import XCTest
import ImageIO
@testable import PhotoCurator

final class MomentTextEvidenceTests: XCTestCase {
    private func photo(_ modified: Double = 1) -> IndexedPhoto {
        IndexedPhoto(id: "synthetic/asset", created: Date(), modified: Date(timeIntervalSince1970: modified),
                     latitude: nil, longitude: nil, favorite: false, width: 100, height: 100)
    }

    func testOriginalDownloadOnlyForFailedOrLowConfidenceText() {
        XCTAssertTrue(MomentTextEvidenceStore.needsOriginal(nil))
        XCTAssertFalse(MomentTextEvidenceStore.needsOriginal([]))
        XCTAssertFalse(MomentTextEvidenceStore.needsOriginal([PhotoTextLine(text: "Madurodam", confidence: 0.9)]))
        XCTAssertTrue(MomentTextEvidenceStore.needsOriginal([
            PhotoTextLine(text: "M4dur", confidence: 0.3), PhotoTextLine(text: "dam", confidence: 0.5)
        ]))
    }

    func testCacheSurvivesReopeningAndRejectsContentEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try DerivedCacheStore(url: directory.appendingPathComponent("analysis-cache.sqlite3"))
        let store = MomentTextEvidenceStore(directory: directory, cache: cache)
        let lines = [PhotoTextLine(text: "Madurodam", confidence: 0.95)]
        let saved = try await store.save(lines, for: photo())
        XCTAssertEqual(saved.assetID, photo().id)
        let reopened = MomentTextEvidenceStore(directory: directory, cache: try DerivedCacheStore(url: cache.url))
        let cached = await reopened.cached(photo())
        XCTAssertEqual(cached?.lines, lines)
        // Metadata-only modificationDate churn must reuse OCR.
        let metadataOnly = await reopened.cached(photo(2))
        XCTAssertEqual(metadataOnly?.lines, lines)
        // Dimension change is treated as a content edit.
        let resized = IndexedPhoto(id: "synthetic/asset", created: Date(),
                                   modified: Date(timeIntervalSince1970: 1),
                                   latitude: nil, longitude: nil, favorite: false, width: 200, height: 100)
        let edited = await reopened.cached(resized)
        XCTAssertNil(edited)
    }

    func testEmptySuccessIsCachedAndCorruptionIsMiss() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try DerivedCacheStore(url: directory.appendingPathComponent("analysis-cache.sqlite3"))
        let store = MomentTextEvidenceStore(directory: directory, cache: cache)
        _ = try await store.save([], for: photo())
        let value = await store.cached(photo())
        XCTAssertEqual(value?.lines, [])
        try cache.set(Data("bad cache".utf8), namespace: .textEvidence,
                      key: MomentTextEvidenceStore.cacheKey(photo().id))
        let corrupt = await store.cached(photo())
        XCTAssertNil(corrupt)
    }

    func testRecognitionCancellationAlwaysReturns() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let store = MomentTextEvidenceStore(directory: FileManager.default.temporaryDirectory)
        let task = Task { try await store.recognize(image) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func testOversizedImageIsUnavailableNotHardFailure() async throws {
        let big = try XCTUnwrap(CGContext(data: nil, width: 2049, height: 32, bitsPerComponent: 8,
            bytesPerRow: 2049 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(big.makeImage())
        let store = MomentTextEvidenceStore(directory: FileManager.default.temporaryDirectory)
        do {
            _ = try await store.recognize(image)
            XCTFail("Expected unavailable for oversized frames")
        } catch TextRecognitionFailure.unavailable {
        }
    }

    func testUnavailableRecognitionCanBeCachedAsEmptyEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try DerivedCacheStore(url: directory.appendingPathComponent("analysis-cache.sqlite3"))
        let store = MomentTextEvidenceStore(directory: directory, cache: cache)
        // Soft-fail path used by prepareText: empty OCR is durable and skips re-OCR.
        _ = try await store.save([], for: photo())
        let cached = await store.cached(photo())
        XCTAssertEqual(cached?.lines, [])
    }

    func testSelectedCluePrecedesGenericLabelsWithoutVerifyingPlace() throws {
        let metadata = MomentNarrativeMetadata(dateLabel: "Today", photoCount: 30, favoriteCount: 16,
            verifiedPlace: nil, visualLabels: ["people"], textClue: "madurodam")
        let candidates = try LocalMomentNarrative.candidates(metadata)
        XCTAssertTrue(candidates[0].title.contains("madurodam"))
        XCTAssertTrue(candidates[0].description.contains("not a verified place"))
        XCTAssertNil(metadata.verifiedPlace)
        var oversized = metadata
        oversized.textClue = String(repeating: "x", count: 161)
        XCTAssertThrowsError(try LocalMomentNarrative.candidates(oversized))
    }

    func testOptInExportedAugustSet() async throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTO_CURATOR_OCR_TEST_FOLDER"] else {
            throw XCTSkip("Opt-in exported-copy OCR test")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MomentTextEvidenceStore(directory: directory,
                                            cache: try DerivedCacheStore(url: directory.appendingPathComponent("analysis-cache.sqlite3")))
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jpeg" && !$0.lastPathComponent.contains(" (1)") }
        XCTAssertEqual(files.count, 30)
        var found = false
        for file in files {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
            ] as CFDictionary))
            let lines = try await store.recognize(image)
            if file.lastPathComponent == "IMG_8796.jpeg" {
                found = lines.contains { $0.text.lowercased().contains("madurodam") }
            }
        }
        XCTAssertTrue(found, "Expected the visible Madurodam sign to be recognized")
    }
}
