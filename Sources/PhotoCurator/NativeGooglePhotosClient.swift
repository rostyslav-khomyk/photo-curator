import Foundation
import UniformTypeIdentifiers

protocol GoogleAccessTokenProviding: Sendable {
    func accessToken(scopes: Set<String>, forceRefresh: Bool) async throws -> String
    func accountIdentifier(subject: String) async throws -> String
}

extension GoogleAccessTokenProviding {
    func accountIdentifier(subject: String) async throws -> String { subject }
}

protocol GooglePhotosServicing: Sendable {
    func accountIdentifier() async throws -> String
    func listAlbums() async throws -> [GoogleAlbum]
    func albumMediaIDs(_ albumID: String) async throws -> Set<String>
    func existingMediaIDs(_ ids: Set<String>) async throws -> Set<String>
    func createAlbum(title: String) async throws -> String
    func uploadBytes(at file: URL) async throws -> String
    func createMedia(uploadToken: String, filename: String) async throws -> String
    func changeAlbum(_ albumID: String, mediaIDs: Set<String>, removing: Bool) async throws
}

enum NativeGooglePhotosError: LocalizedError, Equatable {
    case invalidResponse
    case rejected(Int, String?)
    case missingIdentifier

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Google Photos returned an invalid response."
        case .rejected(let status, let message):
            message ?? "Google Photos rejected the request (error \(status))."
        case .missingIdentifier:
            "Google Photos completed the request without returning an identifier."
        }
    }
}

actor NativeGooglePhotosClient: GooglePhotosServicing {
    static let appendScope = "https://www.googleapis.com/auth/photoslibrary.appendonly"
    static let readScope = "https://www.googleapis.com/auth/photoslibrary.readonly.appcreateddata"
    static let editScope = "https://www.googleapis.com/auth/photoslibrary.edit.appcreateddata"

    private let baseURL = URL(string: "https://photoslibrary.googleapis.com/v1/")!
    private let session: URLSession
    private let tokens: GoogleAccessTokenProviding

    init(tokens: GoogleAccessTokenProviding, session: URLSession = .shared) {
        self.tokens = tokens
        self.session = session
    }

    func accountIdentifier() async throws -> String {
        let url = URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!
        let data = try await request(url: url, scopes: [NativeGoogleOAuth.identityScope])
        guard let subject = try JSONDecoder().decode(Account.self, from: data).sub.nonEmpty else {
            throw NativeGooglePhotosError.missingIdentifier
        }
        return try await tokens.accountIdentifier(subject: subject)
    }

    func listAlbums() async throws -> [GoogleAlbum] {
        var albums: [GoogleAlbum] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(url: baseURL.appendingPathComponent("albums"),
                                           resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "pageSize", value: "50")]
            if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let data = try await request(url: components.url!, scopes: [Self.readScope])
            let page = try JSONDecoder().decode(AlbumPage.self, from: data)
            albums.append(contentsOf: page.albums ?? [])
            pageToken = page.nextPageToken
        } while pageToken != nil
        return albums
    }

    func albumMediaIDs(_ albumID: String) async throws -> Set<String> {
        var ids = Set<String>()
        var pageToken: String?
        repeat {
            var body: [String: Any] = ["albumId": albumID, "pageSize": 100]
            if let pageToken { body["pageToken"] = pageToken }
            let data = try await request(url: baseURL.appendingPathComponent("mediaItems:search"),
                method: "POST", scopes: [Self.readScope], json: body)
            let page = try JSONDecoder().decode(MediaPage.self, from: data)
            ids.formUnion((page.mediaItems ?? []).map(\.id))
            pageToken = page.nextPageToken
        } while pageToken != nil
        return ids
    }

    func existingMediaIDs(_ ids: Set<String>) async throws -> Set<String> {
        var existing = Set<String>()
        for batch in ids.sorted().chunks(of: 50) {
            var components = URLComponents(url: baseURL.appendingPathComponent("mediaItems:batchGet"),
                                           resolvingAgainstBaseURL: false)!
            components.queryItems = batch.map { URLQueryItem(name: "mediaItemIds", value: $0) }
            let data = try await request(url: components.url!, scopes: [Self.readScope])
            let response = try JSONDecoder().decode(MediaBatch.self, from: data)
            existing.formUnion((response.mediaItemResults ?? []).compactMap(\.mediaItem?.id))
        }
        return existing
    }

    func createAlbum(title: String) async throws -> String {
        let data = try await request(url: baseURL.appendingPathComponent("albums"), method: "POST",
            scopes: [Self.appendScope], json: ["album": ["title": title]])
        guard let id = try JSONDecoder().decode(GoogleAlbum.self, from: data).id.nonEmpty else {
            throw NativeGooglePhotosError.missingIdentifier
        }
        return id
    }

    func uploadBytes(at file: URL) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("uploads"))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
                         ?? "application/octet-stream", forHTTPHeaderField: "X-Goog-Upload-Content-Type")
        request.setValue("raw", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        request.setValue(file.lastPathComponent, forHTTPHeaderField: "X-Goog-Upload-File-Name")
        for forceRefresh in [false, true] {
            let access = try await tokens.accessToken(scopes: [Self.appendScope], forceRefresh: forceRefresh)
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            for attempt in 0..<4 {
                let (data, response) = try await session.upload(for: request, fromFile: file)
                guard let http = response as? HTTPURLResponse else {
                    throw NativeGooglePhotosError.invalidResponse
                }
                if http.statusCode == 401, !forceRefresh { break }
                if shouldRetry(http.statusCode, method: "POST", attempt: attempt) {
                    try await Task.sleep(for: .seconds(retryDelay(response: http, attempt: attempt)))
                    continue
                }
                try validate(response, data: data)
                guard let token = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                    throw NativeGooglePhotosError.missingIdentifier
                }
                return token
            }
        }
        throw NativeGooglePhotosError.invalidResponse
    }

    func createMedia(uploadToken: String, filename: String) async throws -> String {
        let body = ["newMediaItems": [["simpleMediaItem": ["uploadToken": uploadToken,
                                                              "fileName": filename]]]]
        let data = try await request(url: baseURL.appendingPathComponent("mediaItems:batchCreate"),
            method: "POST", scopes: [Self.appendScope], json: body)
        let response = try JSONDecoder().decode(MediaCreateResponse.self, from: data)
        guard let result = response.newMediaItemResults?.first else {
            throw NativeGooglePhotosError.missingIdentifier
        }
        if let code = result.status?.code, code != 0 {
            throw NativeGooglePhotosError.rejected(code, result.status?.message)
        }
        guard let id = result.mediaItem?.id else { throw NativeGooglePhotosError.missingIdentifier }
        return id
    }

    func changeAlbum(_ albumID: String, mediaIDs: Set<String>, removing: Bool) async throws {
        let action = removing ? "batchRemoveMediaItems" : "batchAddMediaItems"
        let scope = removing ? Self.editScope : Self.appendScope
        for batch in mediaIDs.sorted().chunks(of: 50) {
            _ = try await request(url: baseURL.appendingPathComponent("albums/\(albumID):\(action)"),
                method: "POST", scopes: [scope], json: ["mediaItemIds": batch])
        }
    }

    private func request(url: URL, method: String = "GET", scopes: Set<String>,
                         json: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for forceRefresh in [false, true] {
            let token = try await tokens.accessToken(scopes: scopes, forceRefresh: forceRefresh)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            for attempt in 0..<4 {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw NativeGooglePhotosError.invalidResponse
                }
                if http.statusCode == 401, !forceRefresh { break }
                if shouldRetry(http.statusCode, method: method, attempt: attempt) {
                    try await Task.sleep(for: .seconds(retryDelay(response: http, attempt: attempt)))
                    continue
                }
                try validate(response, data: data)
                return data
            }
        }
        throw NativeGooglePhotosError.invalidResponse
    }

    private func shouldRetry(_ status: Int, method: String, attempt: Int) -> Bool {
        guard attempt < 3 else { return false }
        if status == 429 { return true }
        return method == "GET" && [500, 502, 503, 504].contains(status)
    }

    private func retryDelay(response: HTTPURLResponse, attempt: Int) -> TimeInterval {
        let fallback = min(300, pow(2, Double(attempt)))
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return fallback }
        if let seconds = TimeInterval(value) { return min(300, max(0, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return min(300, max(fallback, formatter.date(from: value)?.timeIntervalSinceNow ?? 0))
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw NativeGooglePhotosError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(GoogleErrorEnvelope.self, from: data))?.error.message
            throw NativeGooglePhotosError.rejected(http.statusCode, message)
        }
    }
}

private struct AlbumPage: Decodable { let albums: [GoogleAlbum]?; let nextPageToken: String? }
private struct MediaPage: Decodable { let mediaItems: [NativeGoogleMedia]?; let nextPageToken: String? }
private struct NativeGoogleMedia: Decodable { let id: String }
private struct MediaBatch: Decodable { let mediaItemResults: [MediaResult]? }
private struct MediaCreateResponse: Decodable { let newMediaItemResults: [MediaResult]? }
private struct MediaResult: Decodable { let status: GoogleStatus?; let mediaItem: NativeGoogleMedia? }
private struct GoogleStatus: Decodable { let code: Int?; let message: String? }
private struct GoogleErrorEnvelope: Decodable { let error: GoogleError }
private struct GoogleError: Decodable { let message: String }
private struct Account: Decodable { let sub: String }

private extension Array {
    func chunks(of size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
