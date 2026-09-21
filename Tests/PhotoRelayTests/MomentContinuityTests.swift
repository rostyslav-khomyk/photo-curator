import XCTest
@testable import PhotoRelay

private struct ContinuityUnavailableModel: LocalNarrativeModel {
    let version = "continuity-test"
    func isAvailable() async -> Bool { false }
    func choose(from candidates: [MomentNarrativeText]) async throws -> Int { XCTFail("No model call expected"); return 0 }
}

final class MomentContinuityTests: XCTestCase {
    private func group(_ id: String, start: Double, latitude: Double? = 52) -> PhotoMoment {
        let photos = (0..<3).map { index in
            IndexedPhoto(id: "\(id)-\(index)", created: Date(timeIntervalSince1970: start + Double(index * 60)),
                modified: nil, latitude: latitude, longitude: latitude == nil ? nil : 5,
                favorite: false, width: 100, height: 100, similarityCategory: .photos)
        }
        return PhotoMoment(id: id, start: photos.first!.created!, end: photos.last!.created!, photos: photos)
    }
    private var pair: MomentContinuityPair {
        MomentContinuityPair(earlier: group("a", start: 43200), later: group("b", start: 50700))
    }
    private func proposal(_ pair: MomentContinuityPair, labels: [String: [String]] = [:],
                          text: [String: [PhotoTextLine]] = [:], distance: (String, String) -> Float? = { _, _ in 10 }) throws -> MomentContinuityRecord {
        try MomentContinuity.propose(pair, labels: labels, text: text, results: [:], evidenceFingerprint: "synthetic", distance: distance)
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testCorroboratedGapJoinsWithoutChangingCoordinatesAndPersists() throws {
        let pair = pair, root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MomentContinuityStore(root: root)
        let record = try proposal(pair)
        XCTAssertTrue(record.joins)
        XCTAssertNotNil(record.boundaryEstimate)
        XCTAssertTrue((0...1).contains(try XCTUnwrap(record.boundaryEstimate?.probability)))
        try store.save(record, pair: pair)
        let joined = try MomentContinuityStore(root: root).apply([pair.later, pair.earlier], protected: [])
        XCTAssertEqual(joined.count, 1)
        XCTAssertEqual(joined[0].id, pair.id)
        XCTAssertEqual(Set(joined[0].photos.map(\.id)), Set(pair.photos.map(\.id)))
        XCTAssertTrue(joined[0].photos.allSatisfy { $0.latitude == 52 && $0.longitude == 5 })
        XCTAssertNotNil(joined[0].continuityReason)
    }

    func testSameLocationAloneOneMatchAndInvalidDistancesCannotJoin() throws {
        for value: Float? in [nil, .nan, .infinity, -1, 17] {
            XCTAssertFalse(try proposal(pair, distance: { _, _ in value }).joins)
        }
        XCTAssertFalse(try proposal(pair, distance: { a, b in a == "a-0" && b == "b-0" ? 10 : 30 }).joins)
        XCTAssertFalse(try proposal(pair, distance: { a, _ in a == "a-0" ? 10 : 30 }).joins,
            "Several matches to a single source photo are insufficient")
    }

    func testMissingAndContradictoryRecordedLocationsBlockJoin() throws {
        XCTAssertFalse(try proposal(.init(earlier: pair.earlier, later: group("b", start: 50700, latitude: nil))).joins)
        XCTAssertFalse(try proposal(.init(earlier: pair.earlier, later: group("b", start: 50700, latitude: 52.1))).joins)
        var mixed = pair.earlier
        let distant = IndexedPhoto(id: "distant", created: mixed.end, modified: nil, latitude: 52.1, longitude: 5,
            favorite: false, width: 100, height: 100)
        mixed = PhotoMoment(id: mixed.id, start: mixed.start, end: mixed.end, photos: mixed.photos + [distant])
        XCTAssertFalse(try proposal(.init(earlier: mixed, later: pair.later)).joins, "All recorded GPS, not just matching pairs, must agree")
    }

    func testSamePlaceDifferentScenesOrOccasionsStaySeparate() throws {
        var labels: [String: [String]] = [:], text: [String: [PhotoTextLine]] = [:]
        for photo in pair.earlier.photos { labels[photo.id] = ["castle"]; text[photo.id] = [.init(text: "Wedding", confidence: 1)] }
        for photo in pair.later.photos { labels[photo.id] = ["beach"]; text[photo.id] = [.init(text: "Conference", confidence: 1)] }
        XCTAssertFalse(try proposal(pair, labels: labels).joins)
        XCTAssertFalse(try proposal(pair, text: text).joins)
    }

    func testUtilityImagesCannotProvideBridgeEvenWhenFavorite() throws {
        let convert: (PhotoMoment) -> PhotoMoment = { moment in
            var result = moment
            result = PhotoMoment(id: moment.id, start: moment.start, end: moment.end, photos: moment.photos.map {
                IndexedPhoto(id: $0.id, created: $0.created, modified: nil, latitude: $0.latitude, longitude: $0.longitude,
                    favorite: true, width: 100, height: 100, similarityCategory: .screenshots)
            })
            return result
        }
        XCTAssertFalse(try proposal(.init(earlier: convert(pair.earlier), later: convert(pair.later))).joins)
    }

    func testGapDayCompressedAndSizeLimits() {
        XCTAssertFalse(MomentContinuity.eligible(.init(earlier: pair.earlier, later: group("b", start: 56000))))
        XCTAssertFalse(MomentContinuity.eligible(.init(earlier: pair.earlier, later: group("b", start: 130000))))
        var compressed = pair.earlier
        compressed = PhotoMoment(id: "compressed", start: compressed.start, end: compressed.start.addingTimeInterval(8),
            photos: (0..<8).map { i in IndexedPhoto(id: "c-\(i)", created: compressed.start.addingTimeInterval(Double(i)),
                modified: nil, latitude: 52, longitude: 5, favorite: false, width: 100, height: 100) })
        XCTAssertFalse(MomentContinuity.eligible(.init(earlier: compressed, later: pair.later)))
        let large = PhotoMoment(id: "large", start: pair.earlier.start, end: pair.earlier.end, photos: (0..<513).map { i in
            IndexedPhoto(id: "large-\(i)", created: pair.earlier.start.addingTimeInterval(Double(i)), modified: nil,
                latitude: 52, longitude: 5, favorite: false, width: 100, height: 100)
        })
        XCTAssertFalse(MomentContinuity.eligible(.init(earlier: large, later: pair.later)))
    }

    func testNoChainingOrJumpingOverInterveningGroups() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let a = pair.earlier, b = pair.later, c = group("c", start: 58200)
        let store = MomentContinuityStore(root: root)
        for pair in MomentContinuity.pairs([a, b, c], protected: []) { try store.save(proposal(pair), pair: pair) }
        let first = try store.apply([a, b, c], protected: [])
        let reversed = try store.apply([c, b, a], protected: [])
        XCTAssertEqual(first.map(\.id), reversed.map(\.id))
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(Set(first.flatMap(\.photos).map(\.id)).count, 9)
        XCTAssertLessThanOrEqual(first.map { $0.photos.count }.max()!, 6)
        let intervening = group("between", start: 48000)
        XCTAssertFalse(MomentContinuity.pairs([a, intervening, b], protected: []).contains { $0.earlier.id == a.id && $0.later.id == b.id })
    }

    func testSavedSplitNamedGroupsAndProtectedChildrenWin() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let pair = pair, store = MomentContinuityStore(root: root.appendingPathComponent("event-continuity"))
        try store.save(proposal(pair), pair: pair)
        XCTAssertEqual(try store.apply([pair.earlier, pair.later], protected: [pair.earlier.id]).count, 2)
        let review = GroupReviewArchive(groups: [.init(id: "saved-left", title: "My first occasion", members: Set(pair.earlier.photos.map(\.id))),
            .init(id: "saved-right", title: "My second occasion", members: Set(pair.later.photos.map(\.id)))])
        let reviewed = MomentCatalogGrouping.build(pair.photos, reviews: review)
        XCTAssertEqual(try store.apply(reviewed, protected: []).map(\.id), reviewed.map(\.id))
        let db = try CuratorStore(url: root.appendingPathComponent("index.sqlite3"))
        try db.save(pair.photos, generation: "test")
        let base = MomentGrouping.group(pair.photos)
        let actualPair = MomentContinuityPair(earlier: base[1], later: base[0])
        try store.save(proposal(actualPair), pair: actualPair)
        let automatic = AutomaticMomentStore(root: root.appendingPathComponent("automatic-moments"))
        try automatic.save(.init(fingerprint: AutomaticMomentSegmentation.fingerprint(base[1]), segments: [
            .init(id: "named-child", members: base[1].photos.map(\.id), reason: "test")]), for: base[1])
        let worker = CuratorWorker(url: root.appendingPathComponent("index.sqlite3"))
        let protected = try await worker.preparedCatalog(protection: .init(ids: ["named-child"]))
        XCTAssertEqual(protected.count, 2)
        XCTAssertTrue(protected.contains { $0.id == "named-child" })
    }

    func testEditedMetadataInvalidatesSavedDecisionAndCancellationWritesNothing() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MomentContinuityStore(root: root), pair = pair
        let record = try proposal(pair)
        try store.save(record, pair: pair)
        let changed = MomentContinuityPair(earlier: pair.earlier, later: group("b", start: 50701))
        XCTAssertNil(try store.load(changed))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try store.save(record, pair: pair)
        }
        do { try await task.value; XCTFail("Cancellation must propagate") } catch is CancellationError { }
        XCTAssertEqual(try store.load(pair)?.evidenceFingerprint, record.evidenceFingerprint)
    }

    func testMissingAnalysisDefersContinuityWithoutSavingARejection() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try CuratorStore(url: root.appendingPathComponent("index.sqlite3"))
        try db.save(pair.photos, generation: "test")
        let worker = CuratorWorker(url: root.appendingPathComponent("index.sqlite3"))
        _ = try await worker.prepareMoments(range: nil, protection: .init(), model: ContinuityUnavailableModel())
        let catalog = try await worker.preparedCatalog(protection: .init())
        XCTAssertEqual(catalog.count, 2)
        XCTAssertTrue(catalog.allSatisfy { $0.groupingState == .preparing })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("event-continuity").path))
    }

    func testShortGapNeedsMultipleMatchesAndRejectsConflictsAndOverlap() throws {
        let short = MomentContinuityPair(earlier: pair.earlier, later: group("b", start: 43500))
        XCTAssertTrue(try proposal(short).joins)
        XCTAssertFalse(try proposal(short, distance: { a, _ in a == "a-0" ? 1 : 30 }).joins)
        XCTAssertFalse(try proposal(.init(earlier: pair.earlier, later: group("b", start: 43500, latitude: 53))).joins)
        XCTAssertFalse(try proposal(.init(earlier: pair.earlier, later: group("b", start: 43260))).joins)
        var labels: [String: [String]] = [:]
        for p in short.earlier.photos { labels[p.id] = ["castle"] }
        for p in short.later.photos { labels[p.id] = ["beach"] }
        XCTAssertFalse(try proposal(short, labels: labels).joins)
    }

    func testPreparedCatalogReconcilesAdjacentAutomaticSections() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let short = MomentContinuityPair(earlier: pair.earlier, later: group("b", start: 43500))
        let db = try CuratorStore(url: root.appendingPathComponent("index.sqlite3"))
        try db.save(short.photos, generation: "test")
        let parent = MomentGrouping.group(short.photos)[0]
        let automatic = AutomaticMomentStore(root: root.appendingPathComponent("automatic-moments"))
        try automatic.save(.init(fingerprint: AutomaticMomentSegmentation.fingerprint(parent), segments: [
            .init(id: "a", members: short.earlier.photos.map(\.id), reason: "scene"),
            .init(id: "b", members: short.later.photos.map(\.id), reason: "scene")]), for: parent)
        let children = try automatic.apply(parent, protected: [])
        let actual = MomentContinuity.pairs(children, protected: [])[0]
        let store = MomentContinuityStore(root: root.appendingPathComponent("event-continuity"))
        try store.save(proposal(actual), pair: actual)
        let worker = CuratorWorker(url: root.appendingPathComponent("index.sqlite3"))
        let result = try await worker.preparedCatalog(protection: .init())
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(Set(result[0].photos.map(\.id)), Set(short.photos.map(\.id)))
    }
}
