import XCTest
import SQLite3
@testable import PhotoCurator

final class AnalysisQueueTests: XCTestCase {
    func testReconciliationRepairsStaleJobEvenWhenMetadataAlreadyMatches() async throws {
        let store = try CuratorStore(url: url)
        let photo = IndexedPhoto(id: "edited", created: now, modified: now, latitude: nil,
                                 longitude: nil, favorite: false, width: 10, height: 10)
        try store.save([photo], generation: "g")
        try store.enqueueAnalysis(asset: photo.id, revision: "stale", analyzer: CuratorVisionAnalyzer.version)
        let stale = try XCTUnwrap(store.claimAnalysis(now: now))
        let worker = CuratorWorker(url: url)
        let changed = try await worker.reconcilePhoto(photo)
        XCTAssertFalse(changed)
        let repaired = try XCTUnwrap(store.claimAnalysis(now: now))
        XCTAssertEqual(repaired.revision, photo.analysisRevision)
        XCTAssertFalse(try store.finishAnalysis(stale, result: Data([0])))
        XCTAssertTrue(try store.finishAnalysis(repaired, result: Data([1])))
        _ = try await worker.reconcilePhoto(photo)
        XCTAssertNil(try store.claimAnalysis(now: now))
        XCTAssertEqual(try store.analysisResult(asset: photo.id, revision: photo.analysisRevision,
            analyzer: CuratorVisionAnalyzer.version), Data([1]))
    }

    func testIndexedOrderTracksDateChangesAndMergesExpiredJobs() throws {
        let store = try CuratorStore(url: url)
        func photo(_ id: String, _ offset: Double) -> IndexedPhoto {
            IndexedPhoto(id: id, created: now.addingTimeInterval(offset), modified: now,
                         latitude: nil, longitude: nil, favorite: false, width: 10, height: 10)
        }
        // Exercise both enqueue-before-metadata and normal insert order.
        try store.enqueueAnalysis(asset: "a", revision: "r", analyzer: "v")
        try store.save([photo("a", 1), photo("b", 2)], generation: "g")
        try store.enqueueAnalysis(asset: "b", revision: "r", analyzer: "v")
        let first = try XCTUnwrap(store.claimAnalysis(now: now, leaseDuration: 10))
        XCTAssertEqual(first.asset, "b")
        XCTAssertTrue(try store.updatePhoto(photo("a", 3)))
        XCTAssertEqual(try store.claimAnalysis(now: now.addingTimeInterval(11))?.asset, "a")
        XCTAssertEqual(try store.claimAnalysis(now: now.addingTimeInterval(11))?.asset, "b")
    }

    func testVersionThreeMigrationPreservesResultsAndBackfillsQueueDates() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE photos(id TEXT PRIMARY KEY,created REAL,payload BLOB NOT NULL,generation TEXT NOT NULL);
            CREATE TABLE analysis_jobs(asset TEXT PRIMARY KEY,revision TEXT NOT NULL,analyzer TEXT NOT NULL,
              priority INTEGER NOT NULL DEFAULT 0,state TEXT NOT NULL DEFAULT 'pending',token TEXT,lease REAL,result BLOB);
            INSERT INTO photos VALUES('a',100,X'7B7D','g'),('b',200,X'7B7D','g');
            INSERT INTO analysis_jobs(asset,revision,analyzer) VALUES('a','r','v'),('b','r','v');
            INSERT INTO analysis_jobs(asset,revision,analyzer,state,result) VALUES('done','r','v','done',X'01');
            PRAGMA user_version=3;
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let store = try CuratorStore(url: url)
        XCTAssertEqual(try store.claimAnalysis(now: now)?.asset, "b")
        XCTAssertEqual(try store.analysisResult(asset: "done", revision: "r", analyzer: "v"), Data([1]))
    }

    func testOptInCopiedQueueClaimBenchmark() throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTO_CURATOR_QUEUE_AUDIT_COPY"],
              path.hasPrefix("/tmp/photocurator-audit-") else { throw XCTSkip("Requires an isolated temporary index copy") }
        var db: OpaquePointer?, query: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_finalize(query); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT asset,revision,analyzer FROM analysis_jobs WHERE state='pending' OR (state='running' AND lease<=?) ORDER BY priority DESC,(SELECT created FROM photos WHERE id=asset) DESC,asset LIMIT 1", -1, &query, nil), SQLITE_OK)
        let time = Date()
        var baseline: [Double] = []
        var expected: String?
        for _ in 0..<20 {
            sqlite3_bind_double(query, 1, time.timeIntervalSince1970)
            let started = Date()
            XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
            baseline.append(Date().timeIntervalSince(started))
            expected = String(cString: sqlite3_column_text(query, 0))
            sqlite3_reset(query)
        }
        let start = Date()
        let store = try CuratorStore(url: URL(fileURLWithPath: path))
        let migration = Date().timeIntervalSince(start)
        var timings: [Double] = []
        for _ in 0..<20 {
            let started = Date()
            if let job = try store.claimAnalysis(now: time) {
                timings.append(Date().timeIntervalSince(started))
                XCTAssertEqual(job.asset, expected)
                _ = try store.releaseAnalysis(job)
            }
        }
        XCTAssertEqual(timings.count, 20)
        print("QUEUE AUDIT migration=\(migration)s oldMedianSelect=\(baseline.sorted()[10])s medianClaim=\(timings.sorted()[10])s maxClaim=\(timings.max()!)s")
    }

    func testDeferredWorkDoesNotBlockReadyJobs() throws {
        let store = try CuratorStore(url: url)
        try store.enqueueAnalysis(asset: "a", revision: "1", analyzer: "1")
        try store.enqueueAnalysis(asset: "b", revision: "1", analyzer: "1")
        let job = try XCTUnwrap(store.claimAnalysis(now: now))
        try store.deferAnalysis(job, until: now.addingTimeInterval(3600))
        XCTAssertEqual(try store.claimAnalysis(now: now)?.asset, "b")
        XCTAssertNil(try store.claimAnalysis(now: now))
        XCTAssertFalse(try store.finishAnalysis(job, result: Data()))
        XCTAssertEqual(try store.claimAnalysis(now: now.addingTimeInterval(3600))?.asset, "a")
    }

    func testBoundedClaimDoesNotClaimOutsideInterval() throws {
        let store = try CuratorStore(url: url)
        let photos = [IndexedPhoto(id: "inside", created: now, modified: now, latitude: nil, longitude: nil, favorite: false, width: 10, height: 10),
                      IndexedPhoto(id: "outside", created: now.addingTimeInterval(100), modified: now, latitude: nil, longitude: nil, favorite: false, width: 10, height: 10)]
        try store.save(photos, generation: "g")
        for photo in photos { try store.enqueueAnalysis(asset: photo.id, revision: photo.analysisRevision, analyzer: "1") }
        let range = DateInterval(start: now, duration: 10)
        XCTAssertEqual(try store.claimAnalysis(now: now, range: range)?.asset, "inside")
        XCTAssertNil(try store.claimAnalysis(now: now, range: range))
        XCTAssertEqual(try store.claimAnalysis(now: now)?.asset, "outside")
    }

    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("index.sqlite3") }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private let now = Date(timeIntervalSince1970: 1000)

    func testCompletedResultSurvivesRestartAndIdenticalEnqueue() throws {
        do {
            let store = try CuratorStore(url: url)
            try store.enqueueAnalysis(asset: "a", revision: "r1", analyzer: "vision1")
            let job = try XCTUnwrap(store.claimAnalysis(now: now))
            XCTAssertTrue(try store.finishAnalysis(job, result: Data("saved".utf8)))
        }
        let store = try CuratorStore(url: url)
        try store.enqueueAnalysis(asset: "a", revision: "r1", analyzer: "vision1", priority: 5)
        XCTAssertNil(try store.claimAnalysis(now: now.addingTimeInterval(1000)))
        XCTAssertEqual(try store.analysisResult(asset: "a", revision: "r1", analyzer: "vision1"), Data("saved".utf8))
    }

    func testInterruptedLeaseRecoversAndRejectsOldCompletion() throws {
        var old: AnalysisJob!
        do {
            let store = try CuratorStore(url: url)
            try store.enqueueAnalysis(asset: "a", revision: "1", analyzer: "1")
            old = try store.claimAnalysis(now: now, leaseDuration: 10)
        }
        let store = try CuratorStore(url: url)
        XCTAssertNil(try store.claimAnalysis(now: now.addingTimeInterval(9)))
        let new = try XCTUnwrap(store.claimAnalysis(now: now.addingTimeInterval(10)))
        XCTAssertNotEqual(old.token, new.token)
        XCTAssertFalse(try store.finishAnalysis(old, result: Data([1])))
        XCTAssertFalse(try store.releaseAnalysis(old))
        XCTAssertTrue(try store.finishAnalysis(new, result: Data()))
        XCTAssertEqual(try store.analysisResult(asset: "a", revision: "1", analyzer: "1"), Data())
    }

    func testEditAndAlgorithmChangeInvalidateResults() throws {
        let store = try CuratorStore(url: url)
        try store.enqueueAnalysis(asset: "a", revision: "1", analyzer: "1")
        let old = try XCTUnwrap(store.claimAnalysis(now: now))
        try store.enqueueAnalysis(asset: "a", revision: "2", analyzer: "1")
        XCTAssertFalse(try store.finishAnalysis(old, result: Data([1])))
        let edited = try XCTUnwrap(store.claimAnalysis(now: now))
        XCTAssertEqual(edited.revision, "2")
        XCTAssertTrue(try store.finishAnalysis(edited, result: Data([2])))
        try store.enqueueAnalysis(asset: "a", revision: "2", analyzer: "2")
        XCTAssertNil(try store.analysisResult(asset: "a", revision: "2", analyzer: "1"))
        XCTAssertEqual(try store.claimAnalysis(now: now)?.analyzer, "2")
    }

    func testPriorityPromotionAndCancellation() throws {
        let store = try CuratorStore(url: url)
        try store.enqueueAnalysis(asset: "a", revision: "1", analyzer: "1")
        try store.enqueueAnalysis(asset: "z", revision: "1", analyzer: "1")
        try store.enqueueAnalysis(asset: "z", revision: "1", analyzer: "1", priority: 10)
        let first = try XCTUnwrap(store.claimAnalysis(now: now))
        XCTAssertEqual(first.asset, "z")
        try store.enqueueAnalysis(asset: "z", revision: "1", analyzer: "1")
        XCTAssertEqual(try store.claimAnalysis(now: now)?.asset, "a")
        XCTAssertTrue(try store.releaseAnalysis(first))
        XCTAssertEqual(try store.claimAnalysis(now: now)?.asset, "z")
    }

    func testFullReanalysisRequeuesCompletedAndLeasedJobs() throws {
        let store = try CuratorStore(url: url)
        let photos = [IndexedPhoto(id: "done", created: now, modified: now, latitude: nil,
                                   longitude: nil, favorite: false, width: 10, height: 10),
                      IndexedPhoto(id: "leased", created: nil, modified: nil, latitude: nil,
                                   longitude: nil, favorite: false, width: 20, height: 20)]
        try store.save(photos, generation: "g")
        for photo in photos { try store.enqueueAnalysis(asset: photo.id, revision: photo.analysisRevision, analyzer: "old") }
        let first = try XCTUnwrap(store.claimAnalysis(now: now))
        XCTAssertTrue(try store.finishAnalysis(first, result: Data("old".utf8)))
        _ = try XCTUnwrap(store.claimAnalysis(now: now))

        XCTAssertEqual(try store.requeueAllAnalysis(analyzer: "new"), 2)

        let requeued = [try XCTUnwrap(store.claimAnalysis(now: now)),
                        try XCTUnwrap(store.claimAnalysis(now: now))]
        XCTAssertEqual(Set(requeued.map(\.asset)), Set(photos.map(\.id)))
        XCTAssertTrue(requeued.allSatisfy { $0.analyzer == "new" })
        XCTAssertNil(try store.claimAnalysis(now: now))
    }

    func testTwoConnectionsDoNotClaimSameUnexpiredWork() throws {
        let first = try CuratorStore(url: url)
        let second = try CuratorStore(url: url)
        try first.enqueueAnalysis(asset: "a", revision: "1", analyzer: "1")
        XCTAssertNotNil(try first.claimAnalysis(now: now))
        XCTAssertNil(try second.claimAnalysis(now: now))
        XCTAssertThrowsError(try second.claimAnalysis(now: now, leaseDuration: -1))
    }

    func testVersionOneMigrationPreservesMetadata() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE photos(id TEXT PRIMARY KEY, created REAL, payload BLOB NOT NULL, generation TEXT NOT NULL); INSERT INTO photos VALUES('old',NULL,X'7B7D','old'); PRAGMA user_version=1", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let store = try CuratorStore(url: url)
        XCTAssertEqual(try store.counts().total, 1)
        try store.enqueueAnalysis(asset: "old", revision: "1", analyzer: "1")
        XCTAssertNotNil(try store.claimAnalysis(now: now))
    }
}
