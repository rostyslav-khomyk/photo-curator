import Foundation
import SQLite3

enum DerivedCacheNamespace: String, Sendable {
    case textEvidence = "text-evidence"
    case visualLabels = "visual-labels"
    case momentCaptions = "moment-captions"
    case automaticMoments = "automatic-moments"
    case largeMomentWindows = "large-moment-windows"
    case momentContinuity = "moment-continuity"
}

struct DerivedCacheStats: Sendable, Equatable {
    let records: Int
    let payloadBytes: Int64
    let fileBytes: Int64
}

/// A rebuildable cache. Every transaction is synchronous and contains no suspension point.
final class DerivedCacheStore: @unchecked Sendable {
    static let maximumPayloadBytes = 512 * 1024
    static let minimumFreeBytes: Int64 = 2 * 1024 * 1024 * 1024

    let url: URL
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func productionURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Curator/analysis-cache.sqlite3")
    }

    static func production() throws -> DerivedCacheStore { try DerivedCacheStore(url: productionURL()) }

    static func adjacentToLegacyDirectory(_ directory: URL) -> URL {
        let siblingDirectories: Set<String> = ["text-evidence", "background-context", "automatic-moments", "event-continuity"]
        let container = siblingDirectories.contains(directory.lastPathComponent)
            ? directory.deletingLastPathComponent() : directory
        return container.appendingPathComponent("analysis-cache.sqlite3")
    }

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure()
            sqlite3_close(db)
            db = nil
            throw error
        }
        do {
            try execute("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=3000; PRAGMA synchronous=NORMAL;")
            try execute("""
                CREATE TABLE IF NOT EXISTS entries (
                    namespace TEXT NOT NULL,
                    cache_key TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    updated REAL NOT NULL,
                    PRIMARY KEY(namespace, cache_key)
                );
                CREATE INDEX IF NOT EXISTS entries_updated ON entries(updated);
                PRAGMA user_version=1;
                """)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    func data(namespace: DerivedCacheNamespace, key: String, maximumBytes: Int,
              legacyURL: URL? = nil) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? read(namespace: namespace.rawValue, key: key), data.count <= maximumBytes {
            return data
        }
        guard let legacyURL,
              let size = try? legacyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumBytes,
              let data = try? Data(contentsOf: legacyURL), data.count <= maximumBytes else { return nil }
        if (try? writeIfAbsent(data, namespace: namespace.rawValue, key: key)) != nil {
            try? FileManager.default.removeItem(at: legacyURL)
            return (try? read(namespace: namespace.rawValue, key: key)) ?? data
        }
        return data
    }

    func set(_ data: Data, namespace: DerivedCacheNamespace, key: String,
             maximumBytes: Int = maximumPayloadBytes) throws {
        guard data.count <= maximumBytes else { throw PublicationFailure.invalidRequest }
        guard Self.hasWriteCapacity(at: url) else {
            throw NSError(domain: "PhotoRelay.DerivedCache", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Local analysis paused because this Mac is low on storage."])
        }
        lock.lock()
        defer { lock.unlock() }
        try write(data, namespace: namespace.rawValue, key: key)
    }

    func remove(namespace: DerivedCacheNamespace, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("DELETE FROM entries WHERE namespace=? AND cache_key=?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, namespace.rawValue, -1, transient)
        sqlite3_bind_text(statement, 2, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func stats() throws -> DerivedCacheStats {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("SELECT COUNT(*),COALESCE(SUM(length(payload)),0) FROM entries")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        let files = [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
        let fileBytes = files.reduce(Int64(0)) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return DerivedCacheStats(records: Int(sqlite3_column_int64(statement, 0)),
                                 payloadBytes: sqlite3_column_int64(statement, 1), fileBytes: fileBytes)
    }

    func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("DELETE FROM entries; PRAGMA wal_checkpoint(TRUNCATE);")
    }

    func maintain(maximumPayloadBytes: Int64 = 2 * 1024 * 1024 * 1024,
                  deleteOlderThan cutoff: Date = Date().addingTimeInterval(-365 * 86_400)) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let expired = try prepare("DELETE FROM entries WHERE rowid IN (SELECT rowid FROM entries WHERE updated < ? ORDER BY updated LIMIT 1000)")
            sqlite3_bind_double(expired, 1, cutoff.timeIntervalSince1970)
            guard sqlite3_step(expired) == SQLITE_DONE else { sqlite3_finalize(expired); throw failure() }
            sqlite3_finalize(expired)
            let total = try scalar("SELECT COALESCE(SUM(length(payload)),0) FROM entries")
            if total > maximumPayloadBytes {
                let excess = total - maximumPayloadBytes
                let oldest = try prepare("SELECT rowid,length(payload) FROM entries ORDER BY updated")
                var ids: [Int64] = [], reclaimed: Int64 = 0
                while reclaimed < excess, ids.count < 1000, sqlite3_step(oldest) == SQLITE_ROW {
                    ids.append(sqlite3_column_int64(oldest, 0))
                    reclaimed += sqlite3_column_int64(oldest, 1)
                }
                sqlite3_finalize(oldest)
                let remove = try prepare("DELETE FROM entries WHERE rowid=?")
                for id in ids {
                    sqlite3_reset(remove)
                    sqlite3_bind_int64(remove, 1, id)
                    guard sqlite3_step(remove) == SQLITE_DONE else { sqlite3_finalize(remove); throw failure() }
                }
                sqlite3_finalize(remove)
            }
            try execute("COMMIT")
            try execute("PRAGMA optimize; PRAGMA wal_checkpoint(PASSIVE);")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Imports a bounded group atomically; source files are removed only after commit.
    func importLegacy(_ entries: [(DerivedCacheNamespace, String, URL, Int)]) throws -> Int {
        guard !entries.isEmpty, Self.hasWriteCapacity(at: url) else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        var imported: [URL] = []
        do {
            for (namespace, key, file, maximumBytes) in entries {
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= maximumBytes, let data = try? Data(contentsOf: file), data.count <= maximumBytes else { continue }
                try writeIfAbsent(data, namespace: namespace.rawValue, key: key)
                imported.append(file)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        for file in imported {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(atPath: file.path + ".lock")
        }
        return imported.count
    }

    static func hasWriteCapacity(at url: URL) -> Bool {
        let values = try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return available >= minimumFreeBytes
    }

    private func read(namespace: String, key: String) throws -> Data? {
        let statement = try prepare("SELECT payload FROM entries WHERE namespace=? AND cache_key=?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, namespace, -1, transient)
        sqlite3_bind_text(statement, 2, key, -1, transient)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    private func write(_ data: Data, namespace: String, key: String) throws {
        let statement = try prepare("""
            INSERT INTO entries(namespace,cache_key,payload,updated) VALUES(?,?,?,?)
            ON CONFLICT(namespace,cache_key) DO UPDATE SET payload=excluded.payload,updated=excluded.updated
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, namespace, -1, transient)
        sqlite3_bind_text(statement, 2, key, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), transient) }
        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func writeIfAbsent(_ data: Data, namespace: String, key: String) throws {
        let statement = try prepare("INSERT OR IGNORE INTO entries(namespace,cache_key,payload,updated) VALUES(?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, namespace, -1, transient)
        sqlite3_bind_text(statement, 2, key, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), transient) }
        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func scalar(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int64(statement, 0)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func failure() -> NSError {
        NSError(domain: "PhotoRelay.DerivedCache", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: db.map { String(cString: sqlite3_errmsg($0)) } ?? "Cache unavailable"])
    }
}
