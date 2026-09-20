import XCTest
import SQLite3
@testable import PhotoRelay

final class AnalysisQueueTests: XCTestCase {
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

    func testForegroundRangeDoesNotClaimOutsidePhotos() throws {
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
