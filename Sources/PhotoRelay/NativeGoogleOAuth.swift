import AppKit
import Foundation
import Network
import Security

enum GoogleOAuthError: LocalizedError, Equatable {
    case notConfigured
    case authorizationRequired
    case rejected(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Google sign-in is not configured in this build of Photo Curator."
        case .authorizationRequired:
            "Google Photos needs to be connected again."
        case .rejected(let message):
            message
        case .invalidResponse:
            "Google returned an invalid sign-in response."
        }
    }
}

struct GoogleOAuthToken: Codable, Equatable, Sendable {
    var accessToken: String?
    var refreshToken: String
    var expiresAt: Date?
    var scopes: Set<String>

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case scopes = "scope"
    }

    init(accessToken: String?, refreshToken: String, expiresAt: Date?, scopes: Set<String>) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try values.decodeIfPresent(String.self, forKey: .accessToken)
        refreshToken = try values.decode(String.self, forKey: .refreshToken)
        expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt)
        if let value = try? values.decode(String.self, forKey: .scopes) {
            scopes = Set(value.split(separator: " ").map(String.init))
        } else {
            scopes = Set(try values.decodeIfPresent([String].self, forKey: .scopes) ?? [])
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(accessToken, forKey: .accessToken)
        try values.encode(refreshToken, forKey: .refreshToken)
        try values.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try values.encode(scopes.sorted().joined(separator: " "), forKey: .scopes)
    }
}

protocol GoogleTokenStoring: Sendable {
    func load(clientID: String) throws -> GoogleOAuthToken?
    func save(_ token: GoogleOAuthToken, clientID: String) throws
    func delete(clientID: String) throws
}

struct KeychainGoogleTokenStore: GoogleTokenStoring {
    private let service = "com.photocurator.google-oauth"

    func load(clientID: String) throws -> GoogleOAuthToken? {
        var query = baseQuery(clientID: clientID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw GoogleOAuthError.rejected("The saved Google sign-in could not be read.")
        }
        return try JSONDecoder().decode(GoogleOAuthToken.self, from: data)
    }

    func save(_ token: GoogleOAuthToken, clientID: String) throws {
        let data = try JSONEncoder().encode(token)
        let query = baseQuery(clientID: clientID)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw GoogleOAuthError.rejected("The Google sign-in could not be saved securely.")
            }
        } else if status != errSecSuccess {
            throw GoogleOAuthError.rejected("The Google sign-in could not be saved securely.")
        }
    }

    func delete(clientID: String) throws {
        let status = SecItemDelete(baseQuery(clientID: clientID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GoogleOAuthError.rejected("The saved Google sign-in could not be removed.")
        }
    }

    private func baseQuery(clientID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: clientID]
    }
}

actor NativeGoogleOAuth: GoogleAccessTokenProviding {
    static let identityScope = "openid"
    private struct ClientFile: Decodable {
        let installed: Client?
        let web: Client?
        struct Client: Decodable { let clientID: String; let clientSecret: String
            enum CodingKeys: String, CodingKey {
                case clientID = "client_id"
                case clientSecret = "client_secret"
            }
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval?
        let scope: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
        }
    }

    private struct ErrorResponse: Decodable {
        let error: String
        let errorDescription: String?
        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private let credentialsURL: URL
    private let store: GoogleTokenStoring
    private let session: URLSession
    private let now: @Sendable () -> Date
    private var cachedClient: ClientFile.Client?
    private var cachedToken: GoogleOAuthToken?

    init(credentialsURL: URL, store: GoogleTokenStoring = KeychainGoogleTokenStore(),
         session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentialsURL = credentialsURL
        self.store = store
        self.session = session
        self.now = now
    }

    func isConnected(scopes: Set<String>) throws -> Bool {
        let client = try loadClient()
        let token = try loadToken(clientID: client.clientID)
        return token.map { scopes.isSubset(of: $0.scopes) } ?? false
    }

    func authorize(scopes: Set<String>) async throws {
        let client = try loadClient()
        let callback = try GoogleOAuthLoopbackServer()
        let redirectURI = try await callback.start()
        defer { callback.stop() }
        let state = UUID().uuidString
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.sorted().joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authorizationURL = components.url else { throw GoogleOAuthError.invalidResponse }
        let opened = await MainActor.run { NSWorkspace.shared.open(authorizationURL) }
        guard opened else { throw GoogleOAuthError.rejected("The system browser could not be opened.") }
        let code = try await callback.waitForCode(state: state)
        let token = try await exchange(code: code, redirectURI: redirectURI, scopes: scopes, client: client)
        try store.save(token, clientID: client.clientID)
        cachedToken = token
    }

    func accessToken(scopes: Set<String>, forceRefresh: Bool) async throws -> String {
        let client = try loadClient()
        guard var token = try loadToken(clientID: client.clientID),
              scopes.isSubset(of: token.scopes) else { throw GoogleOAuthError.authorizationRequired }
        if !forceRefresh, let access = token.accessToken,
           token.expiresAt.map({ $0.timeIntervalSince(now()) > 60 }) ?? false {
            return access
        }
        token = try await refresh(token, client: client)
        try store.save(token, clientID: client.clientID)
        cachedToken = token
        return try token.accessToken.unwrap(or: GoogleOAuthError.invalidResponse)
    }

    private func loadClient() throws -> ClientFile.Client {
        if let cachedClient { return cachedClient }
        guard let data = try? Data(contentsOf: credentialsURL),
              let file = try? JSONDecoder().decode(ClientFile.self, from: data),
              let client = file.installed ?? file.web,
              !client.clientID.isEmpty, !client.clientSecret.isEmpty else {
            throw GoogleOAuthError.notConfigured
        }
        cachedClient = client
        return client
    }

    private func loadToken(clientID: String) throws -> GoogleOAuthToken? {
        if let cachedToken { return cachedToken }
        if let saved = try store.load(clientID: clientID) {
            cachedToken = saved
            return saved
        }
        guard let legacy = try legacyToken() else { return nil }
        try store.save(legacy, clientID: clientID)
        cachedToken = legacy
        return legacy
    }

    private func legacyToken() throws -> GoogleOAuthToken? {
        let name = credentialsURL.deletingPathExtension().lastPathComponent + "_token"
        let url = credentialsURL.deletingLastPathComponent()
            .appendingPathComponent(name).appendingPathExtension(credentialsURL.pathExtension)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(GoogleOAuthToken.self, from: Data(contentsOf: url))
    }

    private func refresh(_ token: GoogleOAuthToken, client: ClientFile.Client) async throws -> GoogleOAuthToken {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form([
            "client_id": client.clientID,
            "client_secret": client.clientSecret,
            "refresh_token": token.refreshToken,
            "grant_type": "refresh_token",
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleOAuthError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let result = try? JSONDecoder().decode(ErrorResponse.self, from: data),
               result.error == "invalid_grant" { throw GoogleOAuthError.authorizationRequired }
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.errorDescription
            throw GoogleOAuthError.rejected(message ?? "Google sign-in could not be refreshed.")
        }
        let result = try JSONDecoder().decode(TokenResponse.self, from: data)
        return GoogleOAuthToken(
            accessToken: result.accessToken,
            refreshToken: result.refreshToken ?? token.refreshToken,
            expiresAt: now().addingTimeInterval(result.expiresIn ?? 3_600),
            scopes: result.scope.map { Set($0.split(separator: " ").map(String.init)) } ?? token.scopes
        )
    }

    private func exchange(code: String, redirectURI: String, scopes: Set<String>,
                          client: ClientFile.Client) async throws -> GoogleOAuthToken {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form([
            "code": code,
            "client_id": client.clientID,
            "client_secret": client.clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleOAuthError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.errorDescription
            throw GoogleOAuthError.rejected(message ?? "Google authorization was not completed.")
        }
        let result = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let refreshToken = result.refreshToken ?? cachedToken?.refreshToken else {
            throw GoogleOAuthError.invalidResponse
        }
        return GoogleOAuthToken(
            accessToken: result.accessToken,
            refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(result.expiresIn ?? 3_600),
            scopes: result.scope.map { Set($0.split(separator: " ").map(String.init)) } ?? scopes
        )
    }

    private func form(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}

private final class GoogleOAuthLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "PhotoCurator.GoogleOAuthCallback")
    private let lock = NSLock()
    private var startCallback: CheckedContinuation<NWEndpoint.Port, Error>?
    private var callback: CheckedContinuation<String, Error>?
    private var completed: Result<String, Error>?

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> String {
        let port = try await withCheckedThrowingContinuation { continuation in
            lock.withLock { startCallback = continuation }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = self.listener.port { self.finishStart(.success(port)) }
                case .failed(let error):
                    self.finishStart(.failure(error))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
            listener.start(queue: queue)
        }
        return "http://127.0.0.1:\(port.rawValue)/callback"
    }

    func waitForCode(state: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                expectedState = state
                if let completed {
                    continuation.resume(with: completed)
                } else {
                    callback = continuation
                    queue.asyncAfter(deadline: .now() + 300) { [weak self] in
                        self?.finish(.failure(GoogleOAuthError.rejected(
                            "Google authorization timed out after 5 minutes."
                        )))
                    }
                }
            }
        }
    }

    func stop() { listener.cancel() }

    private var expectedState = ""

    private func receive(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                finish(.failure(error))
                connection.cancel()
                return
            }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: "\n").first?.split(separator: " ").dropFirst().first
            let components = target.flatMap { URLComponents(string: String($0)) }
            let values = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let valid = components?.path == "/callback" && values["state"] == expectedState
            let code = values["code"]
            let success = valid && code?.isEmpty == false
            let page = success
                ? "<h1>Google Photos connected</h1><p>You can close this tab and return to Photo Curator.</p>"
                : "<h1>Google Photos connection failed</h1><p>Return to Photo Curator and try again.</p>"
            let status = success ? "200 OK" : "400 Bad Request"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if let code, success {
                finish(.success(code))
            } else {
                finish(.failure(GoogleOAuthError.rejected(
                    values["error"].map { "Google authorization was not completed: \($0)" }
                        ?? "The authentication response did not pass its security check."
                )))
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        lock.withLock {
            guard completed == nil else { return }
            completed = result
            callback?.resume(with: result)
            callback = nil
        }
    }

    private func finishStart(_ result: Result<NWEndpoint.Port, Error>) {
        lock.withLock {
            startCallback?.resume(with: result)
            startCallback = nil
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
