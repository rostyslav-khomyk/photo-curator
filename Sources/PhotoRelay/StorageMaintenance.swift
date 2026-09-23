import Foundation

enum StorageMaintenance {
    static func run(fileManager: FileManager = .default, now: Date = Date()) {
        let cache = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Curator", isDirectory: true)
        trim(cache.appendingPathComponent("Google Staging"), maximumBytes: 2 * 1024 * 1024 * 1024,
             deleteOlderThan: now.addingTimeInterval(-7 * 86_400), fileManager: fileManager)
        // High-file-count evidence is migrated in bounded background batches. Never
        // enumerate those directories synchronously during app launch.
    }

    static func migrateLegacyEvidence(fileManager: FileManager = .default, batchSize: Int = 500,
                                      maximumBatches: Int = 20) {
        guard let cache = try? DerivedCacheStore.production() else { return }
        var batches = 0
        while batches < maximumBatches, DerivedCacheStore.hasWriteCapacity(at: cache.url) {
            let batch = legacyBatch(limit: batchSize, fileManager: fileManager)
            guard !batch.isEmpty else { break }
            guard (try? cache.importLegacy(batch)) ?? 0 > 0 else { break }
            batches += 1
            Thread.sleep(forTimeInterval: 0.02)
        }
        try? cache.maintain()
    }

    static func storageSummary(fileManager: FileManager = .default) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let cacheURL = DerivedCacheStore.productionURL(fileManager: fileManager)
        let available = (try? cacheURL.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        var parts: [String] = []
        if let cache = try? DerivedCacheStore(url: cacheURL), let stats = try? cache.stats() {
            parts.append("Analysis cache: \(stats.records.formatted()) records, \(formatter.string(fromByteCount: stats.fileBytes)) on disk")
        } else {
            parts.append("Analysis cache is not available")
        }
        if let available {
            parts.append("Free space available to Photo Curator: \(formatter.string(fromByteCount: available))")
        }
        if available.map({ $0 < DerivedCacheStore.minimumFreeBytes }) == true {
            parts.append("New local analysis is paused until at least 2 GB is available")
        }
        return parts.joined(separator: "\n")
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

    private static func legacyBatch(limit: Int, fileManager: FileManager) -> [(DerivedCacheNamespace, String, URL, Int)] {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Relay/curator", isDirectory: true)
        let sources: [(URL, DerivedCacheNamespace, Int, (URL) -> Bool)] = [
            (support.appendingPathComponent("text-evidence"), .textEvidence, 128 * 1024, { $0.pathExtension == "json" }),
            (support.appendingPathComponent("background-context"), .visualLabels, 128 * 1024,
             { $0.lastPathComponent.hasPrefix("labels-") && $0.pathExtension == "json" }),
            (support.appendingPathComponent("background-context"), .momentCaptions, 128 * 1024,
             { $0.lastPathComponent.hasPrefix("moment-") && $0.pathExtension == "json" }),
            (support.appendingPathComponent("automatic-moments"), .automaticMoments, 256 * 1024, { $0.pathExtension == "json" }),
            (support.appendingPathComponent("automatic-moments/internal-windows"), .largeMomentWindows, 256 * 1024, { $0.pathExtension == "json" }),
            (support.appendingPathComponent("event-continuity"), .momentContinuity, 64 * 1024, { $0.pathExtension == "json" })
        ]
        var result: [(DerivedCacheNamespace, String, URL, Int)] = []
        for (directory, namespace, maximumBytes, include) in sources {
            guard result.count < limit,
                  let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { continue }
            while result.count < limit, let file = enumerator.nextObject() as? URL {
                guard include(file),
                      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                result.append((namespace, file.deletingPathExtension().lastPathComponent, file, maximumBytes))
            }
        }
        return result
    }
}
