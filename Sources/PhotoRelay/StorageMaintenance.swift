import Foundation

enum StorageMaintenance {
    static let cacheLimit = 512 * 1024 * 1024

    static func run(fileManager: FileManager = .default, now: Date = Date()) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Relay/curator", isDirectory: true)
        let cache = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Curator", isDirectory: true)
        trim(cache.appendingPathComponent("Google Staging"), maximumBytes: 2 * 1024 * 1024 * 1024,
             deleteOlderThan: now.addingTimeInterval(-7 * 86_400), fileManager: fileManager)
        trim(support.appendingPathComponent("text-evidence"), maximumBytes: cacheLimit,
             deleteOlderThan: now.addingTimeInterval(-365 * 86_400), fileManager: fileManager)
        trim(support.appendingPathComponent("background-context"), maximumBytes: cacheLimit,
             deleteOlderThan: now.addingTimeInterval(-365 * 86_400), fileManager: fileManager)
    }

    static func removeGoogleStaging(fileManager: FileManager = .default) {
        let directory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Curator/Google Staging", isDirectory: true)
        try? fileManager.removeItem(at: directory)
    }

    static func trim(_ directory: URL, maximumBytes: Int, deleteOlderThan cutoff: Date,
                     fileManager: FileManager = .default) {
        guard let enumerator = fileManager.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        var files: [(URL, Int, Date)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }
            files.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        for file in files where file.2 < cutoff { try? fileManager.removeItem(at: file.0) }
        let retained = files.filter { fileManager.fileExists(atPath: $0.0.path) }
        var total = retained.reduce(0) { $0 + $1.1 }
        for file in retained.sorted(by: { $0.2 < $1.2 }) where total > maximumBytes {
            if (try? fileManager.removeItem(at: file.0)) != nil { total -= file.1 }
        }
    }
}
