import XCTest
import ImageIO
@testable import PhotoRelay

final class EvidenceGroupingTests: XCTestCase {
    func testOptInExportedGrouping() async throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTO_RELAY_OCR_TEST_FOLDER"] else {
            throw XCTSkip("Opt-in local exported-photo grouping test")
        }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jpeg" && !$0.lastPathComponent.contains(" (1)") && !$0.lastPathComponent.hasPrefix("IMG_5269") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(files.count, 29)
        let session = GroupingEvidenceSession()
        var photos: [IndexedPhoto] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        for file in files {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
            let date = try XCTUnwrap(formatter.date(from: try XCTUnwrap(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String)))
            let item = photo(file.lastPathComponent, date.timeIntervalSince1970)
            photos.append(item)
            let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024
            ] as CFDictionary))
            try await session.inspect(item, image: image, lines: [])
        }
        let result = try await session.proposal(photos, cutoff: EvidenceGrouping.defaultCutoff)
        XCTAssertTrue(result.suspiciousTimes)
        XCTAssertEqual(Set(result.groups.flatMap(\.photos).map(\.id)).count, 29)
        XCTAssertGreaterThan(result.groups.count, 1)
        XCTAssertLessThan(result.groups.count, photos.count, "Default must find supported same-scene pairs")
        XCTAssertTrue(result.groups.allSatisfy { $0.inferredLocationSources.isEmpty })
        func together(_ a: String, _ b: String) -> Bool {
            result.groups.contains { group in
                let names = Set(group.photos.map(\.id))
                return names.contains(a + ".jpeg") && names.contains(b + ".jpeg")
            }
        }
        XCTAssertTrue(together("IMG_8794", "IMG_8797"), "Same Kurhaus backdrop")
        XCTAssertTrue(together("IMG_8817", "IMG_8819"), "Same Amsterdam boat setting")
        XCTAssertFalse(together("IMG_8795", "IMG_8818"), "Miniature park is not Amsterdam")
        XCTAssertFalse(together("IMG_8800", "IMG_8801"), "Peace Palace is not De Haar")
        print("Local grouping preview: \(result.groups.count) groups; sizes \(result.groups.map { $0.photos.count }); no location inference.")
        if ProcessInfo.processInfo.environment["PHOTO_RELAY_GROUPING_TRACE"] == "1" {
            for group in result.groups {
                print("Visual group: \(group.photos.map(\.id).joined(separator: ", "))")
            }
        }
    }
    func photo(_ id: String, _ seconds: Double, lat: Double? = nil, lon: Double? = nil) -> IndexedPhoto {
        IndexedPhoto(id: id, created: Date(timeIntervalSince1970: seconds), modified: nil,
                     latitude: lat, longitude: lon, favorite: false, width: 100, height: 100)
    }

    func testDirectGPSAnchorAndSharedText() {
        let a = photo("a", 0, lat: 52, lon: 4)
        let b = photo("b", 60)
        let lines = [PhotoTextLine(text: "Madurodam", confidence: 0.9)]
        let result = EvidenceGrouping.propose([b, a], text: ["a": lines, "b": lines], cutoff: 10) { _, _ in 3 }
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].inferredLocationSources["b"], "a")
        XCTAssertTrue(result.groups[0].explanations["b"]!.contains("Shared OCR"))
        XCTAssertNil(b.latitude)
    }

    func testSceneryTimeAndConflictingGPSPreventMerge() {
        let photos = [photo("a", 0, lat: 52, lon: 4), photo("b", 60, lat: 53, lon: 4),
                      photo("c", 120), photo("d", 4000)]
        let result = EvidenceGrouping.propose(photos, text: [:], cutoff: 10) { a, b in
            a == "c" || b == "c" ? 20 : 1
        }
        XCTAssertEqual(result.groups.count, 4)
    }

    func testNoTransitiveSceneryOrLocationChains() {
        let photos = [photo("a", 0, lat: 52, lon: 4), photo("b", 60), photo("c", 120)]
        let result = EvidenceGrouping.propose(photos, text: [:], cutoff: 10) { a, b in
            Set([a, b]) == Set(["a", "c"]) ? 20 : 2
        }
        XCTAssertEqual(result.groups.map { $0.photos.map(\.id) }, [["a", "b"], ["c"]])
        XCTAssertTrue(result.groups[1].inferredLocationSources.isEmpty)
    }

    func testMissingEvidenceAndInvalidDistancesStaySeparate() {
        let photos = [photo("a", 0), photo("b", 1)]
        for value: Float? in [nil, .nan, .infinity, -1] {
            XCTAssertEqual(EvidenceGrouping.propose(photos, text: [:], cutoff: 10) { _, _ in value }.groups.count, 2)
        }
        XCTAssertFalse(EvidenceGrouping.validGPS(photo("invalid", 0, lat: 100, lon: 4)))
    }

    func testCompressedTimestampsNeverGainInferenceByLooseningSlider() {
        let photos = (0..<10).map { photo("\($0)", Double($0), lat: $0 == 0 ? 52 : nil, lon: $0 == 0 ? 4 : nil) }
        for cutoff: Float in [0, 10, 25] {
            let result = EvidenceGrouping.propose(photos, text: [:], cutoff: cutoff) { _, _ in 5 }
            XCTAssertTrue(result.suspiciousTimes)
            XCTAssertTrue(result.groups.allSatisfy { $0.inferredLocationSources.isEmpty })
            XCTAssertEqual(result.groups.flatMap(\.photos).count, 10)
        }
    }

    func testLaterGPSMustMatchEachPhotoDirectly() {
        let photos = [photo("a", 0), photo("b", 60), photo("c", 120, lat: 52, lon: 4)]
        let result = EvidenceGrouping.propose(photos, text: [:], cutoff: 10) { a, b in
            Set([a, b]) == Set(["b", "c"]) ? 20 : 2
        }
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].inferredLocationSources["a"], "c")
        XCTAssertNil(result.groups[0].inferredLocationSources["b"])
    }

    func testLooserPreviewCannotLoosenLocationInference() {
        let photos = [photo("a", 0, lat: 52, lon: 4), photo("b", 60)]
        let result = EvidenceGrouping.propose(photos, text: [:], cutoff: 25) { _, _ in 20 }
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertTrue(result.groups[0].inferredLocationSources.isEmpty)
    }

    func testOCRCannotOverrideDifferentSceneryOrMissingEvidence() {
        let photos = [photo("a", 0), photo("b", 60)]
        let lines = [PhotoTextLine(text: "SAME SHIRT", confidence: 0.99)]
        let result = EvidenceGrouping.propose(photos, text: ["a": lines, "b": lines], cutoff: 16) { _, _ in 20 }
        XCTAssertEqual(result.groups.count, 2)
    }

    func testStableOrderAndBoundedAnchorTime() {
        let photos = [photo("a", 0), photo("b", 1500), photo("c", 3000)]
        let result = EvidenceGrouping.propose(photos.reversed(), text: [:], cutoff: 16) { _, _ in 1 }
        XCTAssertEqual(result.groups.map { $0.photos.map(\.id) }, [["a", "b"], ["c"]])
    }
}
