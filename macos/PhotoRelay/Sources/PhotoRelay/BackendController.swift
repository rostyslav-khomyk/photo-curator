import Foundation

@MainActor
final class BackendController: ObservableObject {
    static let shared = BackendController()
    @Published private(set) var isRunning = false
    @Published private(set) var isReady = false
    @Published private(set) var lastError: String?
    // Request envelope only; never sent over HTTP.
    let dashboardURL = URL(string: "http://native.invalid")!
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var pending: [String: (Result<(Data, URLResponse), Error>) -> Void] = [:]
    private let writer = DispatchQueue(label: "PhotoCurator.syncPipe")
    private init() {}

    func start() throws {
        guard process?.isRunning != true else { return }
        guard let executable = ProcessInfo.processInfo.environment["PHOTO_RELAY_ENGINE"].map({ URL(fileURLWithPath: $0) })
                ?? Bundle.main.resourceURL?.appendingPathComponent("Engine/icloudpd") else { throw CocoaError(.fileNoSuchFile) }
        let task = Process(), incoming = Pipe(), outgoing = Pipe()
        task.executableURL = executable
        task.arguments = ["--web-ui"]
        var environment = ProcessInfo.processInfo.environment
        environment["PHOTO_CURATOR_NATIVE_PIPE"] = "1"
        environment["ICLOUDPD_NO_OPEN_BROWSER"] = "1"
        environment["ICLOUDPD_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        task.environment = environment
        task.currentDirectoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Photo Relay")
        try FileManager.default.createDirectory(at: task.currentDirectoryURL!, withIntermediateDirectories: true)
        task.standardInput = incoming; task.standardOutput = outgoing
        task.standardError = FileHandle.nullDevice
        outgoing.fileHandleForReading.readabilityHandler = { [weak self, weak task] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor in
                guard let self, self.process === task else { return }
                self.receive(bytes)
            }
        }
        task.terminationHandler = { [weak self, weak task] _ in
            Task { @MainActor in
                guard let self, self.process === task else { return }
                self.stop()
            }
        }
        try task.run()
        process = task; input = incoming.fileHandleForWriting
        isRunning = true; isReady = true; lastError = nil
    }

    func stop() {
        let task = process
        process = nil; input = nil; buffer.removeAll()
        isRunning = false; isReady = false
        task?.terminate()
        let callbacks = Array(pending.values); pending.removeAll()
        callbacks.forEach { $0(.failure(URLError(.networkConnectionLost))) }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try start()
        let id = UUID().uuidString
        let message: [String: Any] = ["id": id, "path": request.url!.path,
            "method": request.httpMethod ?? "GET", "headers": request.allHTTPHeaderFields ?? [:],
            "body": String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""]
        var bytes = try JSONSerialization.data(withJSONObject: message); bytes.append(10)
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(1, request.timeoutInterval)))
                guard !Task.isCancelled else { return }
                self?.pending.removeValue(forKey: id)?(.failure(URLError(.timedOut)))
            }
            pending[id] = { result in timeout.cancel(); continuation.resume(with: result) }
            let handle = input, payload = bytes
            writer.async { [weak self] in
                do { try handle?.write(contentsOf: payload) }
                catch { Task { @MainActor in self?.pending.removeValue(forKey: id)?(.failure(error)) } }
            }
        }
    }
    func data(from url: URL) async throws -> (Data, URLResponse) { try await data(for: URLRequest(url: url)) }

    private func receive(_ bytes: Data) {
        buffer.append(bytes)
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            let prefix = "PHOTO_CURATOR_RPC "
            guard let string = String(data: line, encoding: .utf8), string.hasPrefix(prefix),
                  let data = String(string.dropFirst(prefix.count)).data(using: .utf8),
                  let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = reply["id"] as? String, let status = reply["status"] as? Int,
                  let body = reply["body"] as? String,
                  let response = HTTPURLResponse(url: dashboardURL, statusCode: status, httpVersion: nil, headerFields: nil) else { continue }
            pending.removeValue(forKey: id)?(.success((Data(body.utf8), response)))
        }
    }
}
