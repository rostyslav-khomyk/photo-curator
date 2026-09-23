import XCTest
import SQLite3
@testable import PhotoRelay

final class CuratorTests: XCTestCase {
    func testNewerDatabaseVersionIsNotOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=99", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try CuratorStore(url: url))
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 99)
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func photo(_ id: String, _ seconds: Double?, lat: Double? = nil, lon: Double? = nil, favorite: Bool = false) -> IndexedPhoto {
        IndexedPhoto(id: id, created: seconds.map(Date.init(timeIntervalSince1970:)), modified: nil,
                     latitude: lat, longitude: lon, favorite: favorite, width: 100, height: 100)
    }

    func testIndexSurvivesReopeningAndKeepsUndatedPhotos() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try CuratorStore(url: url)
            try store.save([photo("1998", 883612800), photo("unknown", nil)], generation: "one")
        }
        let reopened = try CuratorStore(url: url)
        XCTAssertEqual(try reopened.counts().total, 2)
        XCTAssertEqual(try reopened.counts().undated, 1)
        let photos = try reopened.photos(in: DateInterval(start: Date(timeIntervalSince1970: 0), end: Date()))
        XCTAssertEqual(photos.map(\.id), ["1998"])
    }

    func testPartialReconciliationDoesNotDeleteOldIndexEntries() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try CuratorStore(url: url)
        try store.save([photo("old", 10), photo("edited", 20)], generation: "old")
        try store.save([photo("edited", 30, favorite: true)], generation: "new")
        XCTAssertEqual(try store.counts().total, 2)
        try store.finishFullScan(generation: "new")
        XCTAssertEqual(try store.counts().total, 1)
        let photos = try store.photos(in: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 100))
        XCTAssertEqual(photos.first?.favorite, true)
        XCTAssertEqual(photos.first?.created, Date(timeIntervalSince1970: 30))
    }

    func testFullVerificationProgressSurvivesRestartAndClearsOnlyOnCommit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let progress = VerificationProgress(scope: "fingerprint", generation: "scan-1",
                                            cursor: 4_200, total: 109_182, updated: Date(timeIntervalSince1970: 10))
        do {
            let store = try CuratorStore(url: url)
            try store.save([photo("old", 10), photo("seen", 20)], generation: "old")
            try store.save([photo("seen", 20)], generation: progress.generation)
            try store.saveVerificationProgress(progress)
        }

        let reopened = try CuratorStore(url: url)
        XCTAssertEqual(try reopened.verificationProgress(), progress)
        try reopened.finishFullScan(generation: progress.generation)
        XCTAssertEqual(try reopened.verificationProgress(), progress)
        try reopened.clearVerificationProgress()
        XCTAssertNil(try reopened.verificationProgress())
        XCTAssertEqual(try reopened.photos(in: DateInterval(start: .distantPast, end: .distantFuture)).map(\.id), ["seen"])
    }

    func testIncrementalChangeDuringVerificationIsMarkedSeenByGeneration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try CuratorStore(url: url)
        try store.save([photo("edited", 10), photo("missing", 20)], generation: "old")
        XCTAssertTrue(try store.updatePhoto(photo("edited", 10, favorite: true), generation: "scan"))
        try store.finishFullScan(generation: "scan")
        let photos = try store.photos(in: DateInterval(start: .distantPast, end: .distantFuture))
        XCTAssertEqual(photos.map(\.id), ["edited"])
        XCTAssertTrue(photos[0].favorite)
    }

    func testIncrementalInsertCreatesPhotoAndAnalysisWork() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try CuratorStore(url: url)
        let inserted = photo("new", 10)
        XCTAssertTrue(try store.updatePhoto(inserted))
        try store.enqueueAnalysis(asset: inserted.id, revision: inserted.analysisRevision, analyzer: "test")
        XCTAssertEqual(try store.counts().total, 1)
        XCTAssertEqual(try store.claimAnalysis()?.asset, inserted.id)
    }

    func testIdenticalPhotoKitMetadataDoesNotRequestCatalogRefresh() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try CuratorStore(url: url)
        let original = photo("asset", 10)
        try store.save([original], generation: "one")

        XCTAssertFalse(try store.updatePhoto(original))
        XCTAssertTrue(try store.updatePhoto(photo("asset", 10, favorite: true)))
        XCTAssertFalse(try store.updatePhoto(photo("asset", 10, favorite: true)))
    }

    func testDeletePhotosPrunesSpecifiedEntriesAndJobs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try CuratorStore(url: url)
        try store.save([photo("keep", 10), photo("delete1", 20), photo("delete2", 30)], generation: "gen1")
        try store.enqueueAnalysis(asset: "keep", revision: "rev1", analyzer: "v1")
        try store.enqueueAnalysis(asset: "delete1", revision: "rev1", analyzer: "v1")
        XCTAssertEqual(try store.counts().total, 3)

        try store.deletePhotos(ids: ["delete1", "delete2"])
        XCTAssertEqual(try store.counts().total, 1)
        let remaining = try store.photos(in: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 100))
        XCTAssertEqual(remaining.map(\.id), ["keep"])
        let claimed = try store.claimAnalysis(range: nil)
        XCTAssertEqual(claimed?.asset, "keep")
    }

    func testRangeUsesExclusiveEndBoundary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try CuratorStore(url: url)
        try store.save([photo("start", 10), photo("inside", 19), photo("end", 20)], generation: "one")
        XCTAssertEqual(try store.photos(in: DateInterval(start: Date(timeIntervalSince1970: 10), duration: 10)).map(\.id), ["start", "inside"])
    }

    func testGroupingUsesDayTimeAndLocationWithoutInventingUnknownDates() {
        let input = [photo("a", 100), photo("b", 200, favorite: true), photo("c", 20_000),
                     photo("d", 21_000, lat: 52, lon: 4), photo("e", 22_000, lat: 48, lon: 2),
                     photo("f", 90_000), photo("unknown", nil)]
        let moments = MomentGrouping.group(input, calendar: calendar)
        XCTAssertEqual(moments.count, 4)
        XCTAssertEqual(moments.flatMap(\.photos).count, 6)
        XCTAssertEqual(moments.last?.favorites, 1)
        XCTAssertEqual(MomentGrouping.group(input.reversed(), calendar: calendar).map(\.id), moments.map(\.id))
    }

    func testForegroundOnlyOverridesIdlePolicy() {
        XCTAssertNotNil(CuratorPolicy.waitingReason(idleSeconds: 0, lowPower: false, hot: false, syncBusy: false, foreground: false))
        XCTAssertNil(CuratorPolicy.waitingReason(idleSeconds: 0, lowPower: false, hot: false, syncBusy: false, foreground: true))
        XCTAssertNotNil(CuratorPolicy.waitingReason(idleSeconds: 999, lowPower: true, hot: false, syncBusy: false, foreground: true))
        XCTAssertNotNil(CuratorPolicy.waitingReason(idleSeconds: 999, lowPower: false, hot: true, syncBusy: false, foreground: true))
        XCTAssertNotNil(CuratorPolicy.waitingReason(idleSeconds: 999, lowPower: false, hot: false, syncBusy: true, foreground: true))
        XCTAssertNotNil(CuratorPolicy.waitingReason(idleSeconds: .nan, lowPower: false, hot: false, syncBusy: false, foreground: false))
        XCTAssertFalse(CuratorPolicy.mayRunAutomaticPublication(idleSeconds: 119, foreground: false))
        XCTAssertTrue(CuratorPolicy.mayRunAutomaticPublication(idleSeconds: 120, foreground: false))
        XCTAssertTrue(CuratorPolicy.mayRunAutomaticPublication(idleSeconds: 0, foreground: true))
    }

    func testCompletedForegroundMetadataAdvancesToAnalysis() {
        XCTAssertTrue(CuratorPolicy.shouldRunMetadata(foreground: true, metadataReady: false,
                                                      reconciliationNeeded: false, reconciliationDue: false))
        XCTAssertFalse(CuratorPolicy.shouldRunMetadata(foreground: true, metadataReady: true,
                                                       reconciliationNeeded: false, reconciliationDue: false))
        XCTAssertTrue(CuratorPolicy.shouldRunMetadata(foreground: false, metadataReady: true,
                                                      reconciliationNeeded: true, reconciliationDue: true))
        XCTAssertFalse(CuratorPolicy.shouldRunMetadata(foreground: false, metadataReady: true,
                                                       reconciliationNeeded: true, reconciliationDue: false))
        XCTAssertFalse(CuratorPolicy.shouldRunMetadata(foreground: true, metadataReady: true,
                                                       reconciliationNeeded: true, reconciliationDue: true))
    }

    func testAnalysisContinuationStopsOnlyWhenCaughtUpOrUnclaimedFailure() {
        XCTAssertTrue(CuratorPolicy.shouldContinueAnalysis(caughtUp: false, failedBeforeClaim: false))
        XCTAssertFalse(CuratorPolicy.shouldContinueAnalysis(caughtUp: true, failedBeforeClaim: false))
        XCTAssertFalse(CuratorPolicy.shouldContinueAnalysis(caughtUp: false, failedBeforeClaim: true))
    }

    func testTimePresetsAndCustomDatesAreExplicit() throws {
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 12))!
        let week = try XCTUnwrap(CuratorPeriod.lastWeek.interval(now: now, calendar: calendar, customStart: now, customEnd: now))
        XCTAssertEqual(week.duration, 7 * 86400)
        let spring = try XCTUnwrap(CuratorPeriod.thisSpring.interval(now: now, calendar: calendar, customStart: now, customEnd: now))
        XCTAssertEqual(calendar.component(.month, from: spring.start), 3)
        XCTAssertEqual(calendar.component(.month, from: spring.end), 6)
        XCTAssertNil(CuratorPeriod.custom.interval(now: now, calendar: calendar, customStart: now, customEnd: now.addingTimeInterval(-86400)))
    }
}
