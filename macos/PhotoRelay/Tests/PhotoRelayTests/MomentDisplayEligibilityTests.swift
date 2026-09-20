import XCTest
import SwiftUI
@testable import PhotoRelay

final class MomentDisplayEligibilityTests: XCTestCase {
    func testFeedPromotionPreservesEndorsementsAndDoesNotMergeSmallSets() {
        var single = moment([photo("a")])
        single.selection = MomentSelector.select(single.photos, results: ["a": result()])
        XCTAssertTrue(MomentDisplayEligibility.isSupportingCollection(single, decisions: [:], userAuthored: false))
        XCTAssertFalse(MomentDisplayEligibility.isSupportingCollection(single, decisions: ["a": .include], userAuthored: false))
        XCTAssertFalse(MomentDisplayEligibility.isSupportingCollection(single, decisions: [:], userAuthored: true))
        var favorite = moment([photo("fav", favorite: true)])
        favorite.selection = MomentSelector.select(favorite.photos, results: ["fav": result()])
        XCTAssertFalse(MomentDisplayEligibility.isSupportingCollection(favorite, decisions: [:], userAuthored: false))
        var pair = moment([photo("a"), photo("b")])
        pair.selection = MomentSelector.select(pair.photos, results: ["a": result(), "b": result()])
        XCTAssertFalse(MomentDisplayEligibility.isSupportingCollection(pair, decisions: [:], userAuthored: false))
        XCTAssertTrue(MomentDisplayEligibility.isSupportingCollection(pair, decisions: ["a": .exclude, "b": .exclude], userAuthored: false))
        XCTAssertEqual(pair.photos.map(\.id), ["a", "b"])
    }

    private func photo(_ id: String, favorite: Bool = false, screenshot: Bool = false) -> IndexedPhoto {
        IndexedPhoto(id: id, created: Date(timeIntervalSince1970: 100), modified: nil,
            latitude: nil, longitude: nil, favorite: favorite, width: 100, height: 100,
            similarityCategory: screenshot ? .screenshots : .photos)
    }
    private func result(utility: Bool = false) -> CuratorVisionResult {
        CuratorVisionResult(version: CuratorVisionAnalyzer.version, faces: .available(0),
            aesthetics: .available(AestheticSignal(score: 0.5, utility: utility)), featurePrint: .unavailable)
    }
    private func moment(_ photos: [IndexedPhoto]) -> PhotoMoment {
        PhotoMoment(id: "test", start: photos[0].created!, end: photos.last!.created!, photos: photos)
    }
    private var menu: [PhotoTextLine] {
        ["STARTERS", "SOUPS", "DESSERTS", "SALAD", "FRIES", "BURGER"].map { PhotoTextLine(text: $0, confidence: 1) }
    }
    private func classify(_ labels: [String], text: [PhotoTextLine] = [], utility: Bool = false) -> PhotoDisplayEvidence? {
        MomentDisplayEligibility.classify(photo("a"), labels: labels, lines: text, result: result(utility: utility))
    }

    func testScreenshotsMenusAndCorroboratedMapsHaveSeparateRoles() {
        XCTAssertEqual(MomentDisplayEligibility.classify(photo("screen", screenshot: true), labels: [], lines: [], result: nil)?.reason, .screenshot)
        XCTAssertEqual(classify(["structure"], text: menu)?.reason, .menu)
        XCTAssertEqual(classify(["map", "document"])?.reason, .map)
        XCTAssertEqual(classify(["document"], text: menu.map { PhotoTextLine(text: "Reference text", confidence: $0.confidence) })?.reason, .document)
        XCTAssertNil(classify(["map"]))
        XCTAssertNil(classify(["document"]))
    }

    func testUtilitySignalAloneAndTextOnMeaningfulSubjectsCannotRejectThem() {
        XCTAssertNil(classify([], utility: true))
        for label in ["people", "adult", "doll", "toy", "figurine", "painting", "sculpture", "flower", "food"] {
            XCTAssertNil(classify([label, "document"], text: menu, utility: true), label)
        }
        XCTAssertNil(classify(["sign"], text: [PhotoTextLine(text: "BISTRO GARDEN", confidence: 1)]))
    }

    func testUncertainOrStaleSignalsDoNotSuppress() {
        for score: Float in [0.89, .nan, .infinity, -1] {
            XCTAssertNil(classify(["structure"], text: menu.map { PhotoTextLine(text: $0.text, confidence: score) }))
        }
        let stale = CuratorVisionResult(version: "old", faces: .available(0),
            aesthetics: .available(AestheticSignal(score: 0.5, utility: true)), featurePrint: .unavailable)
        XCTAssertNil(MomentDisplayEligibility.classify(photo("a"), labels: ["document"], lines: [], result: stale))
    }

    func testDenseFoodReferencesNeedDiverseCluesNotRepeatedWords() {
        let repeated = (0..<12).map { _ in PhotoTextLine(text: "STEAK STEAKS", confidence: 1) }
        XCTAssertNil(classify(["structure"], text: repeated))
        var varied = repeated
        varied[0] = PhotoTextLine(text: "BURGERS RIBS SHRIMPS", confidence: 1)
        XCTAssertEqual(classify(["structure"], text: varied)?.reason, .menu)
        XCTAssertNil(classify(["structure"], text: Array(varied.prefix(5))))
    }

    func testContextIsRemovedBeforeSimilarityAndBalancedRanking() throws {
        let photos = [photo("a-menu"), photo("b-scene")]
        var group = moment(photos)
        group.displayEvidence = ["a-menu": classify(["structure"], text: menu)!]
        // The fixture evidence must refer to the actual asset's revision.
        let candidates = MomentDisplayEligibility.automaticCandidates(in: group)
        let results = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, result()) })
        let raw = MomentSelector.select(candidates, results: results, distance: { _, _ in 0 })
        let selection = BalancedMomentSelector.select(MomentDisplayEligibility.annotate(raw, moment: group), photos: photos, results: results)
        XCTAssertEqual(selection.selected, ["b-scene"])
        XCTAssertEqual(selection.contextOnly, ["a-menu"])
        XCTAssertTrue(selection.similar.isEmpty)
        XCTAssertEqual(group.photos.count, 2)
        XCTAssertEqual(MomentDisplayEligibility.cover(group, decisions: [:], selected: selection.selected)?.id, "b-scene")
    }

    @MainActor
    func testManualIncludeFavoriteAndExcludeTakePrecedence() throws {
        let screenshot = photo("screen", screenshot: true)
        let group = moment([screenshot])
        let selection = MomentDisplayEligibility.annotate(MomentSelection(selected: [], pending: [], similar: []), moment: group)
        XCTAssertNil(MomentDisplayEligibility.cover(group, decisions: [:], selected: []))
        let included = MomentReviewDecisions.apply(["screen": .include], to: selection, photos: group.photos)
        XCTAssertEqual(included.selected, ["screen"])
        XCTAssertEqual(included.contextOnly, [])
        XCTAssertEqual(MomentDisplayEligibility.cover(group, decisions: ["screen": .include], selected: included.selected)?.id, "screen")
        let favored = moment([photo("fav", favorite: true, screenshot: true)])
        XCTAssertEqual(MomentDisplayEligibility.automaticCandidates(in: favored).map(\.id), ["fav"])
        XCTAssertFalse(MomentDisplayEligibility.isContextOnly(favored, decisions: [:], userAuthored: false))
        XCTAssertNil(MomentDisplayEligibility.cover(favored, decisions: ["fav": .exclude], selected: ["fav"]))
    }

    func testContextOnlyPhotoCanBeBrowsingCoverWithoutBecomingHighlight() {
        let screenshot = photo("screen", screenshot: true)
        let group = moment([screenshot])
        XCTAssertNil(MomentDisplayEligibility.cover(group, decisions: [:], selected: []))
        XCTAssertEqual(MomentDisplayEligibility.browsingCover(group, decisions: [:], selected: [])?.id, "screen")
        XCTAssertNil(MomentDisplayEligibility.browsingCover(group, decisions: ["screen": .exclude], selected: [])?.id)
    }

    func testViewportPriorityIsBoundedEndToEndAndKeepsEndorsements() {
        let photos = (0..<30).map { photo("p\($0)", favorite: $0 == 10) }
        let group = moment(photos)
        let prioritized = MomentDisplayEligibility.viewportPriorityPhotos(
            group, decisions: [:], selected: ["p17"], limit: 12)
        XCTAssertEqual(prioritized.count, 12)
        XCTAssertEqual(Set(prioritized.map(\.id)).count, 12)
        XCTAssertTrue(prioritized.contains { $0.id == "p10" })
        XCTAssertTrue(prioritized.contains { $0.id == "p17" })
        XCTAssertTrue(prioritized.contains { $0.id == "p0" })
        XCTAssertTrue(prioritized.contains { $0.id == "p29" })
    }

    func testContextOnlyCollectionsRemainRecoverableAndNamedGroupsVisible() {
        var group = moment([photo("screen", screenshot: true)])
        XCTAssertTrue(MomentDisplayEligibility.isContextOnly(group, decisions: [:], userAuthored: false))
        XCTAssertFalse(MomentDisplayEligibility.isContextOnly(group, decisions: ["screen": .include], userAuthored: false))
        XCTAssertFalse(MomentDisplayEligibility.isContextOnly(group, decisions: [:], userAuthored: true))
        group.groupingState = .reviewed
        XCTAssertFalse(MomentDisplayEligibility.isContextOnly(group, decisions: [:], userAuthored: false))
        XCTAssertEqual(group.photos.count, 1)
    }

    func testCatalogPersistsRolesAndLegacySnapshotsStillDecode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var group = moment([photo("menu")])
        group.displayEvidence = ["menu": classify(["structure"], text: menu)!]
        group.selection = MomentDisplayEligibility.annotate(MomentSelection(selected: [], pending: [], similar: []), moment: group)
        let url = root.appendingPathComponent("catalog.json")
        try MomentsCatalog(updated: Date(), moments: [group]).save(to: url)
        let read = try XCTUnwrap(MomentsCatalog.load(from: url)?.moments.first)
        XCTAssertEqual(read.displayEvidence, group.displayEvidence)
        XCTAssertEqual(read.selection?.contextOnly, ["menu"])
        XCTAssertTrue(MomentDisplayEligibility.isContextOnly(read, decisions: [:], userAuthored: false))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(group)) as? [String: Any])
        object.removeValue(forKey: "displayEvidence")
        var selection = object["selection"] as! [String: Any]
        selection.removeValue(forKey: "contextOnly")
        object["selection"] = selection
        let legacy = try JSONDecoder().decode(PhotoMoment.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.displayEvidence)
        XCTAssertNil(legacy.selection?.contextOnly)
    }

    func testChangedPhotoOrEngineInvalidatesDerivedRole() {
        let p = photo("a")
        var group = moment([p])
        for stale in [PhotoDisplayEvidence(revision: "old", engine: PhotoDisplayEvidence.version, reason: .menu),
                      PhotoDisplayEvidence(revision: p.analysisRevision, engine: "old", reason: .menu)] {
            group.displayEvidence = [p.id: stale]
            XCTAssertNil(MomentDisplayEligibility.evidence(for: p, in: group))
            XCTAssertEqual(MomentDisplayEligibility.automaticCandidates(in: group).count, 1)
        }
    }

    func testWorkerUsesExistingEvidenceWithoutRemovingAssetsOrCaptionClues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = BackgroundMomentContext(root: root.appendingPathComponent("background-context"))
        let text = MomentTextEvidenceStore(directory: root.appendingPathComponent("text-evidence"))
        let photos = [photo("menu"), photo("scene")]
        try await context.saveLabels(["structure"], for: photos[0])
        try await context.saveLabels(["people"], for: photos[1])
        _ = try await text.save(menu, for: photos[0])
        _ = try await text.save([], for: photos[1])
        let worker = CuratorWorker(url: root.appendingPathComponent("index.sqlite3"))
        let prepared = try await worker.prepareDisplaySelection(moment(photos), results: ["menu": result(), "scene": result()])
        XCTAssertEqual(prepared.selection?.selected, ["scene"])
        XCTAssertEqual(prepared.selection?.contextOnly, ["menu"])
        XCTAssertEqual(prepared.photos, photos)
        let retained = await text.cached(photos[0])
        XCTAssertEqual(retained?.lines, menu)
        let indexExists = FileManager.default.fileExists(atPath: root.appendingPathComponent("index.sqlite3").path)
        XCTAssertFalse(indexExists, "Display preparation uses caches without indexing or PhotoKit access")
    }

    @MainActor
    func testContextOnlyCardRendersWithoutLoadingPhotoPixels() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var group = moment([photo("screen", screenshot: true)])
        group.selection = MomentDisplayEligibility.annotate(MomentSelection(selected: [], pending: [], similar: []), moment: group)
        let renderer = ImageRenderer(content: MomentCoverCard(moment: group, decisions: MomentReviewDecisions(defaults: defaults))
            .frame(width: 250).environment(\.colorScheme, .light).background(Color.white))
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 250)
        XCTAssertGreaterThan(image.height, 250)
        XCTAssertLessThan(image.height, 430)
        if let path = ProcessInfo.processInfo.environment["PHOTO_RELAY_DISPLAY_RENDER"] {
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
