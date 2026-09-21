import XCTest
@testable import PhotoRelay

private struct UnavailableCaptionModel: LocalNarrativeModel {
    let version = "synthetic-unavailable"
    func isAvailable() async -> Bool { false }
    func choose(from candidates: [MomentNarrativeText]) async throws -> Int { XCTFail("Unavailable model invoked"); return 0 }
}

final class BackgroundContextTests: XCTestCase {
    func testWaitsForEvidenceThenPersistsFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackgroundMomentContext(root: root)
        let text = MomentTextEvidenceStore(directory: root.appendingPathComponent("text-evidence"))
        let photo = IndexedPhoto(id: "synthetic", created: Date(timeIntervalSince1970: 1), modified: nil,
                                 latitude: nil, longitude: nil, favorite: false, width: 100, height: 100)
        let moment = MomentGrouping.group([photo])[0]
        let before = try await store.prepare(moment, model: UnavailableCaptionModel())
        XCTAssertFalse(before)
        try await store.saveLabels(["castle", "people"], for: photo)
        let labelsOnly = try await store.prepare(moment, model: UnavailableCaptionModel())
        XCTAssertFalse(labelsOnly, "OCR must finish before a caption is prepared")
        _ = try await text.save([], for: photo)
        let prepared = try await store.prepare(moment, model: UnavailableCaptionModel())
        XCTAssertTrue(prepared)
        let caption = await BackgroundMomentContext(root: root).cached(moment)
        XCTAssertEqual(caption?.narrative.headline, moment.start.formatted(date: .abbreviated, time: .omitted), "One label is not a supported activity")
        XCTAssertEqual(caption?.evidence?.inspected, 1)
        XCTAssertEqual(caption?.narrative.provenance.first, "Deterministic fallback")
        let repeated = try await store.prepare(moment, model: UnavailableCaptionModel())
        XCTAssertFalse(repeated)
        let edited = IndexedPhoto(id: photo.id, created: photo.created, modified: Date(),
                                  latitude: nil, longitude: nil, favorite: false, width: 100, height: 100)
        let stale = await store.cached(MomentGrouping.group([edited])[0])
        XCTAssertNil(stale)
    }

    func testLateOCRRefreshesCaptionAndKeepsProvenanceAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackgroundMomentContext(root: root)
        let text = MomentTextEvidenceStore(directory: root.appendingPathComponent("text-evidence"))
        let photos = (0..<2).map { IndexedPhoto(id: "test-\($0)", created: Date(timeIntervalSince1970: Double($0 * 120)),
            modified: nil, latitude: nil, longitude: nil, favorite: false, width: 100, height: 100, similarityCategory: .photos) }
        let moment = MomentGrouping.group(photos)[0]
        for photo in photos {
            try await store.saveLabels(["structure", "sign"], for: photo)
            _ = try await text.save([], for: photo)
        }
        _ = try await store.prepare(moment, model: UnavailableCaptionModel())
        let before = await store.cached(moment)
        for photo in photos {
            _ = try await text.save([PhotoTextLine(text: "BISTRO GARDEN", confidence: 1)], for: photo)
        }
        let changed = try await store.prepare(moment, model: UnavailableCaptionModel())
        XCTAssertTrue(changed, "Evidence changes bypass an unavailable-model retry delay")
        let after = await BackgroundMomentContext(root: root).cached(moment)
        XCTAssertNotEqual(after?.evidenceFingerprint, before?.evidenceFingerprint)
        XCTAssertEqual(after?.narrative.headline, "Food and dining")
        XCTAssertEqual(after?.evidence?.textClues.first?.text, "BISTRO GARDEN")
        XCTAssertTrue(after?.narrative.story?.contains("BISTRO GARDEN") == true)
        XCTAssertTrue(photos.map(\.id).contains(after?.evidence?.textClues.first?.asset ?? ""))
    }

    func testScreenshotNeedsNoOCRAndCancellationSavesNoCaption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackgroundMomentContext(root: root)
        let photo = IndexedPhoto(id: "screen", created: Date(), modified: nil, latitude: nil, longitude: nil,
            favorite: false, width: 100, height: 100, similarityCategory: .screenshots)
        let moment = MomentGrouping.group([photo])[0]
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.prepare(moment, model: UnavailableCaptionModel())
        }
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError { }
        let absent = await store.cached(moment)
        XCTAssertNil(absent)
        let ready = try await store.prepare(moment, model: UnavailableCaptionModel())
        XCTAssertTrue(ready)
        let caption = await store.cached(moment)
        XCTAssertEqual(caption?.evidence?.inspected, 0)
        XCTAssertEqual(caption?.evidence?.excludedScreenshots, 1)
    }

    func testPartialEvidencePreparesWhenThresholdReached() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackgroundMomentContext(root: root)
        let text = MomentTextEvidenceStore(directory: root.appendingPathComponent("text-evidence"))
        let photos = (0..<10).map { i in
            IndexedPhoto(id: "photo-\(i)", created: Date(timeIntervalSince1970: Double(i * 100)),
                         modified: nil, latitude: nil, longitude: nil, favorite: false,
                         width: 100, height: 100, similarityCategory: .photos)
        }
        let moment = MomentGrouping.group(photos)[0]
        for i in 0..<4 {
            try await store.saveLabels(["castle"], for: photos[i])
            _ = try await text.save([], for: photos[i])
        }
        let ready = try await store.prepare(moment, model: UnavailableCaptionModel())
        XCTAssertTrue(ready, "Threshold of 4 analyzed photos allows early caption preparation")
        let caption = await store.cached(moment)
        XCTAssertEqual(caption?.evidence?.inspected, 4)
        XCTAssertEqual(caption?.narrative.headline, "Castle views")
    }
}
