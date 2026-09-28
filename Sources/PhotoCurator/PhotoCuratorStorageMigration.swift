import Foundation
import SQLite3

enum PhotoCuratorStorageMigration {
    static func run(fileManager: FileManager = .default, defaults: UserDefaults = .standard,
                    roots suppliedRoots: [URL]? = nil) {
        let legacyName = ["Photo", "Relay"].joined(separator: " ")
        let currentName = "Photo Curator"
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = suppliedRoots ?? [
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            home.appendingPathComponent("Library/Logs", isDirectory: true),
            home.appendingPathComponent("Pictures", isDirectory: true),
        ]

        for root in roots {
            let legacy = root.appendingPathComponent(legacyName, isDirectory: true)
            let current = root.appendingPathComponent(currentName, isDirectory: true)
            guard fileManager.fileExists(atPath: legacy.path) else { continue }
            if !fileManager.fileExists(atPath: current.path) {
                try? fileManager.moveItem(at: legacy, to: current)
                continue
            }
            guard let items = try? fileManager.contentsOfDirectory(at: legacy,
                includingPropertiesForKeys: nil) else { continue }
            for item in items {
                var destination = current.appendingPathComponent(item.lastPathComponent)
                if fileManager.fileExists(atPath: destination.path) {
                    destination = current.appendingPathComponent(item.lastPathComponent + ".legacy")
                    var copy = 2
                    while fileManager.fileExists(atPath: destination.path) {
                        destination = current.appendingPathComponent(item.lastPathComponent + ".legacy-\(copy)")
                        copy += 1
                    }
                }
                try? fileManager.moveItem(at: item, to: destination)
            }
            if (try? fileManager.contentsOfDirectory(atPath: legacy.path).isEmpty) == true {
                try? fileManager.removeItem(at: legacy)
            }
        }

        for key in ["googleCredentials", "albumMapping", "exportDirectory"] {
            guard let value = defaults.string(forKey: key), value.contains(legacyName) else { continue }
            let migrated = value.replacingOccurrences(of: legacyName, with: currentName)
            if fileManager.fileExists(atPath: migrated) { defaults.set(migrated, forKey: key) }
        }

        for root in roots {
            migrateGoogleLedger(in: root.appendingPathComponent(currentName), fileManager: fileManager)
        }
    }

    private static func migrateGoogleLedger(in directory: URL, fileManager: FileManager) {
        let oldStem = ["photo", "relay", "uploads"].joined(separator: "_")
        let legacy = directory.appendingPathComponent(oldStem + ".sqlite3")
        guard fileManager.fileExists(atPath: legacy.path) else { return }
        let current = directory.appendingPathComponent("photo_curator_uploads.sqlite3")
        var db: OpaquePointer?
        guard sqlite3_open(current.path, &db) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        let quoted = legacy.path.replacingOccurrences(of: "'", with: "''")
        let statements = [
            "CREATE TABLE IF NOT EXISTS uploads (account TEXT, digest TEXT, media_id TEXT, PRIMARY KEY (account, digest))",
            "CREATE TABLE IF NOT EXISTS album_creations (account TEXT, title TEXT, album_id TEXT, PRIMARY KEY (account, title))",
            "ATTACH DATABASE '\(quoted)' AS legacy",
            "BEGIN IMMEDIATE",
            "INSERT INTO uploads SELECT * FROM legacy.uploads WHERE 1 ON CONFLICT(account, digest) DO UPDATE SET media_id=COALESCE(uploads.media_id, excluded.media_id)",
            "INSERT INTO album_creations SELECT * FROM legacy.album_creations WHERE 1 ON CONFLICT(account, title) DO UPDATE SET album_id=COALESCE(album_creations.album_id, excluded.album_id)",
            "COMMIT",
            "DETACH DATABASE legacy",
        ]
        for statement in statements where sqlite3_exec(db, statement, nil, nil, nil) != SQLITE_OK {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return
        }
        for suffix in ["", "-wal", "-shm"] {
            try? fileManager.removeItem(at: URL(fileURLWithPath: legacy.path + suffix))
        }
    }
}
