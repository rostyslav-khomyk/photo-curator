import XCTest
import ImageIO
@testable import PhotoRelay

private final class FakeNarrativeModel: LocalNarrativeModel {
    var version = "test1"
    var available = true
    var calls = 0
    var choice = 1
    var fail = false
    var receivedEvidence: MomentCaptionEvidence?
    func isAvailable() async -> Bool { available }
    func choose(from candidates: [MomentNarrativeText]) async throws -> Int {
        calls += 1
        if fail { throw NarrativeFailure.invalidResponse }
        return choice
    }
    func choose(from candidates: [MomentNarrativeText], evidence: MomentCaptionEvidence?) async throws -> Int {
        receivedEvidence = evidence
        return try await choose(from: candidates)
    }
}

final class LocalNarrativeTests: XCTestCase {
    func testCanonicalNarrativePreservesManualPrecedenceAcrossSurfaces() {
        let photo = IndexedPhoto(id: "a", created: Date(timeIntervalSince1970: 1), modified: nil,
            latitude: nil, longitude: nil, favorite: false, width: 10, height: 10)
        var moment = PhotoMoment(id: "m", start: photo.created!, end: photo.created!, photos: [photo])
        moment.narrative = .init(version: MomentNarrative.version, headline: "Automatic title", deck: nil,
            story: "Automatic story", place: nil, date: "Today", confidence: 0.8, provenance: ["test"], state: .automatic)
        let automatic = MomentPresentation.narrative(moment, customTitle: nil)
        XCTAssertEqual(automatic.headline, "Automatic title")
        XCTAssertEqual(automatic.story, "Automatic story")
        XCTAssertEqual(automatic.state, .automatic)
        let custom = MomentPresentation.narrative(moment, customTitle: "My trip", customDescription: "My story")
        XCTAssertEqual(custom.headline, "My trip")
        XCTAssertEqual(custom.story, "My story")
        XCTAssertEqual(custom.state, .customized)
        XCTAssertEqual(MomentPresentation.title(moment, custom: "My trip"), custom.headline)
    }
    func testVisualHintsUsePhotographerLanguageWithoutClaimingAnEvent() throws {
        let metadata = MomentNarrativeMetadata(dateLabel: "Today", photoCount: 2, favoriteCount: 0,
                                              verifiedPlace: nil, visualLabels: ["architecture", "tree"])
        let options = try LocalMomentNarrative.candidates(metadata)
        XCTAssertEqual(options[0].title, "Architecture")
        XCTAssertFalse(options[0].title.localizedCaseInsensitiveContains("possible"))
    }
    func testOptInRealExportedPhotoReadOnly() async throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTO_RELAY_TEST_REAL_PHOTO"] else {
            throw XCTSkip("Opt-in read-only exported-photo test")
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024
        ] as CFDictionary))
        let labels = try await NarrativeVisualContext().labels(image)
        let realMetadata = MomentNarrativeMetadata(dateLabel: "Photo review", photoCount: 1, favoriteCount: 0,
                                                  verifiedPlace: nil, visualLabels: labels)
        let model = AppleLocalNarrativeModel()
        guard await model.isAvailable() else { throw XCTSkip("Local model unavailable") }
        let options = try LocalMomentNarrative.candidates(realMetadata)
        let index = try await model.choose(from: options)
        XCTAssertTrue(options.indices.contains(index))
        print("Real-photo read-only check: \(labels.count) visual labels; model selected valid candidate \(index).")
    }
    func testOptInAppleModelWithSyntheticMetadata() async throws {
        guard ProcessInfo.processInfo.environment["PHOTO_RELAY_TEST_LOCAL_MODEL"] == "1" else {
            throw XCTSkip("Opt-in local model smoke test")
        }
        let model = AppleLocalNarrativeModel()
        guard await model.isAvailable() else { throw XCTSkip("Apple local model unavailable") }
        let options = try LocalMomentNarrative.candidates(metadata)
        let index = try await model.choose(from: options)
        XCTAssertTrue(options.indices.contains(index))
        let evidence = MomentCaptionEvidence(inspected: 3, total: 12, excludedScreenshots: 0, mixedTimeline: false,
            activities: [CaptionActivityEvidence(activity: .dining, assets: ["synthetic-a", "synthetic-b"])],
            textClues: [CaptionTextClue(text: "BISTRO GARDEN", asset: "synthetic-a", revision: "synthetic", confidence: 1, kind: "business sign")])
        let enriched = MomentNarrativeMetadata(dateLabel: "Today", photoCount: 12, favoriteCount: 2,
            verifiedPlace: nil, contextEvidence: evidence)
        let grounded = try LocalMomentNarrative.candidates(enriched)
        let groundedIndex = try await model.choose(from: grounded, evidence: evidence)
        XCTAssertTrue(grounded.indices.contains(groundedIndex), "Evidence-aware prompt must produce a valid bounded choice")
    }
    private let metadata = MomentNarrativeMetadata(dateLabel: "20 July 2026", photoCount: 12, favoriteCount: 2, verifiedPlace: "Delft")
    private func url() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("cache.json") }

    func testGroundedSuggestionCacheAndVersionInvalidation() async throws {
        let url = url(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = FakeNarrativeModel()
        let first = try await LocalMomentNarrative(cacheURL: url).suggest(metadata, model: model)
        XCTAssertFalse(first.text.title.localizedCaseInsensitiveContains("photos from"))
        _ = try await LocalMomentNarrative(cacheURL: url).suggest(metadata, model: model)
        XCTAssertEqual(model.calls, 1)
        model.version = "test2"
        _ = try await LocalMomentNarrative(cacheURL: url).suggest(metadata, model: model)
        XCTAssertEqual(model.calls, 2)
    }

    func testUnavailableAndMalformedResponsesFallBack() async throws {
        let url = url(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = LocalMomentNarrative(cacheURL: url), model = FakeNarrativeModel()
        model.available = false
        let unavailable = try await engine.suggest(metadata, model: model)
        XCTAssertEqual(unavailable.source, "Deterministic fallback")
        XCTAssertEqual(model.calls, 0)
        model.available = true; model.choice = 999
        let invalid = try await engine.suggest(metadata, model: model)
        XCTAssertEqual(invalid.text, unavailable.text)
        model.fail = true
        let failed = try await engine.suggest(metadata, model: model)
        XCTAssertEqual(failed.source, "Deterministic fallback")
    }

    func testMissingPlaceNeverInventsOneAndChangedMetadataMissesCache() async throws {
        let url = url(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = FakeNarrativeModel(), engine = LocalMomentNarrative(cacheURL: url)
        _ = try await engine.suggest(metadata, model: model)
        let unknown = MomentNarrativeMetadata(dateLabel: "21 July 2026", photoCount: 3, favoriteCount: 0, verifiedPlace: nil)
        let value = try await engine.suggest(unknown, model: model)
        XCTAssertFalse(value.text.title.contains("Delft"))
        XCTAssertEqual(model.calls, 2)
        XCTAssertThrowsError(try LocalMomentNarrative.candidates(MomentNarrativeMetadata(dateLabel: "", photoCount: -1, favoriteCount: 0, verifiedPlace: nil)))
    }

    func testEvidenceReachesModelAndChangedEvidenceInvalidatesChoice() async throws {
        let url = url(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = FakeNarrativeModel(), engine = LocalMomentNarrative(cacheURL: url)
        var enriched = metadata
        enriched.contextEvidence = MomentCaptionEvidence(inspected: 3, total: 12, excludedScreenshots: 0, mixedTimeline: false,
            activities: [CaptionActivityEvidence(activity: .dining, assets: ["a", "b"])], textClues: [])
        _ = try await engine.suggest(enriched, model: model)
        XCTAssertEqual(model.receivedEvidence, enriched.contextEvidence)
        _ = try await engine.suggest(enriched, model: model)
        XCTAssertEqual(model.calls, 1)
        enriched.contextEvidence = MomentCaptionEvidence(inspected: 3, total: 12, excludedScreenshots: 0, mixedTimeline: true,
            activities: [], textClues: [])
        let changed = try await engine.suggest(enriched, model: model)
        XCTAssertEqual(model.calls, 2)
        XCTAssertEqual(changed.text.title, "20 July 2026 in Delft")
    }

    func testPlaceGroundedCandidateGenerationWithAndWithoutActivity() throws {
        let diningEvidence = MomentCaptionEvidence(
            inspected: 4, total: 10, excludedScreenshots: 0, mixedTimeline: false,
            activities: [CaptionActivityEvidence(activity: .dining, assets: ["1", "2"])],
            textClues: []
        )
        let frejusMetadata = MomentNarrativeMetadata(
            dateLabel: "Today", photoCount: 10, favoriteCount: 3,
            verifiedPlace: "Fréjus", contextEvidence: diningEvidence
        )
        let frejusCandidates = try LocalMomentNarrative.candidates(frejusMetadata)
        XCTAssertTrue(frejusCandidates.contains { $0.title == "Food and dining in Fréjus" })
        XCTAssertFalse(frejusCandidates.contains { $0.title.contains("·") || $0.title.localizedCaseInsensitiveContains("in pictures") })
        XCTAssertTrue(frejusCandidates.first?.description.contains("in Fréjus") == true)

        let woerdenMetadata = MomentNarrativeMetadata(
            dateLabel: "15 August 2026", photoCount: 8, favoriteCount: 1,
            verifiedPlace: "Woerden", contextEvidence: nil
        )
        let woerdenCandidates = try LocalMomentNarrative.candidates(woerdenMetadata)
        XCTAssertTrue(woerdenCandidates.contains { $0.title == "15 August 2026 in Woerden" })
        XCTAssertFalse(woerdenCandidates.contains { $0.title.localizedCaseInsensitiveContains("photos from") })
        XCTAssertFalse(woerdenCandidates.contains { $0.title.localizedCaseInsensitiveContains("in pictures") })
        XCTAssertTrue(woerdenCandidates.contains { $0.description.contains("Woerden") })
    }

    func testPlaceAndTextClueWithoutRoboticDisclaimer() throws {
        let metadata = MomentNarrativeMetadata(
            dateLabel: "29 August 2026",
            photoCount: 2,
            favoriteCount: 0,
            verifiedPlace: "Prins Alexander, Rotterdam",
            textClue: "Pond of Water Lilies"
        )
        let candidates = try LocalMomentNarrative.candidates(metadata)
        let top = try XCTUnwrap(candidates.first)
        XCTAssertTrue(top.title.contains("Pond of Water Lilies"))
        XCTAssertTrue(top.title.contains("Prins Alexander, Rotterdam"))
        XCTAssertTrue(top.description.contains("Prins Alexander, Rotterdam"))
        XCTAssertTrue(top.description.contains("Pond of Water Lilies"))
        XCTAssertFalse(top.description.contains("not a verified place"), "Should not contain robotic disclaimers when place is verified")
        XCTAssertFalse(top.description.contains("uncertain visual hints"), "Should not contain robotic disclaimers")
    }
}
