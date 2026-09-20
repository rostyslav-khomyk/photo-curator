import XCTest
import ImageIO
@testable import PhotoRelay

private struct PipelineFallbackModel: LocalNarrativeModel {
    let version = "pipeline-test"
    func isAvailable() async -> Bool { false }
    func choose(from candidates: [MomentNarrativeText]) async throws -> Int { XCTFail("No live model in synthetic tests"); return 0 }
}

final class AutomaticMomentPipelineTests: XCTestCase {
    func testLargeVisitResumesAndRechecksChangedEvidenceWithoutExtraCards() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = (0..<624).map { photo("large-\($0)", 100_000 + Double($0 * 10)) }
        try await seed(photos, root: root)
        let url = root.appendingPathComponent("index.sqlite3")
        let worker = CuratorWorker(url: url)
        let initial = try await worker.preparedCatalog(protection: .init())
        XCTAssertEqual(initial.count, 1)
        let parent = try XCTUnwrap(initial.first)
        _ = try await worker.prepareMoments(range: nil, protection: .init(), model: PipelineFallbackModel())
        let checkpoints = LargeMomentWindowStore(root: root.appendingPathComponent("automatic-moments"))
        let windows = try LargeMomentWindows.make(parent)
        XCTAssertNotNil(try checkpoints.load(windows[0])?.evidenceFingerprint)
        XCTAssertNil(try checkpoints.load(windows[1]))
        let reopened = CuratorWorker(url: url)
        try await drain(reopened)
        let catalog = try await reopened.preparedCatalog(protection: .init())
        XCTAssertEqual(catalog.map(\.id), [parent.id])
        XCTAssertEqual(catalog[0].photos.count, 624)
        XCTAssertEqual(catalog[0].groupingState, .conservative)
        XCTAssertTrue(catalog[0].groupingReason?.contains("3 of 3") == true)
        let before = try checkpoints.load(windows[1])?.evidenceFingerprint
        let context = BackgroundMomentContext(root: root.appendingPathComponent("background-context"))
        try await context.saveLabels(["beach"], for: photos[300])
        try await drain(reopened)
        XCTAssertNotEqual(try checkpoints.load(windows[1])?.evidenceFingerprint, before)
        let protected = try AutomaticMomentStore(root: root.appendingPathComponent("automatic-moments"))
            .apply(parent, protected: [parent.id])
        XCTAssertEqual(protected[0].groupingState, .reviewed)
        XCTAssertEqual(protected[0].photos.count, 624)
    }

    func testLargeMissingWindowDoesNotStarveOtherWindows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = (0..<624).map { photo("large-\($0)", 100_000 + Double($0 * 10)) }
        try await seed(photos, root: root, evidence: false)
        try await seed(Array(photos.dropFirst()), root: root)
        let worker = CuratorWorker(url: root.appendingPathComponent("index.sqlite3"))
        try await drain(worker)
        let catalog = try await worker.preparedCatalog(protection: .init())
        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(catalog[0].groupingState, .preparing)
        XCTAssertTrue(catalog[0].groupingReason?.contains("2 of 3") == true)
        try await seed([photos[0]], root: root)
        try await drain(worker)
        let ready = try await worker.preparedCatalog(protection: .init())
        XCTAssertTrue(ready[0].groupingReason?.contains("3 of 3") == true)
    }

    func testOptInExportedAutomaticPipeline() async throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTO_RELAY_OCR_TEST_FOLDER"] else {
            throw XCTSkip("Opt-in authorized exported-copy pipeline test")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jpeg" && !$0.lastPathComponent.contains(" (1)") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(files.count, 30)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let db = try CuratorStore(url: root.appendingPathComponent("index.sqlite3"))
        let analyzer = CuratorVisionAnalyzer()
        let worker = CuratorWorker(url: root.appendingPathComponent("index.sqlite3"))
        var photos: [IndexedPhoto] = []
        for file in files {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
            let date = try XCTUnwrap(formatter.date(from: try XCTUnwrap(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String)))
            let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
            let lat = (gps[kCGImagePropertyGPSLatitude as String] as? Double).map { (gps[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S" ? -$0 : $0 }
            let lon = (gps[kCGImagePropertyGPSLongitude as String] as? Double).map { (gps[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W" ? -$0 : $0 }
            let photo = IndexedPhoto(id: file.lastPathComponent, created: date, modified: nil, latitude: lat, longitude: lon,
                favorite: false, width: properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0,
                height: properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0)
            photos.append(photo)
            try db.save([photo], generation: "exported-test")
            try db.enqueueAnalysis(asset: photo.id, revision: photo.analysisRevision, analyzer: CuratorVisionAnalyzer.version)
            let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024
            ] as CFDictionary))
            try await worker.prepareText(photo, image: image)
            let result = try await analyzer.analyze(image)
            let job = try XCTUnwrap(db.claimAnalysis())
            XCTAssertEqual(job.asset, photo.id)
            XCTAssertTrue(try db.finishAnalysis(job, result: JSONEncoder().encode(result)))
        }
        // Restart after evidence ingestion: exercise the same persistent caches as the app.
        let reopened = CuratorWorker(url: root.appendingPathComponent("index.sqlite3"))
        try await drain(reopened)
        let catalog = try await reopened.preparedCatalog(protection: .init())
        let members = catalog.flatMap(\.photos).map(\.id)
        XCTAssertEqual(Set(members), Set(photos.map(\.id)))
        XCTAssertEqual(members.count, 30)
        XCTAssertEqual(Set(catalog.map(\.id)).count, catalog.count)
        XCTAssertTrue(catalog.allSatisfy { $0.groupingState == .ready || $0.groupingKind == .unresolved })
        XCTAssertGreaterThan(catalog.filter { $0.groupingKind == .scene }.count, 1)
        XCTAssertTrue(catalog.filter { $0.groupingKind == .scene }.allSatisfy { $0.photos.count >= 3 })
        let scenes = catalog.filter { $0.groupingKind == .scene }.map { Set($0.photos.map(\.id)) }
        XCTAssertTrue(scenes.contains { $0.isSuperset(of: ["IMG_8801.jpeg", "IMG_8802.jpeg", "IMG_8807.jpeg"]) })
        XCTAssertTrue(scenes.contains { $0.isSuperset(of: ["IMG_8808.jpeg", "IMG_8811.jpeg", "IMG_8814.jpeg"]) })
        XCTAssertFalse(scenes.contains { $0.contains("IMG_8800.jpeg") && $0.contains("IMG_8801.jpeg") }, "Different buildings must not merge")
        XCTAssertFalse(scenes.contains { $0.contains("IMG_8795.jpeg") && $0.contains("IMG_8818.jpeg") }, "Miniature city must not merge with city visit")
        let context = BackgroundMomentContext(root: root.appendingPathComponent("background-context"))
        for moment in catalog {
            let caption = await context.cached(moment)
            if moment.groupingKind == .unresolved { XCTAssertNil(caption, "Do not invent a caption for mixed unresolved photos") }
            else { XCTAssertNotNil(caption) }
        }
        let again = try await reopened.prepareMoments(range: nil, protection: .init(), model: PipelineFallbackModel())
        XCTAssertEqual(again, .caughtUp)
        print("Automatic exported-copy pipeline: \(catalog.count) collections; sizes \(catalog.map { $0.photos.count }); complete coverage, captions only for supported collections, no uploads or library writes.")
        for moment in catalog {
            print("Boundary evidence: \(moment.groupingReason ?? "none")")
            if ProcessInfo.processInfo.environment["PHOTO_RELAY_GROUPING_TRACE"] == "1" {
                print("Collection: \(moment.groupingKind?.rawValue ?? "time/location"): \(moment.photos.map(\.id).joined(separator: ", "))")
            }
        }
    }

    private func photo(_ id: String, _ time: Double) -> IndexedPhoto {
        IndexedPhoto(id: id, created: Date(timeIntervalSince1970: time), modified: nil,
            latitude: nil, longitude: nil, favorite: false, width: 100, height: 100)
    }

    private func seed(_ photos: [IndexedPhoto], root: URL, evidence: Bool = true) async throws {
        let db = try CuratorStore(url: root.appendingPathComponent("index.sqlite3"))
        try db.save(photos, generation: "synthetic")
        guard evidence else { return }
        let context = BackgroundMomentContext(root: root.appendingPathComponent("background-context"))
        let text = MomentTextEvidenceStore(directory: root.appendingPathComponent("text-evidence"))
        for photo in photos {
            try db.enqueueAnalysis(asset: photo.id, revision: photo.analysisRevision, analyzer: CuratorVisionAnalyzer.version)
            try await context.saveLabels(["castle"], for: photo)
            _ = try await text.save([], for: photo)
        }
        while let job = try db.claimAnalysis() {
            let result = CuratorVisionResult(version: CuratorVisionAnalyzer.version, faces: .available(0),
                aesthetics: .unavailable, featurePrint: .unavailable)
            XCTAssertTrue(try db.finishAnalysis(job, result: JSONEncoder().encode(result)))
        }
    }

    private func drain(_ worker: CuratorWorker, range: DateInterval? = nil,
                       protection: MomentGroupingProtection = .init()) async throws {
        for _ in 0..<100 {
            if try await worker.prepareMoments(range: range, protection: protection, model: PipelineFallbackModel()) == .caughtUp { return }
        }
        XCTFail("Preparation did not settle within bounded steps")
    }

    func testPriorityKeepsWholeMembershipAndRestartReusesRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = [photo("old", 1), photo("new-a", 200_000), photo("new-b", 200_010)]
        try await seed(photos, root: root)
        let worker = CuratorWorker(url: root.appendingPathComponent("index.sqlite3"))
        let range = DateInterval(start: Date(timeIntervalSince1970: 200_005), end: Date(timeIntervalSince1970: 200_011))
        try await drain(worker, range: range)
        let catalog = try await worker.preparedCatalog(protection: .init())
        XCTAssertEqual(catalog.count, 2, "Priority is not a catalog filter")
        XCTAssertEqual(catalog[0].photos.map(\.id), ["new-a", "new-b"])
        XCTAssertEqual(catalog[0].groupingState, .ready)
        XCTAssertEqual(catalog[1].groupingState, .preparing)
        let context = BackgroundMomentContext(root: root.appendingPathComponent("background-context"))
        let caption = await context.cached(catalog[0])
        XCTAssertNotNil(caption, "Do not finish priority work between grouping and caption stages")
        let reopened = CuratorWorker(url: root.appendingPathComponent("index.sqlite3"))
        let settled = try await reopened.prepareMoments(range: range, protection: .init(), model: PipelineFallbackModel())
        XCTAssertEqual(settled, .caughtUp)
        try await drain(reopened)
        let complete = try await reopened.preparedCatalog(protection: .init())
        XCTAssertTrue(complete.allSatisfy { $0.groupingState == .ready })
    }

    func testNewestFirstAndMoreThanOneSweepBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = (0..<10).map { photo("photo-\($0)", Double($0 * 200_000)) }
        try await seed(photos, root: root)
        let worker = CuratorWorker(url: root.appendingPathComponent("index.sqlite3"))
        let step = try await worker.prepareMoments(range: nil, protection: .init(), model: PipelineFallbackModel())
        let first = try await worker.preparedCatalog(protection: .init())
        XCTAssertEqual(step, .presentationChanged(first[0].id))
        XCTAssertEqual(first[0].photos[0].id, "photo-9")
        XCTAssertEqual(first[0].groupingState, .ready)
        XCTAssertEqual(first[1].groupingState, .preparing)
        try await drain(worker)
        let complete = try await worker.preparedCatalog(protection: .init())
        let context = BackgroundMomentContext(root: root.appendingPathComponent("background-context"))
        for moment in complete {
            let caption = await context.cached(moment)
            XCTAssertNotNil(caption)
        }
    }

    func testMissingEvidenceDoesNotBecomeACompletedBoundaryRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try await seed([photo("missing", 1)], root: root, evidence: false)
        let worker = CuratorWorker(url: root.appendingPathComponent("index.sqlite3"))
        try await drain(worker)
        let catalog = try await worker.preparedCatalog(protection: .init())
        XCTAssertEqual(catalog[0].groupingState, .preparing)
        XCTAssertNil(try AutomaticMomentStore(root: root.appendingPathComponent("automatic-moments")).load(catalog[0].id))
        try await seed([photo("missing", 1)], root: root)
        try await drain(worker)
        let ready = try await worker.preparedCatalog(protection: .init())
        XCTAssertEqual(ready[0].groupingState, .ready)
    }

    @MainActor
    func testNamedChildSurvivesMetadataRegroupingAndExplicitEditsWin() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = PhotoMoment(id: "child", start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2),
            photos: [photo("a", 1), photo("b", 2)])
        let decisions = MomentReviewDecisions(defaults: defaults)
        decisions.setTitle("My trip", for: original.id, moment: original)
        decisions.set(.exclude, for: "a")
        let protection = MomentGroupingProtection.load(defaults)
        let changed = [photo("a", 500_000), photo("b", 2), photo("new", 3)]
        let output = MomentCatalogGrouping.build(changed, reviews: .init(), protection: protection)
        XCTAssertEqual(Set(output.first { $0.id == "child" }!.photos.map(\.id)), ["a", "b"])
        XCTAssertEqual(output.flatMap(\.photos).count, 3)
        let review = GroupReviewArchive(groups: [.init(id: "explicit", title: "Split", members: ["a"])])
        let edited = MomentCatalogGrouping.build(changed, reviews: review, protection: protection)
        XCTAssertEqual(edited.first { $0.id == "child" }?.photos.map(\.id), ["b"])
        XCTAssertEqual(edited.flatMap(\.photos).count, 3)
        let restored = MomentReviewDecisions(defaults: defaults)
        XCTAssertEqual(restored.titles["child"], "My trip")
        XCTAssertEqual(restored.values["a"], .exclude)
        restored.setTitle("", for: "child")
        XCTAssertTrue(MomentGroupingProtection.load(defaults).members.isEmpty)
    }
}
