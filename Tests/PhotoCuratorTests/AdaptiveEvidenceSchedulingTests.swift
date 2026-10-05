import XCTest
@testable import PhotoCurator

final class AdaptiveEvidenceSchedulingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000) // ~2027

    private func photo(id: String, year: Int?, lat: Double?, lon: Double?,
                       category: SimilarityCategory? = nil) -> IndexedPhoto {
        let created = year.map {
            Calendar(identifier: .gregorian).date(from: DateComponents(year: $0, month: 6, day: 1))!
        }
        return IndexedPhoto(id: id, created: created, modified: created, latitude: lat, longitude: lon,
                            favorite: false, width: 100, height: 100, similarityCategory: category)
    }

    func testThinAttributePhotosOutrankRecentGPSCaptures() {
        let thinOld = photo(id: "old", year: 2003, lat: nil, lon: nil)
        let modernNoGPS = photo(id: "nogps", year: 2020, lat: nil, lon: nil)
        let recentGPS = photo(id: "rich", year: 2025, lat: 52.1, lon: 4.8)
        let screenshot = photo(id: "shot", year: 2025, lat: nil, lon: nil, category: .screenshots)

        XCTAssertGreaterThan(AdaptiveEvidenceScheduling.analysisPriority(thinOld, now: now),
                             AdaptiveEvidenceScheduling.analysisPriority(recentGPS, now: now))
        XCTAssertGreaterThan(AdaptiveEvidenceScheduling.analysisPriority(modernNoGPS, now: now),
                             AdaptiveEvidenceScheduling.analysisPriority(recentGPS, now: now))
        XCTAssertGreaterThan(AdaptiveEvidenceScheduling.analysisPriority(recentGPS, now: now),
                             AdaptiveEvidenceScheduling.analysisPriority(screenshot, now: now))
        XCTAssertLessThan(AdaptiveEvidenceScheduling.viewportPriority,
                          200)
        XCTAssertGreaterThan(AdaptiveEvidenceScheduling.viewportPriority,
                             AdaptiveEvidenceScheduling.analysisPriority(thinOld, now: now))
    }

    func testClaimOrderServesThinJobsBeforeRichGPS() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CuratorStore(url: root.appendingPathComponent("index.sqlite3"))
        let rich = photo(id: "rich", year: 2025, lat: 41.4, lon: 2.1)
        let thin = photo(id: "thin", year: 2004, lat: nil, lon: nil)
        try store.save([rich, thin], generation: "g")
        try store.enqueueAnalysis(asset: rich.id, revision: rich.analysisRevision, analyzer: "v",
                                  priority: AdaptiveEvidenceScheduling.analysisPriority(rich, now: now))
        try store.enqueueAnalysis(asset: thin.id, revision: thin.analysisRevision, analyzer: "v",
                                  priority: AdaptiveEvidenceScheduling.analysisPriority(thin, now: now))
        let first = try XCTUnwrap(store.claimAnalysis(now: now))
        XCTAssertEqual(first.asset, "thin")
    }

    func testClaimDefersMetadataRichRefinementWhileThinWorkRemains() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CuratorStore(url: root.appendingPathComponent("index.sqlite3"))
        let rich = photo(id: "rich", year: 2025, lat: 41.4, lon: 2.1)
        let thin = photo(id: "thin", year: 2004, lat: nil, lon: nil)
        try store.save([rich, thin], generation: "g")
        try store.enqueueAnalysis(asset: rich.id, revision: rich.analysisRevision, analyzer: "v",
                                  priority: AdaptiveEvidenceScheduling.analysisPriority(rich, now: now))
        try store.enqueueAnalysis(asset: thin.id, revision: thin.analysisRevision, analyzer: "v",
                                  priority: AdaptiveEvidenceScheduling.analysisPriority(thin, now: now))
        let first = try XCTUnwrap(store.claimAnalysis(now: now))
        XCTAssertEqual(first.asset, "thin")
        // Hold the thin lease so only refinement remains claimable if deferral were broken.
        XCTAssertNil(try store.claimAnalysis(now: now),
                     "GPS-rich refinement must stay parked while thin work is in flight")
        try store.finishAnalysis(first, result: Data([1]))
        let second = try XCTUnwrap(store.claimAnalysis(now: now))
        XCTAssertEqual(second.asset, "rich")
    }

    func testDeferredThinRetriesDoNotStallRefinementClaims() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CuratorStore(url: root.appendingPathComponent("index.sqlite3"))
        let rich = photo(id: "rich", year: 2025, lat: 41.4, lon: 2.1)
        let thin = photo(id: "thin", year: 2004, lat: nil, lon: nil)
        try store.save([rich, thin], generation: "g")
        try store.enqueueAnalysis(asset: rich.id, revision: rich.analysisRevision, analyzer: "v",
                                  priority: AdaptiveEvidenceScheduling.analysisPriority(rich, now: now))
        try store.enqueueAnalysis(asset: thin.id, revision: thin.analysisRevision, analyzer: "v",
                                  priority: AdaptiveEvidenceScheduling.analysisPriority(thin, now: now))
        let thinJob = try XCTUnwrap(store.claimAnalysis(now: now))
        XCTAssertEqual(thinJob.asset, "thin")
        // Soft-defer leaves state=running with a future lease and no worker token.
        try store.deferAnalysis(thinJob, until: now.addingTimeInterval(3600))
        let next = try XCTUnwrap(store.claimAnalysis(now: now),
                                 "Deferred thin retries must not freeze the claim gate")
        XCTAssertEqual(next.asset, "rich")
    }

    func testMetadataRichRefinementPredicateMatchesCeiling() {
        let rich = photo(id: "rich", year: 2025, lat: 52.1, lon: 4.8)
        let modernNoGPS = photo(id: "nogps", year: 2020, lat: nil, lon: nil)
        XCTAssertTrue(AdaptiveEvidenceScheduling.isMetadataRichRefinement(rich, now: now))
        XCTAssertFalse(AdaptiveEvidenceScheduling.isMetadataRichRefinement(modernNoGPS, now: now))
        XCTAssertLessThanOrEqual(AdaptiveEvidenceScheduling.analysisPriority(rich, now: now),
                                 AdaptiveEvidenceScheduling.refinementMaxPriority)
    }

    func testModernNoGPSMidBandDemotesBurstsAnimatedAndLivePhotos() {
        let photoNoGPS = photo(id: "photo", year: 2020, lat: nil, lon: nil)
        let burst = photo(id: "burst", year: 2020, lat: nil, lon: nil, category: .bursts)
        let animated = photo(id: "anim", year: 2021, lat: nil, lon: nil, category: .animated)
        let live = photo(id: "live", year: 2022, lat: nil, lon: nil, category: .livePhotos)
        var withBurstID = photo(id: "burst-id", year: 2020, lat: nil, lon: nil)
        withBurstID.burstIdentifier = "burst-1"
        let thinOld = photo(id: "old", year: 2003, lat: nil, lon: nil)
        let recentGPS = photo(id: "rich", year: 2025, lat: 52.1, lon: 4.8)

        XCTAssertEqual(AdaptiveEvidenceScheduling.analysisPriority(photoNoGPS, now: now), 65)
        XCTAssertEqual(AdaptiveEvidenceScheduling.analysisPriority(burst, now: now), 45)
        XCTAssertEqual(AdaptiveEvidenceScheduling.analysisPriority(animated, now: now), 45)
        XCTAssertEqual(AdaptiveEvidenceScheduling.analysisPriority(live, now: now), 45)
        XCTAssertEqual(AdaptiveEvidenceScheduling.analysisPriority(withBurstID, now: now), 45)
        XCTAssertEqual(AdaptiveEvidenceScheduling.analysisPriority(photo(id: "y2009", year: 2009, lat: nil, lon: nil), now: now), 80)
        XCTAssertGreaterThan(AdaptiveEvidenceScheduling.analysisPriority(thinOld, now: now),
                             AdaptiveEvidenceScheduling.analysisPriority(photoNoGPS, now: now))
        XCTAssertGreaterThan(AdaptiveEvidenceScheduling.analysisPriority(photoNoGPS, now: now),
                             AdaptiveEvidenceScheduling.analysisPriority(burst, now: now))
        XCTAssertGreaterThan(AdaptiveEvidenceScheduling.analysisPriority(burst, now: now),
                             AdaptiveEvidenceScheduling.refinementMaxPriority)
        XCTAssertGreaterThan(AdaptiveEvidenceScheduling.analysisPriority(burst, now: now),
                             AdaptiveEvidenceScheduling.analysisPriority(recentGPS, now: now))
        XCTAssertFalse(AdaptiveEvidenceScheduling.isMetadataRichRefinement(burst, now: now))
    }

    func testDedicatedCameraWithoutGPSGetsPreGeotagPriority() {
        var body = photo(id: "body", year: 2018, lat: nil, lon: nil)
        body.cameraMake = "Canon"
        body.cameraModel = "EOS 6D"
        var raw = photo(id: "raw", year: 2018, lat: nil, lon: nil)
        raw.sourceUTI = "com.adobe.raw-image"
        var phone = photo(id: "phone", year: 2018, lat: nil, lon: nil)
        phone.cameraMake = "Apple"
        phone.cameraModel = "iPhone"
        let plainNoGPS = photo(id: "plain", year: 2018, lat: nil, lon: nil)
        let recentGPS = photo(id: "rich", year: 2025, lat: 52.1, lon: 4.8)

        XCTAssertEqual(AdaptiveEvidenceScheduling.analysisPriority(body, now: now), 80)
        XCTAssertEqual(AdaptiveEvidenceScheduling.analysisPriority(raw, now: now), 80)
        XCTAssertEqual(AdaptiveEvidenceScheduling.analysisPriority(phone, now: now), 65)
        XCTAssertEqual(AdaptiveEvidenceScheduling.analysisPriority(plainNoGPS, now: now), 65)
        XCTAssertTrue(AdaptiveEvidenceScheduling.looksDedicatedCamera(body))
        XCTAssertFalse(AdaptiveEvidenceScheduling.looksDedicatedCamera(phone))
        XCTAssertGreaterThan(AdaptiveEvidenceScheduling.analysisPriority(body, now: now),
                             AdaptiveEvidenceScheduling.analysisPriority(recentGPS, now: now))
        XCTAssertFalse(AdaptiveEvidenceScheduling.isMetadataRichRefinement(body, now: now))
    }

    func testRefreshReprioritizesPendingZeroPriorityJobs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CuratorStore(url: root.appendingPathComponent("index.sqlite3"))
        let thin = photo(id: "thin", year: 2002, lat: nil, lon: nil)
        let rich = photo(id: "rich", year: 2024, lat: 48.8, lon: 2.3)
        try store.save([thin, rich], generation: "g")
        try store.enqueueAnalysis(asset: thin.id, revision: thin.analysisRevision, analyzer: "v", priority: 0)
        try store.enqueueAnalysis(asset: rich.id, revision: rich.analysisRevision, analyzer: "v", priority: 0)
        XCTAssertGreaterThanOrEqual(try store.refreshAdaptiveAnalysisPriorities(), 2)
        let first = try XCTUnwrap(store.claimAnalysis(now: now))
        XCTAssertEqual(first.asset, "thin")
    }

    func testJourneyEnrichmentRecoveryCadenceWhenShellsDominate() {
        XCTAssertTrue(JourneyEnrichmentScheduling.needsTitleRecovery(journeyCount: 36, finalizedCount: 1))
        XCTAssertTrue(JourneyEnrichmentScheduling.needsTitleRecovery(journeyCount: 36, finalizedCount: 2))
        XCTAssertEqual(JourneyEnrichmentScheduling.cadence(journeyCount: 36, finalizedCount: 2), 1)
        XCTAssertEqual(JourneyEnrichmentScheduling.maximumLookups(journeyCount: 36, finalizedCount: 2), 8)
        XCTAssertFalse(JourneyEnrichmentScheduling.needsTitleRecovery(journeyCount: 12, finalizedCount: 6))
        XCTAssertFalse(JourneyEnrichmentScheduling.needsTitleRecovery(journeyCount: 36, finalizedCount: 20))
        XCTAssertEqual(JourneyEnrichmentScheduling.cadence(journeyCount: 36, finalizedCount: 20), 15)
        XCTAssertEqual(JourneyEnrichmentScheduling.maximumLookups(journeyCount: 12, finalizedCount: 6), 4)
    }

    func testAnalysisLanesStayBoundedAndDropOnThermal() {
        XCTAssertEqual(AnalysisLaneBudget.capacity(lowPower: false, thermal: .nominal, processorCount: 12), 3)
        XCTAssertEqual(AnalysisLaneBudget.capacity(lowPower: false, thermal: .nominal, processorCount: 4), 1)
        XCTAssertEqual(AnalysisLaneBudget.capacity(lowPower: true, thermal: .nominal, processorCount: 16), 1)
        XCTAssertEqual(AnalysisLaneBudget.capacity(lowPower: false, thermal: .critical, processorCount: 16), 1)
        XCTAssertLessThanOrEqual(AnalysisLaneBudget.maxLanes, 3)
    }

    func testClaimBatchKeepsRefinementParkedWhileThinWorkRuns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CuratorStore(url: root.appendingPathComponent("index.sqlite3"))
        let rich = photo(id: "rich", year: 2025, lat: 41.4, lon: 2.1)
        let thinA = photo(id: "thin-a", year: 2004, lat: nil, lon: nil)
        let thinB = photo(id: "thin-b", year: 2005, lat: nil, lon: nil)
        let thinC = photo(id: "thin-c", year: 2006, lat: nil, lon: nil)
        try store.save([rich, thinA, thinB, thinC], generation: "g")
        for photo in [rich, thinA, thinB, thinC] {
            try store.enqueueAnalysis(asset: photo.id, revision: photo.analysisRevision, analyzer: "v",
                                      priority: AdaptiveEvidenceScheduling.analysisPriority(photo, now: now))
        }
        let batch = try store.claimAnalysis(limit: 3, now: now)
        XCTAssertEqual(Set(batch.map(\.asset)), ["thin-a", "thin-b", "thin-c"])
        XCTAssertNil(try store.claimAnalysis(now: now),
                     "GPS-rich refinement must stay parked while thin lanes are in flight")
    }
}
