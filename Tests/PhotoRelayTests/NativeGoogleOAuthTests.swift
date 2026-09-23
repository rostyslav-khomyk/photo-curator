import Foundation
import XCTest
@testable import PhotoRelay

private final class GoogleTokenMemoryStore: GoogleTokenStoring, @unchecked Sendable {
    var token: GoogleOAuthToken?
    func load(clientID: String) throws -> GoogleOAuthToken? { token }
    func save(_ token: GoogleOAuthToken, clientID: String) throws { self.token = token }
    func delete(clientID: String) throws { token = nil }
}

final class NativeGoogleOAuthTests: XCTestCase {
    func testRefreshStoresNewAccessTokenAndPreservesRefreshToken() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = directory.appendingPathComponent("google_credentials.json")
        try Data(#"{"installed":{"client_id":"client","client_secret":"secret"}}"#.utf8).write(to: credentials)
        let store = GoogleTokenMemoryStore()
        store.token = GoogleOAuthToken(accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast,
                                       scopes: [NativeGooglePhotosClient.readScope])
        GoogleURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/token")
            XCTAssertEqual(request.httpMethod, "POST")
            return (200, Data(#"{"access_token":"new","expires_in":3600}"#.utf8))
        }
        let oauth = NativeGoogleOAuth(credentialsURL: credentials, store: store, session: session())

        let token = try await oauth.accessToken(scopes: [NativeGooglePhotosClient.readScope], forceRefresh: false)

        XCTAssertEqual(token, "new")
        XCTAssertEqual(store.token?.refreshToken, "refresh")
        XCTAssertEqual(store.token?.accessToken, "new")
    }

    func testLegacyTokenMigratesIntoStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = directory.appendingPathComponent("google_credentials.json")
        try Data(#"{"installed":{"client_id":"client","client_secret":"secret"}}"#.utf8).write(to: credentials)
        let legacy = directory.appendingPathComponent("google_credentials_token.json")
        try Data(#"{"access_token":"saved","refresh_token":"refresh","scope":"scope-a"}"#.utf8).write(to: legacy)
        let store = GoogleTokenMemoryStore()
        let oauth = NativeGoogleOAuth(credentialsURL: credentials, store: store, session: session())

        let connected = try await oauth.isConnected(scopes: ["scope-a"])

        XCTAssertTrue(connected)
        XCTAssertEqual(store.token?.refreshToken, "refresh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
