import Foundation
import XCTest
@testable import PhotoRelay

private actor GoogleTokenFake: GoogleAccessTokenProviding {
    private(set) var refreshes = 0
    private var current = "saved"
    func accessToken(scopes: Set<String>, forceRefresh: Bool) -> String {
        if forceRefresh {
            refreshes += 1
            current = "fresh"
        }
        return current
    }
}

private final class GoogleURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class NativeGooglePhotosClientTests: XCTestCase {
    override func tearDown() {
        GoogleURLProtocol.handler = nil
        super.tearDown()
    }

    func testAlbumListingPaginatesAndRefreshesOnceAfterUnauthorized() async throws {
        let tokens = GoogleTokenFake()
        var requests = 0
        GoogleURLProtocol.handler = { request in
            requests += 1
            if requests == 1 { return (401, Data()) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "pageToken" })?.value
            return page == nil
                ? (200, Data(#"{"albums":[{"id":"a","title":"One"}],"nextPageToken":"next"}"#.utf8))
                : (200, Data(#"{"albums":[{"id":"b","title":"Two"}]}"#.utf8))
        }
        let client = NativeGooglePhotosClient(tokens: tokens, session: session())

        let albums = try await client.listAlbums()

        XCTAssertEqual(albums.map(\.id), ["a", "b"])
        let refreshes = await tokens.refreshes
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(requests, 3)
    }

    func testAmbiguousAlbumCreateFailureIsNotRetried() async throws {
        let tokens = GoogleTokenFake()
        var requests = 0
        GoogleURLProtocol.handler = { _ in
            requests += 1
            return (500, Data(#"{"error":{"message":"uncertain"}}"#.utf8))
        }
        let client = NativeGooglePhotosClient(tokens: tokens, session: session())

        do {
            _ = try await client.createAlbum(title: "Family")
            XCTFail("Expected uncertain creation failure")
        } catch {
            XCTAssertEqual(error as? NativeGooglePhotosError, .rejected(500, "uncertain"))
        }
        XCTAssertEqual(requests, 1)
    }

    func testAlbumMembershipChangesAreLimitedToFiftyItemsPerRequest() async throws {
        let tokens = GoogleTokenFake()
        var batchSizes: [Int] = []
        GoogleURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/albums/album-id:batchAddMediaItems")
            let body = try request.bodyData()
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            batchSizes.append(try XCTUnwrap(object["mediaItemIds"] as? [String]).count)
            return (200, Data("{}".utf8))
        }
        let client = NativeGooglePhotosClient(tokens: tokens, session: session())

        try await client.changeAlbum("album-id", mediaIDs: Set((0..<51).map(String.init)), removing: false)

        XCTAssertEqual(batchSizes, [50, 1])
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private extension URLRequest {
    func bodyData() throws -> Data {
        if let httpBody { return httpBody }
        let stream = try XCTUnwrap(httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
