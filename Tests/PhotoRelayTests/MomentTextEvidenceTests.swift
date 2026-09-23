import XCTest
import ImageIO
@testable import PhotoRelay

final class MomentTextEvidenceTests: XCTestCase {
    private func photo(_ modified: Double = 1) -> IndexedPhoto {
        IndexedPhoto(id: "synthetic/asset", created: Date(), modified: Date(timeIntervalSince1970: modified),
                     latitude: nil, longitude: nil, favorite: false, width: 100, height: 100)
    }

    func testCacheSurvivesReopeningAndRejectsEdits() async throws {
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
        let edited = await reopened.cached(photo(2))
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
        guard let path = ProcessInfo.processInfo.environment["PHOTO_RELAY_OCR_TEST_FOLDER"] else {
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
