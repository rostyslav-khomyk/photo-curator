import Foundation

struct DiagnosticExportContext: Codable, Sendable, Equatable {
    let indexedPhotos: Int
    let availableMoments: Int
    let visibleMoments: Int
    let analyzedThisSession: Int
    let deferredThisSession: Int
    let backgroundCurationEnabled: Bool
    let automaticPublicationEnabled: Bool
}

struct DiagnosticStorageSummary: Codable, Sendable, Equatable {
    let regularFiles: Int
    let bytes: Int64
}

struct DiagnosticTelemetryEntry: Codable, Sendable, Equatable {
    let time: String
    let event: String
    let counts: [String: Int]
}

struct DiagnosticBundle: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let createdAt: Date
    let appVersion: String
    let build: String
    let operatingSystem: String
    let architecture: String
    let context: DiagnosticExportContext
    let applicationSupport: DiagnosticStorageSummary
    let logs: DiagnosticStorageSummary
    let telemetry: [DiagnosticTelemetryEntry]
    let privacy: String
}

enum DiagnosticBundleExporter {
    private static let allowedCountKeys = Set([
        "analyzed", "boundedPilot", "code", "deferred", "enabled", "full", "indexed",
        "moments", "pending", "photos", "reason", "removed", "saved", "scanned", "selected",
        "singletons", "total", "updated", "visible"
    ])

    static func export(
        context: DiagnosticExportContext,
        to destination: URL,
        fileManager: FileManager = .default,
        supportDirectory: URL? = nil,
        logsDirectory: URL? = nil
    ) throws {
        let support = supportDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Relay", isDirectory: true)
        let logs = logsDirectory ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Photo Relay", isDirectory: true)
        let info = Bundle.main.infoDictionary ?? [:]
        let bundle = DiagnosticBundle(
            schemaVersion: 1,
            createdAt: Date(),
            appVersion: info["CFBundleShortVersionString"] as? String ?? "development",
            build: info["CFBundleVersion"] as? String ?? "development",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            context: context,
            applicationSupport: storageSummary(at: support, fileManager: fileManager),
            logs: storageSummary(at: logs, fileManager: fileManager),
            telemetry: sanitizedTelemetry(in: logs, fileManager: fileManager),
            privacy: "Contains aggregate counts, sizes, versions, and whitelisted event counters only. No photo identifiers, filenames, titles, locations, OCR, image data, tokens, or credentials."
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(bundle).write(to: destination, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func storageSummary(at root: URL, fileManager: FileManager) -> DiagnosticStorageSummary {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return DiagnosticStorageSummary(regularFiles: 0, bytes: 0) }

        var files = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return DiagnosticStorageSummary(regularFiles: files, bytes: bytes)
    }

    private static func sanitizedTelemetry(in directory: URL, fileManager: FileManager) -> [DiagnosticTelemetryEntry] {
        let names = ["curator.3.jsonl", "curator.2.jsonl", "curator.1.jsonl", "curator.jsonl"]
        let allowedEvents = Set(CuratorTelemetry.Event.allCases.map(\.rawValue))
        var entries: [DiagnosticTelemetryEntry] = []

        for name in names {
            let url = directory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path),
                  let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in contents.split(whereSeparator: \.isNewline) {
                guard let data = line.data(using: .utf8),
                      let raw = try? JSONDecoder().decode(RawTelemetryEntry.self, from: data),
                      allowedEvents.contains(raw.event) else { continue }
                entries.append(DiagnosticTelemetryEntry(
                    time: raw.time,
                    event: raw.event,
                    counts: raw.counts.filter { allowedCountKeys.contains($0.key) }
                ))
            }
        }
        return Array(entries.suffix(4_000))
    }

    private struct RawTelemetryEntry: Decodable {
        let time: String
        let event: String
        let counts: [String: Int]
    }
}
