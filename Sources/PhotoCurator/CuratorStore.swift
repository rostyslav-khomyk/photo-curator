import Foundation
import SQLite3

/// Confined to CuratorWorker's actor; tests use isolated temporary instances.
final class CuratorStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            let error = failure()
            sqlite3_close(db)
            db = nil
            throw error
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let version = try prepare("PRAGMA user_version")
            defer { sqlite3_finalize(version) }
            guard sqlite3_step(version) == SQLITE_ROW else { throw failure() }
            let previousVersion = sqlite3_column_int(version, 0)
            guard previousVersion <= 4 else {
                throw NSError(domain: "PhotoCurator.CuratorStore", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "This curator index was created by a newer Photo Curator. Update the app to continue; your index was kept."])
            }
            sqlite3_reset(version)
            try execute("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=3000;")
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("CREATE TABLE IF NOT EXISTS photos (id TEXT PRIMARY KEY, created REAL, payload BLOB NOT NULL, generation TEXT NOT NULL);")
                try execute("CREATE INDEX IF NOT EXISTS photos_created ON photos(created);")
                try execute("""
                    CREATE TABLE IF NOT EXISTS analysis_jobs (
                        asset TEXT PRIMARY KEY, revision TEXT NOT NULL, analyzer TEXT NOT NULL,
                        priority INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'pending',
                        token TEXT, lease REAL, result BLOB);
                    CREATE INDEX IF NOT EXISTS analysis_pending ON analysis_jobs(state, priority);
                    CREATE TABLE IF NOT EXISTS verification_progress (
                        kind TEXT PRIMARY KEY, scope TEXT NOT NULL, generation TEXT NOT NULL,
                        cursor INTEGER NOT NULL, total INTEGER NOT NULL, updated REAL NOT NULL);
                    """)
                if previousVersion < 4 {
                    try execute("ALTER TABLE analysis_jobs ADD COLUMN created REAL")
                    try execute("UPDATE analysis_jobs SET created=(SELECT created FROM photos WHERE id=asset)")
                }
                try execute("""
                    CREATE INDEX IF NOT EXISTS analysis_ready_order ON analysis_jobs(priority DESC,created DESC,asset)
                      WHERE state='pending';
                    CREATE INDEX IF NOT EXISTS analysis_retry_order ON analysis_jobs(priority DESC,created DESC,asset,lease)
                      WHERE state='running';
                    CREATE TRIGGER IF NOT EXISTS analysis_insert_date AFTER INSERT ON analysis_jobs BEGIN
                      UPDATE analysis_jobs SET created=(SELECT created FROM photos WHERE id=NEW.asset) WHERE asset=NEW.asset;
                    END;
                    CREATE TRIGGER IF NOT EXISTS photo_insert_analysis_date AFTER INSERT ON photos BEGIN
                      UPDATE analysis_jobs SET created=NEW.created WHERE asset=NEW.id;
                    END;
                    CREATE TRIGGER IF NOT EXISTS photo_update_analysis_date AFTER UPDATE OF created ON photos
                      WHEN NEW.created IS NOT OLD.created BEGIN
                      UPDATE analysis_jobs SET created=NEW.created WHERE asset=NEW.id;
                    END;
                    PRAGMA user_version=4;
                    """)
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    private func encoded(_ photo: IndexedPhoto) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(photo)
    }

    func save(_ photos: [IndexedPhoto], generation: String) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("INSERT INTO photos VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET created=excluded.created,payload=excluded.payload,generation=excluded.generation")
            defer { sqlite3_finalize(statement) }
            for photo in photos {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, photo.id, -1, transient)
                if let date = photo.created { sqlite3_bind_double(statement, 2, date.timeIntervalSince1970) }
                else { sqlite3_bind_null(statement, 2) }
                let data = try encoded(photo)
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), transient) }
                sqlite3_bind_text(statement, 4, generation, -1, transient)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func finishFullScan(generation: String) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("DELETE FROM photos WHERE generation != ?")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, generation, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            try execute("DELETE FROM analysis_jobs WHERE asset NOT IN (SELECT id FROM photos)")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func verificationProgress(kind: String = "full") throws -> VerificationProgress? {
        let statement = try prepare("SELECT scope,generation,cursor,total,updated FROM verification_progress WHERE kind=?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, transient)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw failure() }
        return VerificationProgress(
            scope: String(cString: sqlite3_column_text(statement, 0)),
            generation: String(cString: sqlite3_column_text(statement, 1)),
            cursor: Int(sqlite3_column_int64(statement, 2)),
            total: Int(sqlite3_column_int64(statement, 3)),
            updated: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)))
    }

    func saveVerificationProgress(_ progress: VerificationProgress, kind: String = "full") throws {
        let statement = try prepare("""
            INSERT INTO verification_progress(kind,scope,generation,cursor,total,updated) VALUES(?,?,?,?,?,?)
            ON CONFLICT(kind) DO UPDATE SET scope=excluded.scope,generation=excluded.generation,
                cursor=excluded.cursor,total=excluded.total,updated=excluded.updated
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, transient)
        sqlite3_bind_text(statement, 2, progress.scope, -1, transient)
        sqlite3_bind_text(statement, 3, progress.generation, -1, transient)
        sqlite3_bind_int64(statement, 4, Int64(progress.cursor))
        sqlite3_bind_int64(statement, 5, Int64(progress.total))
        sqlite3_bind_double(statement, 6, progress.updated.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func clearVerificationProgress(kind: String = "full") throws {
        let statement = try prepare("DELETE FROM verification_progress WHERE kind=?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func deletePhotos(ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("DELETE FROM photos WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            for id in ids {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, id, -1, transient)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            }
            try execute("DELETE FROM analysis_jobs WHERE asset NOT IN (SELECT id FROM photos)")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Updates public PhotoKit metadata without changing the active full-scan generation.
    /// Returns false for PhotoKit notifications that only changed local resource availability.
    @discardableResult
    func updatePhoto(_ photo: IndexedPhoto, generation: String? = nil) throws -> Bool {
        let statement = try prepare("UPDATE photos SET created=?,payload=?" +
            (generation == nil ? "" : ",generation=?") + " WHERE id=? AND payload != ?")
        defer { sqlite3_finalize(statement) }
        if let date = photo.created { sqlite3_bind_double(statement, 1, date.timeIntervalSince1970) }
        else { sqlite3_bind_null(statement, 1) }
        let data = try encoded(photo)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }
        var offset: Int32 = 3
        if let generation {
            sqlite3_bind_text(statement, offset, generation, -1, transient)
            offset += 1
        }
        sqlite3_bind_text(statement, offset, photo.id, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, offset + 1, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        if sqlite3_changes(db) == 1 { return true }

        let exists = try prepare("SELECT 1 FROM photos WHERE id=?")
        sqlite3_bind_text(exists, 1, photo.id, -1, transient)
        let existsStatus = sqlite3_step(exists)
        sqlite3_finalize(exists)
        guard existsStatus == SQLITE_ROW || existsStatus == SQLITE_DONE else { throw failure() }
        if existsStatus == SQLITE_ROW {
            if let generation {
                let markSeen = try prepare("UPDATE photos SET generation=? WHERE id=? AND generation != ?")
                defer { sqlite3_finalize(markSeen) }
                sqlite3_bind_text(markSeen, 1, generation, -1, transient)
                sqlite3_bind_text(markSeen, 2, photo.id, -1, transient)
                sqlite3_bind_text(markSeen, 3, generation, -1, transient)
                guard sqlite3_step(markSeen) == SQLITE_DONE else { throw failure() }
            }
            return false
        }

        let inserted = try prepare("INSERT INTO photos(id,created,payload,generation) VALUES(?,?,?,?)")
        defer { sqlite3_finalize(inserted) }
        sqlite3_bind_text(inserted, 1, photo.id, -1, transient)
        if let date = photo.created { sqlite3_bind_double(inserted, 2, date.timeIntervalSince1970) }
        else { sqlite3_bind_null(inserted, 2) }
        _ = data.withUnsafeBytes { sqlite3_bind_blob(inserted, 3, $0.baseAddress, Int32(data.count), transient) }
        sqlite3_bind_text(inserted, 4, generation ?? "incremental", -1, transient)
        guard sqlite3_step(inserted) == SQLITE_DONE else { throw failure() }
        return true
    }

    func maintain() throws {
        try execute("DELETE FROM analysis_jobs WHERE asset NOT IN (SELECT id FROM photos)")
        try execute("PRAGMA optimize")
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    func photos(in interval: DateInterval) throws -> [IndexedPhoto] {
        let statement = try prepare("SELECT payload FROM photos WHERE created >= ? AND created < ? ORDER BY created,id")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, interval.end.timeIntervalSince1970)
        // One decoder for the whole scan. A fresh JSONDecoder per row turned a
        // library overview into several minutes of CPU while the window sat open.
        let decoder = JSONDecoder()
        var result: [IndexedPhoto] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            if let photo = try? decoder.decode(IndexedPhoto.self, from: data) {
                result.append(photo)
            }
        }
    }

    func photo(id: String) throws -> IndexedPhoto? {
        let statement = try prepare("SELECT payload FROM photos WHERE id=?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, transient)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        return try? JSONDecoder().decode(IndexedPhoto.self, from: data)
    }

    func counts() throws -> (total: Int, undated: Int) {
        let statement = try prepare("SELECT COUNT(*),COALESCE(SUM(created IS NULL),0) FROM photos")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return (Int(sqlite3_column_int64(statement, 0)), Int(sqlite3_column_int64(statement, 1)))
    }

    func requeueAllAnalysis(analyzer: String) throws -> Int {
        try execute("BEGIN IMMEDIATE")
        do {
            let photos = try prepare("SELECT payload FROM photos")
            let enqueue = try prepare("""
                INSERT INTO analysis_jobs(asset,revision,analyzer,priority,state,token,lease,result)
                VALUES(?,?,?,?, 'pending',NULL,NULL,NULL)
                ON CONFLICT(asset) DO UPDATE SET revision=excluded.revision,analyzer=excluded.analyzer,
                  priority=excluded.priority,state='pending',token=NULL,lease=NULL,result=NULL
                """)
            defer { sqlite3_finalize(photos); sqlite3_finalize(enqueue) }
            var count = 0
            while sqlite3_step(photos) == SQLITE_ROW {
                guard let bytes = sqlite3_column_blob(photos, 0) else { throw failure() }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(photos, 0)))
                guard let photo = try? JSONDecoder().decode(IndexedPhoto.self, from: data) else { continue }
                let priority = AdaptiveEvidenceScheduling.analysisPriority(photo)
                sqlite3_reset(enqueue); sqlite3_clear_bindings(enqueue)
                sqlite3_bind_text(enqueue, 1, photo.id, -1, transient)
                sqlite3_bind_text(enqueue, 2, photo.analysisRevision, -1, transient)
                sqlite3_bind_text(enqueue, 3, analyzer, -1, transient)
                sqlite3_bind_int64(enqueue, 4, Int64(priority))
                guard sqlite3_step(enqueue) == SQLITE_DONE else { throw failure() }
                count += 1
            }
            try execute("COMMIT")
            return count
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Re-scores pending/running jobs from indexed attributes so clean-room / soak queues
    /// stop treating metadata-rich GPS photos as equal to thin older ones.
    @discardableResult
    func refreshAdaptiveAnalysisPriorities() throws -> Int {
        try execute("BEGIN IMMEDIATE")
        do {
            let select = try prepare("""
                SELECT j.asset,p.payload FROM analysis_jobs j
                JOIN photos p ON p.id=j.asset
                WHERE j.state IN ('pending','running')
                """)
            let update = try prepare("""
                UPDATE analysis_jobs SET priority=?
                WHERE asset=? AND priority < \(AdaptiveEvidenceScheduling.viewportPriority)
                """)
            defer { sqlite3_finalize(select); sqlite3_finalize(update) }
            var count = 0
            while sqlite3_step(select) == SQLITE_ROW {
                let asset = String(cString: sqlite3_column_text(select, 0))
                guard let bytes = sqlite3_column_blob(select, 1) else { continue }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(select, 1)))
                guard let photo = try? JSONDecoder().decode(IndexedPhoto.self, from: data) else { continue }
                let priority = AdaptiveEvidenceScheduling.analysisPriority(photo)
                sqlite3_reset(update); sqlite3_clear_bindings(update)
                sqlite3_bind_int64(update, 1, Int64(priority))
                sqlite3_bind_text(update, 2, asset, -1, transient)
                // Preserve explicit viewport boosts (>= 100).
                guard sqlite3_step(update) == SQLITE_DONE else { throw failure() }
                if sqlite3_changes(db) > 0 { count += 1 }
            }
            try execute("COMMIT")
            return count
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Revision is the caller's asset/edit fingerprint; analyzer includes algorithm version.
    /// Re-enqueueing identical work preserves both completed results and active leases.
    func enqueueAnalysis(asset: String, revision: String, analyzer: String, priority: Int = 0) throws {
        let statement = try prepare("""
            INSERT INTO analysis_jobs(asset,revision,analyzer,priority) VALUES(?,?,?,?)
            ON CONFLICT(asset) DO UPDATE SET
              priority=MAX(priority,excluded.priority),
              state=CASE WHEN revision=excluded.revision AND analyzer=excluded.analyzer THEN state ELSE 'pending' END,
              token=CASE WHEN revision=excluded.revision AND analyzer=excluded.analyzer THEN token ELSE NULL END,
              lease=CASE WHEN revision=excluded.revision AND analyzer=excluded.analyzer THEN lease ELSE NULL END,
              result=CASE WHEN revision=excluded.revision AND analyzer=excluded.analyzer THEN result ELSE NULL END,
              revision=excluded.revision,analyzer=excluded.analyzer
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, asset, -1, transient)
        sqlite3_bind_text(statement, 2, revision, -1, transient)
        sqlite3_bind_text(statement, 3, analyzer, -1, transient)
        sqlite3_bind_int64(statement, 4, Int64(priority))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    /// Rebinds a completed Vision result onto a new metadata revision when pixels/edits are unchanged.
    /// Returns false when no completed result exists for the prior revision.
    @discardableResult
    func adoptAnalysisRevision(asset: String, from oldRevision: String, to newRevision: String,
                               analyzer: String) throws -> Bool {
        guard oldRevision != newRevision else { return false }
        let statement = try prepare("""
            UPDATE analysis_jobs
            SET revision=?
            WHERE asset=? AND revision=? AND analyzer=? AND state='done' AND result IS NOT NULL
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, newRevision, -1, transient)
        sqlite3_bind_text(statement, 2, asset, -1, transient)
        sqlite3_bind_text(statement, 3, oldRevision, -1, transient)
        sqlite3_bind_text(statement, 4, analyzer, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        return sqlite3_changes(db) == 1
    }

    /// Expired work can be reclaimed after a crash. Tokens reject late worker results.
    /// While attribute-thin work is pending or actively leased, GPS-rich refinement stays
    /// unclaimed. Deferred retries (`running` + future lease + no token) must not stall the queue.
    func claimAnalysis(now: Date = Date(), leaseDuration: TimeInterval = 120, range: DateInterval? = nil) throws -> AnalysisJob? {
        try claimAnalysis(limit: 1, now: now, leaseDuration: leaseDuration, range: range).first
    }

    /// Claim up to `limit` jobs in one writer transaction. Thin work still parks GPS-rich refinement.
    func claimAnalysis(limit: Int, now: Date = Date(), leaseDuration: TimeInterval = 120,
                       range: DateInterval? = nil) throws -> [AnalysisJob] {
        guard leaseDuration.isFinite, leaseDuration > 0, now.timeIntervalSince1970.isFinite else {
            throw NSError(domain: "PhotoCurator.CuratorStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid analysis lease."])
        }
        let bounded = min(max(limit, 0), AnalysisLaneBudget.maxLanes)
        guard bounded > 0 else { return [] }
        try execute("BEGIN IMMEDIATE")
        do {
            var jobs: [AnalysisJob] = []
            for _ in 0..<bounded {
                let ceiling = AdaptiveEvidenceScheduling.refinementMaxPriority
                let thinOutstanding = try hasClaimableOrActiveAnalysis(abovePriority: ceiling, now: now)
                let minimumExclusive: Int? = thinOutstanding ? ceiling : nil
                guard let job = try claimAnalysisCandidateLocked(
                    now: now, leaseDuration: leaseDuration, range: range,
                    minimumPriorityExclusive: minimumExclusive
                ) else { break }
                jobs.append(job)
            }
            try execute("COMMIT")
            return jobs
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Thin work that should keep GPS-rich refinement parked: pending, actively leased, or expired.
    /// Soft-deferred rows (`running` without a token until a future lease) are excluded so a burst
    /// of thumbnail/OCR deferrals cannot freeze the analysis scheduler.
    private func hasClaimableOrActiveAnalysis(abovePriority: Int, now: Date) throws -> Bool {
        let statement = try prepare("""
            SELECT 1 FROM analysis_jobs
            WHERE priority > ?
              AND (
                state='pending'
                OR (state='running' AND token IS NOT NULL)
                OR (state='running' AND lease IS NOT NULL AND lease <= ?)
              )
            LIMIT 1
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(abovePriority))
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Caller holds an open write transaction. `minimumPriorityExclusive` keeps refinement parked.
    private func claimAnalysisCandidateLocked(
        now: Date, leaseDuration: TimeInterval, range: DateInterval?,
        minimumPriorityExclusive: Int?
    ) throws -> AnalysisJob? {
        var scope = ""
        if let minimumPriorityExclusive {
            scope += " AND priority > \(minimumPriorityExclusive)"
        }
        if range != nil {
            scope += " AND created >= ?2 AND created < ?3"
        }
        // Each ordered partial index supplies at most one candidate; only two rows are sorted.
        let select = try prepare("""
            SELECT asset,revision,analyzer FROM (
              SELECT * FROM (SELECT asset,revision,analyzer,priority,created FROM analysis_jobs
                WHERE state='pending'\(scope) ORDER BY priority DESC,created DESC,asset LIMIT 1)
              UNION ALL
              SELECT * FROM (SELECT asset,revision,analyzer,priority,created FROM analysis_jobs
                WHERE state='running' AND lease <= ?1\(scope) ORDER BY priority DESC,created DESC,asset LIMIT 1)
            ) ORDER BY priority DESC,created DESC,asset LIMIT 1
            """)
        defer { sqlite3_finalize(select) }
        sqlite3_bind_double(select, 1, now.timeIntervalSince1970)
        if let range {
            sqlite3_bind_double(select, 2, range.start.timeIntervalSince1970)
            sqlite3_bind_double(select, 3, range.end.timeIntervalSince1970)
        }
        let status = sqlite3_step(select)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw failure() }
        let job = AnalysisJob(asset: String(cString: sqlite3_column_text(select, 0)),
                              revision: String(cString: sqlite3_column_text(select, 1)),
                              analyzer: String(cString: sqlite3_column_text(select, 2)), token: UUID().uuidString)
        let update = try prepare("UPDATE analysis_jobs SET state='running',token=?,lease=? WHERE asset=?")
        defer { sqlite3_finalize(update) }
        sqlite3_bind_text(update, 1, job.token, -1, transient)
        sqlite3_bind_double(update, 2, now.addingTimeInterval(leaseDuration).timeIntervalSince1970)
        sqlite3_bind_text(update, 3, job.asset, -1, transient)
        guard sqlite3_step(update) == SQLITE_DONE else { throw failure() }
        return job
    }

    @discardableResult
    func finishAnalysis(_ job: AnalysisJob, result: Data) throws -> Bool {
        let statement = try prepare("UPDATE analysis_jobs SET state='done',result=?,token=NULL,lease=NULL WHERE asset=? AND revision=? AND analyzer=? AND token=? AND state='running'")
        defer { sqlite3_finalize(statement) }
        // zeroblob preserves an empty result as data rather than SQL NULL.
        if result.isEmpty { sqlite3_bind_zeroblob(statement, 1, 0) }
        else { _ = result.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(result.count), transient) } }
        bindJob(job, to: statement, offset: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        return sqlite3_changes(db) == 1
    }

    /// Cancellation returns just this lease to the queue without affecting a newer job.
    @discardableResult
    func releaseAnalysis(_ job: AnalysisJob) throws -> Bool {
        let statement = try prepare("UPDATE analysis_jobs SET state='pending',token=NULL,lease=NULL WHERE asset=? AND revision=? AND analyzer=? AND token=? AND state='running'")
        defer { sqlite3_finalize(statement) }
        bindJob(job, to: statement, offset: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        return sqlite3_changes(db) == 1
    }

    func pendingAnalysisCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM analysis_jobs WHERE state='pending'")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func analysisResult(asset: String, revision: String, analyzer: String) throws -> Data? {
        let statement = try prepare("SELECT result FROM analysis_jobs WHERE asset=? AND revision=? AND analyzer=? AND state='done'")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, asset, -1, transient)
        sqlite3_bind_text(statement, 2, revision, -1, transient)
        sqlite3_bind_text(statement, 3, analyzer, -1, transient)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw failure() }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func bindJob(_ job: AnalysisJob, to statement: OpaquePointer, offset: Int32) {
        for (index, value) in [job.asset, job.revision, job.analyzer, job.token].enumerated() {
            sqlite3_bind_text(statement, offset + Int32(index), value, -1, transient)
        }
    }

    func deferAnalysis(_ job: AnalysisJob, until: Date) throws {
        let statement = try prepare("UPDATE analysis_jobs SET lease=?,token=NULL WHERE asset=? AND revision=? AND analyzer=? AND token=? AND state='running'")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, until.timeIntervalSince1970)
        bindJob(job, to: statement, offset: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func nextAnalysisEligibilityDate(after now: Date = Date()) throws -> Date? {
        let statement = try prepare("SELECT MIN(lease) FROM analysis_jobs WHERE state='running' AND lease > ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
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
        NSError(domain: "PhotoCurator.CuratorStore", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Could not update the local curator index: \(db.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable")"])
    }
}

struct AnalysisJob: Equatable, Sendable {
    let asset: String
    let revision: String
    let analyzer: String
    let token: String
}

struct VerificationProgress: Equatable {
    let scope: String
    let generation: String
    let cursor: Int
    let total: Int
    let updated: Date
}
