import Foundation

/// Counts-only local pilot telemetry. Never accepts asset IDs, OCR, coordinates or tokens.
final class CuratorTelemetry {
    static let shared = CuratorTelemetry(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Photo Relay"))
    enum Event: String { case launch, enabled, paused, metadata, analysis, catalog, caughtUp, failure, waiting, publication, libraryChange }
    let directory: URL
    let maximumBytes: Int
    private let queue = DispatchQueue(label: "PhotoCurator.telemetry")
    private let session = UUID().uuidString
    init(directory: URL, maximumBytes: Int = 1_000_000) {
        self.directory = directory; self.maximumBytes = maximumBytes
    }
    func record(_ event: Event, counts: [String: Int] = [:]) {
        queue.sync {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let file = directory.appendingPathComponent("curator.jsonl")
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size >= maximumBytes {
                    for index in stride(from: 3, through: 1, by: -1) {
                        let target = directory.appendingPathComponent("curator.\(index).jsonl")
                        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                        let source = index == 1 ? file : directory.appendingPathComponent("curator.\(index - 1).jsonl")
                        if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.moveItem(at: source, to: target) }
                    }
                }
                if !FileManager.default.fileExists(atPath: file.path) {
                    FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                var data = try JSONSerialization.data(withJSONObject: ["time": ISO8601DateFormatter().string(from: Date()),
                    "session": session, "event": event.rawValue, "counts": counts], options: [.sortedKeys])
                data.append(10); try handle.write(contentsOf: data)
            } catch { /* Telemetry must not interrupt photo processing. */ }
        }
    }
}

enum CuratorPilot {
    static func range(_ defaults: UserDefaults = .standard) -> DateInterval? {
        guard let start = defaults.object(forKey: "curatorPilotStart") as? Date,
              let end = defaults.object(forKey: "curatorPilotEnd") as? Date, start < end else { return nil }
        return DateInterval(start: start, end: end)
    }
    static func scope(_ requested: DateInterval?, defaults: UserDefaults = .standard) -> DateInterval? {
        guard let pilot = range(defaults) else { return requested }
        guard let requested else { return pilot }
        return requested.intersection(with: pilot) ?? DateInterval(start: pilot.start, duration: 0)
    }
}
