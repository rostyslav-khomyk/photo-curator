import XCTest
import ImageIO
import CryptoKit
@testable import PhotoRelay

private struct ReferenceManifest: Decodable {
    struct Row: Decodable {
        struct Capture: Decodable { let source: String; let value: String; let offset: String? }
        struct GPS: Decodable { let latitude: Double; let longitude: Double }
        let path: String
        let folder: String
        let sha256: String
        let isPhoto: Bool
        let capture: Capture?
        let gps: GPS?
        let width: Int?
        let height: Int?
    }
    let root: String
    let rows: [Row]
}

private struct ReferenceSamplePlan: Decodable {
    struct Sample: Decodable { let path: String; let sha256: String }
    struct Case: Decodable {
        let id: String
        let referenceFolders: [String]
        let samples: [Sample]
    }
    let cases: [Case]
    let heldOut: [Sample]
}

private struct ReferenceFallbackNarrative: LocalNarrativeModel {
    let version = "reference-fallback-no-model-call"
    func isAvailable() async -> Bool { false }
    func choose(from candidates: [MomentNarrativeText]) async throws -> Int {
        XCTFail("No model inference in the evidence pilot")
        return 0
    }
}

final class ExportedReferenceBaselineTests: XCTestCase {
    func testOptInReviewedSelectionQuality() async throws {
        guard let directory = ProcessInfo.processInfo.environment["PHOTO_RELAY_QUALITY_REPORT"] else {
            throw XCTSkip("Explicit approved-sample selection quality audit")
        }
        struct Checklist: Decodable {
            struct Case: Decodable {
                struct Role: Decodable { let name: String; let indices: [Int] }
                let id: String; let roles: [Role]; let contextIndices: [Int]
            }
            let cases: [Case]
        }
        let report = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
        let manifest = try JSONDecoder().decode(ReferenceManifest.self, from: Data(contentsOf: report.appendingPathComponent("manifest.json")))
        let plan = try JSONDecoder().decode(ReferenceSamplePlan.self, from: Data(contentsOf: report.appendingPathComponent("reference-sample.json")))
        let checklist = try JSONDecoder().decode(Checklist.self, from: Data(contentsOf: report.appendingPathComponent("quality-reference.json")))
        let source = URL(fileURLWithPath: manifest.root).resolvingSymlinksInPath()
        guard report != source, !report.path.hasPrefix(source.path + "/") else { throw PublicationFailure.invalidRequest }
        let heldOut = Set(plan.heldOut.map(\.sha256))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = CuratorWorker(url: root.appendingPathComponent("index.sqlite3"))
        let analyzer = CuratorVisionAnalyzer()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
        var output: [[String: Any]] = []
        for check in checklist.cases {
            let reference = try XCTUnwrap(plan.cases.first { $0.id == check.id })
            var photos: [IndexedPhoto] = [], results: [String: CuratorVisionResult] = [:]
            for sample in reference.samples {
                guard !heldOut.contains(sample.sha256),
                      let row = manifest.rows.first(where: { $0.path == sample.path }),
                      let capture = row.capture, let offset = capture.offset,
                      let date = formatter.date(from: String(capture.value.prefix(19)) + offset) else { throw PublicationFailure.invalidRequest }
                let file = source.appendingPathComponent(sample.path).resolvingSymlinksInPath()
                guard file.path.hasPrefix(source.path + "/") else { throw PublicationFailure.invalidRequest }
                let data = try Data(contentsOf: file)
                guard MomentContinuity.digest(data) == sample.sha256 else { throw PublicationFailure.invalidRequest }
                let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary))
                let photo = IndexedPhoto(id: sample.sha256, created: date, modified: nil, latitude: row.gps?.latitude,
                    longitude: row.gps?.longitude, favorite: false, width: row.width ?? 0, height: row.height ?? 0)
                photos.append(photo)
                try await worker.prepareText(photo, image: image)
                results[photo.id] = try await analyzer.analyze(image)
            }
            let dates = photos.compactMap(\.created)
            let parent = PhotoMoment(id: "sample-evaluation", start: try XCTUnwrap(dates.min()), end: try XCTUnwrap(dates.max()), photos: photos)
            let display = try await worker.prepareDisplaySelection(parent, results: results)
            let selected = Set(try XCTUnwrap(display.selection).selected)
            let indices = photos.indices.filter { selected.contains(photos[$0].id) }.map { $0 + 1 }
            let allIndices = Set(1...photos.count)
            guard check.roles.allSatisfy({ Set($0.indices).isSubset(of: allIndices) }),
                  Set(check.contextIndices).isSubset(of: allIndices) else { throw PublicationFailure.invalidRequest }
            let missed = check.roles.filter { Set($0.indices).isDisjoint(with: indices) }.map(\.name)
            let utilitySelected = check.contextIndices.filter { indices.contains($0) }
            XCTAssertEqual(display.photos.count, photos.count)
            XCTAssertTrue(selected.isSubset(of: Set(photos.map(\.id))))
            output.append(["case": check.id, "selectedIndices": indices, "missingRoles": missed,
                           "contextSelectedIndices": utilitySelected, "sampleCount": photos.count])
            print("Quality sample \(check.id): \(indices.count)/\(photos.count) selected; missing roles: \(missed); contextual selections: \(utilitySelected.count)")
        }
        let file = report.appendingPathComponent("selection-quality.json")
        try JSONSerialization.data(withJSONObject: ["results": output,
            "scope": "Provisional reviewed sample checklist, not whole-visit or holdout quality. No production changes; no user Favorites available."], options: [.sortedKeys, .prettyPrinted])
            .write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func testOptInLargeVisitAndHoldoutValidation() async throws {
        guard let directory = ProcessInfo.processInfo.environment["PHOTO_RELAY_VALIDATION_REPORT"] else {
            throw XCTSkip("Explicit local-only large visit and holdout evaluation")
        }
        let report = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
        let manifest = try JSONDecoder().decode(ReferenceManifest.self, from: Data(contentsOf: report.appendingPathComponent("manifest.json")))
        let plan = try JSONDecoder().decode(ReferenceSamplePlan.self, from: Data(contentsOf: report.appendingPathComponent("reference-sample.json")))
        let source = URL(fileURLWithPath: manifest.root).resolvingSymlinksInPath()
        guard report != source, !report.path.hasPrefix(source.path + "/") else { throw PublicationFailure.invalidRequest }
        let folders = try XCTUnwrap(plan.cases.first { $0.id == "C03" }).referenceFolders
        let heldOut = Set(plan.heldOut.map(\.path))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"; formatter.isLenient = false
        let scopes = ProcessInfo.processInfo.environment["PHOTO_RELAY_VALIDATION_LARGE_ONLY"] == "1" ? ["large"] : ["large", "holdout"]
        for scope in scopes {
            let rows = manifest.rows.filter { $0.isPhoto && (scope == "large" ? folders.contains($0.folder) : heldOut.contains($0.path)) }
            XCTAssertEqual(rows.count, scope == "large" ? 624 : 684)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("index.sqlite3")
            let db = try CuratorStore(url: url), worker = CuratorWorker(url: url)
            let analyzer = CuratorVisionAnalyzer()
            let started = Date()
            var photos: [IndexedPhoto] = [], results: [String: CuratorVisionResult] = [:]
            for row in rows {
                try Task.checkCancellation()
                let file = source.appendingPathComponent(row.path).resolvingSymlinksInPath()
                guard file.path.hasPrefix(source.path + "/"), let capture = row.capture,
                      let offset = capture.offset, let date = formatter.date(from: String(capture.value.prefix(19)) + offset) else {
                    throw PublicationFailure.invalidRequest
                }
                let data = try Data(contentsOf: file)
                guard MomentContinuity.digest(data) == row.sha256 else { throw PublicationFailure.invalidRequest }
                let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary))
                // Folder names and reference labels are never analysis inputs. Export flags are unknown.
                let photo = IndexedPhoto(id: row.sha256, created: date, modified: nil, latitude: row.gps?.latitude,
                    longitude: row.gps?.longitude, favorite: false, width: row.width ?? 0, height: row.height ?? 0)
                photos.append(photo)
                try db.save([photo], generation: "validation")
                try await worker.prepareText(photo, image: image)
                let result = try await analyzer.analyze(image); results[photo.id] = result
                try db.enqueueAnalysis(asset: photo.id, revision: photo.analysisRevision, analyzer: CuratorVisionAnalyzer.version)
                let job = try XCTUnwrap(db.claimAnalysis())
                XCTAssertTrue(try db.finishAnalysis(job, result: JSONEncoder().encode(result)))
                if photos.count % 100 == 0 { print("Local validation \(scope): \(photos.count)/\(rows.count) analyzed") }
            }
            let baseline = MomentGrouping.group(photos)
            let reopened = CuratorWorker(url: url)
            var settled = false, steps = 0
            for _ in 0..<1000 {
                steps += 1
                if try await reopened.prepareMoments(range: nil, protection: .init(), model: ReferenceFallbackNarrative()) == .caughtUp {
                    settled = true; break
                }
            }
            XCTAssertTrue(settled)
            let catalog = try await reopened.preparedCatalog(protection: .init())
            let members = catalog.flatMap(\.photos).map(\.id)
            XCTAssertEqual(members.count, photos.count)
            XCTAssertEqual(Set(members), Set(photos.map(\.id)))
            XCTAssertFalse(catalog.contains { $0.id.hasPrefix("internal-") || $0.groupingState == .preparing })
            let restart = CuratorWorker(url: url)
            let restored = try await restart.preparedCatalog(protection: .init())
            XCTAssertEqual(restored.map(\.id), catalog.map(\.id))
            if scope == "large" { XCTAssertEqual(catalog.count, 1); XCTAssertEqual(catalog.first?.photos.count, 624) }
            var selected = 0, contextOnly = 0
            var displayed: [PhotoMoment] = []
            var selectedEvidence: [[String: Any]] = []
            let context = BackgroundMomentContext(root: root.appendingPathComponent("background-context"))
            for moment in catalog {
                let display = try await reopened.prepareDisplaySelection(moment, results: results)
                displayed.append(display)
                selected += display.selection?.selected.count ?? 0
                contextOnly += display.displayEvidence?.count ?? 0
                if scope == "large" {
                    for id in display.selection?.selected ?? [] {
                        let clues = await context.cachedLabels(try XCTUnwrap(moment.photos.first { $0.id == id })) ?? []
                        selectedEvidence.append(["id": id, "labels": clues,
                            "faces": try JSONSerialization.jsonObject(with: JSONEncoder().encode(results[id]?.faces))])
                    }
                }
            }
            let output: [String: Any] = ["scope": scope, "photos": photos.count,
                "baselineSizes": baseline.map { $0.photos.count }, "catalogSizes": catalog.map { $0.photos.count },
                "catalog": try JSONSerialization.jsonObject(with: JSONEncoder().encode(displayed)),
                "selected": selected, "selectedEvidence": selectedEvidence, "contextOnly": contextOnly, "steps": steps, "settled": settled,
                "seconds": Date().timeIntervalSince(started), "visionVersion": CuratorVisionAnalyzer.version,
                "limitations": "Structural validation only, not human event-quality acceptance. Export Favorites and PhotoKit categories unknown. Deterministic caption fallback, no LLM/network/Photos access."]
            let file = report.appendingPathComponent("\(scope)-validation.json")
            try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted]).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            print("Validation \(scope): \(photos.count) photos, \(baseline.count) -> \(catalog.count) groups, \(selected) selected, \(contextOnly) context-only, \(steps) steps; \(Int(Date().timeIntervalSince(started))) seconds")
        }
    }

    func testOptInRestaurantContinuityPipeline() async throws {
        guard let directory = ProcessInfo.processInfo.environment["PHOTO_RELAY_REFERENCE_REPORT"] else {
            throw XCTSkip("Opt-in authorized restaurant copies; no Photos or network access")
        }
        let report = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
        let manifest = try JSONDecoder().decode(ReferenceManifest.self, from: Data(contentsOf: report.appendingPathComponent("manifest.json")))
        let plan = try JSONDecoder().decode(ReferenceSamplePlan.self, from: Data(contentsOf: report.appendingPathComponent("reference-sample.json")))
        let reference = try XCTUnwrap(plan.cases.first { $0.id == "C05" })
        let heldOut = Set(plan.heldOut.map(\.sha256))
        let source = URL(fileURLWithPath: manifest.root).resolvingSymlinksInPath()
        guard report != source, !report.path.hasPrefix(source.path + "/") else { throw PublicationFailure.invalidRequest }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try CuratorStore(url: root.appendingPathComponent("index.sqlite3"))
        let worker = CuratorWorker(url: root.appendingPathComponent("index.sqlite3"))
        let analyzer = CuratorVisionAnalyzer()
        var photos: [IndexedPhoto] = [], results: [String: CuratorVisionResult] = [:]
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
        for sample in reference.samples {
            guard !heldOut.contains(sample.sha256),
                  let row = manifest.rows.first(where: { $0.path == sample.path }), let capture = row.capture, let offset = capture.offset else {
                throw PublicationFailure.invalidRequest
            }
            let file = source.appendingPathComponent(sample.path).resolvingSymlinksInPath()
            guard file.path.hasPrefix(source.path + "/") else { throw PublicationFailure.invalidRequest }
            let data = try Data(contentsOf: file)
            guard MomentContinuity.digest(data) == sample.sha256 else { throw PublicationFailure.invalidRequest }
            let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary))
            let date = try XCTUnwrap(formatter.date(from: String(capture.value.prefix(19)) + offset))
            let photo = IndexedPhoto(id: sample.sha256, created: date, modified: nil, latitude: row.gps?.latitude,
                longitude: row.gps?.longitude, favorite: false, width: row.width ?? 0, height: row.height ?? 0, similarityCategory: .photos)
            photos.append(photo)
            try db.save([photo], generation: "reference")
            try await worker.prepareText(photo, image: image)
            let result = try await analyzer.analyze(image); results[photo.id] = result
            try db.enqueueAnalysis(asset: photo.id, revision: photo.analysisRevision, analyzer: CuratorVisionAnalyzer.version)
            let job = try XCTUnwrap(db.claimAnalysis())
            XCTAssertTrue(try db.finishAnalysis(job, result: JSONEncoder().encode(result)))
        }
        XCTAssertEqual(photos.count, 16)
        let before = MomentGrouping.group(photos)
        XCTAssertEqual(before.map { $0.photos.count }, [3, 13])
        let pair = try XCTUnwrap(MomentContinuity.pairs(before, protected: []).first)
        let priority = DateInterval(start: pair.later.start, end: pair.later.end.addingTimeInterval(1))
        let reopened = CuratorWorker(url: root.appendingPathComponent("index.sqlite3"))
        var settled = false
        for _ in 0..<30 {
            if try await reopened.prepareMoments(range: priority, protection: .init(), model: ReferenceFallbackNarrative()) == .caughtUp {
                settled = true; break
            }
        }
        XCTAssertTrue(settled)
        let after = try await reopened.preparedCatalog(protection: .init())
        var distances: [Float] = []
        for a in pair.earlier.photos { for b in pair.later.photos {
            if let lhs = results[a.id], let rhs = results[b.id], let d = try? lhs.distance(to: rhs) { distances.append(d) }
        } }
        print("Restaurant continuity: \(before.map { $0.photos.count }) -> \(after.map { $0.photos.count }); closest cross-gap distances \(distances.sorted().prefix(8)).")
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.photos.count, 16)
        XCTAssertEqual(Set(after.flatMap(\.photos).map(\.id)), Set(photos.map(\.id)))
        XCTAssertNotNil(after.first?.continuityReason)
        let record = try XCTUnwrap(MomentContinuityStore(root: root.appendingPathComponent("event-continuity")).load(pair))
        XCTAssertTrue(record.joins)
        let restart = CuratorWorker(url: root.appendingPathComponent("index.sqlite3"))
        let restored = try await restart.preparedCatalog(protection: .init())
        XCTAssertEqual(restored.map(\.id), after.map(\.id))
        let context = BackgroundMomentContext(root: root.appendingPathComponent("background-context"))
        let caption = await context.cached(try XCTUnwrap(after.first))
        XCTAssertNotNil(caption, "Priority must finish captioning the complete joined visit")
        // Synthetic adverse evidence in isolated caches must retract, not freeze, a previous join.
        for photo in pair.earlier.photos { try await context.saveLabels(["castle"], for: photo) }
        for photo in pair.later.photos { try await context.saveLabels(["beach"], for: photo) }
        for _ in 0..<30 {
            if try await reopened.prepareMoments(range: priority, protection: .init(), model: ReferenceFallbackNarrative()) == .caughtUp { break }
        }
        let retracted = try await reopened.preparedCatalog(protection: .init())
        XCTAssertEqual(retracted.map { $0.photos.count }, [3, 13])
        let negative = try MomentContinuityStore(root: root.appendingPathComponent("event-continuity")).load(pair)
        XCTAssertEqual(negative?.joins, false)
        XCTAssertNotEqual(negative?.evidenceFingerprint, record.evidenceFingerprint)
        let output: [String: Any] = ["before": before.map { $0.photos.count }, "after": after.map { $0.photos.count },
            "afterSyntheticConflictingEvidence": retracted.map { $0.photos.count },
            "record": try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)),
            "scope": "16 approved copies; real local Vision/OCR; unknown export Favorites; no live library or network"]
        let file = report.appendingPathComponent("continuity-pilot.json")
        try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func testOptInLocalEvidencePilot() async throws {
        guard let directory = ProcessInfo.processInfo.environment["PHOTO_RELAY_REFERENCE_REPORT"] else {
            throw XCTSkip("Opt-in reference samples only; no Photos access or network")
        }
        let root = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
        let manifest = try JSONDecoder().decode(ReferenceManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let plan = try JSONDecoder().decode(ReferenceSamplePlan.self,
            from: Data(contentsOf: root.appendingPathComponent("reference-sample.json")))
        let sourceRoot = URL(fileURLWithPath: manifest.root).resolvingSymlinksInPath()
        XCTAssertFalse(root.path.hasPrefix(sourceRoot.path + "/"))
        guard root != sourceRoot, !root.path.hasPrefix(sourceRoot.path + "/") else { return }
        let pilot = root.appendingPathComponent("evidence-pilot")
        let worker = CuratorWorker(url: pilot.appendingPathComponent("index.sqlite3"))
        let context = BackgroundMomentContext(root: pilot.appendingPathComponent("background-context"),
            textDirectory: pilot.appendingPathComponent("text-evidence"))
        let textStore = MomentTextEvidenceStore(directory: pilot.appendingPathComponent("text-evidence"))
        let heldOut = Set(plan.heldOut.map(\.sha256))
        let indexed = Dictionary(uniqueKeysWithValues: manifest.rows.map { ($0.path, $0) })
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
        formatter.isLenient = false
        var output: [[String: Any]] = []
        for reference in plan.cases where ["C03", "C05", "C06", "C07", "C08"].contains(reference.id) {
            XCTAssertLessThanOrEqual(reference.samples.count, 32)
            guard reference.samples.count <= 32 else { continue }
            var photos: [IndexedPhoto] = []
            var evidence: [[String: Any]] = []
            var foundExpectedClue = false
            for sample in reference.samples {
                XCTAssertFalse(heldOut.contains(sample.sha256))
                guard !heldOut.contains(sample.sha256) else { continue }
                let row = try XCTUnwrap(indexed[sample.path])
                let url = sourceRoot.appendingPathComponent(sample.path).resolvingSymlinksInPath()
                XCTAssertTrue(url.path.hasPrefix(sourceRoot.path + "/"))
                guard url.path.hasPrefix(sourceRoot.path + "/") else { continue }
                let image = try autoreleasepool { () throws -> CGImage in
                    let data = try Data(contentsOf: url)
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    XCTAssertEqual(digest, sample.sha256)
                    guard digest == sample.sha256 else { throw CocoaError(.fileReadCorruptFile) }
                    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                    return try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1024
                    ] as CFDictionary))
                }
                let capture = try XCTUnwrap(row.capture)
                let offset = try XCTUnwrap(capture.offset)
                let date = try XCTUnwrap(formatter.date(from: String(capture.value.prefix(19)) + offset))
                let photo = IndexedPhoto(id: row.sha256, created: date, modified: nil,
                    latitude: row.gps?.latitude, longitude: row.gps?.longitude,
                    favorite: false, width: row.width ?? 0, height: row.height ?? 0,
                    // Reviewed fixture category, not a claim that the export preserves PhotoKit flags.
                    similarityCategory: reference.id == "C08" ? .screenshots : .photos)
                try await worker.prepareText(photo, image: image)
                let labels = await context.cachedLabels(photo)
                let text = await textStore.cached(photo)
                let lines = try XCTUnwrap(text).lines
                let confidentText = lines.filter { $0.confidence >= 0.9 }.map(\.text).joined(separator: " ").lowercased()
                if reference.id == "C05", confidentText.contains("ribhouse"), confidentText.contains("texas") {
                    foundExpectedClue = true
                }
                if reference.id == "C06", confidentText.contains("madurodam") { foundExpectedClue = true }
                evidence.append(["sha256": row.sha256, "path": row.path,
                    "labels": try XCTUnwrap(labels),
                    "lines": lines.map { ["text": $0.text, "confidence": $0.confidence] }])
                photos.append(photo)
            }
            if ["C05", "C06"].contains(reference.id) {
                XCTAssertTrue(foundExpectedClue, "Known context should be available from local OCR")
            }
            let start = try XCTUnwrap(photos.compactMap(\.created).min())
            let end = try XCTUnwrap(photos.compactMap(\.created).max())
            let moment = PhotoMoment(id: "reference-" + reference.id, start: start, end: end, photos: photos)
            _ = try await context.prepare(moment, model: ReferenceFallbackNarrative())
            let cached = await context.cached(moment)
            let caption = try XCTUnwrap(cached)
            let captionEvidence = try XCTUnwrap(caption.evidence)
            XCTAssertEqual(captionEvidence.inspected, reference.id == "C08" ? 0 : photos.count)
            if reference.id == "C03" { XCTAssertEqual(captionEvidence.primary, .historicInteriors) }
            if reference.id == "C05" {
                XCTAssertEqual(captionEvidence.primary, .dining)
                XCTAssertTrue(captionEvidence.textClues.contains { $0.text.lowercased().contains("ribhouse") && $0.text.lowercased().contains("texas") })
            }
            if reference.id == "C06" {
                XCTAssertTrue(captionEvidence.mixedTimeline)
                XCTAssertEqual(caption.narrative.headline, moment.start.formatted(date: .abbreviated, time: .omitted))
                XCTAssertTrue(captionEvidence.textClues.contains { $0.text.lowercased() == "madurodam" })
            }
            let display = try await worker.prepareDisplaySelection(moment, results: [:])
            let displayEvidence = display.displayEvidence ?? [:]
            XCTAssertEqual(display.photos.map(\.id), photos.map(\.id), "Context classification never deletes members")
            if reference.id == "C03" { XCTAssertTrue(displayEvidence.values.contains { $0.reason == .map }) }
            if reference.id == "C05" { XCTAssertGreaterThanOrEqual(displayEvidence.values.filter { $0.reason == .menu }.count, 2) }
            if reference.id == "C07" {
                XCTAssertTrue(displayEvidence.isEmpty, "The reviewed doll collection is meaningful photo content")
            }
            if reference.id == "C08" {
                XCTAssertEqual(display.selection?.contextOnly?.count, photos.count)
                XCTAssertTrue(MomentDisplayEligibility.isContextOnly(display, decisions: [:], userAuthored: false))
                XCTAssertNil(MomentDisplayEligibility.cover(display, decisions: [:], selected: []))
                XCTAssertTrue(captionEvidence.textClues.isEmpty)
            }
            let displayData = try JSONEncoder().encode(displayEvidence)
            let evidenceData = try JSONEncoder().encode(captionEvidence)
            output.append(["case": reference.id, "samples": evidence,
                "currentSampleCaption": ["title": caption.narrative.headline, "description": caption.narrative.story ?? ""],
                "captionEvidence": try JSONSerialization.jsonObject(with: evidenceData),
                "displayEvidence": try JSONSerialization.jsonObject(with: displayData),
                "captionSource": caption.narrative.provenance.first ?? "unknown"])
            print("Reference evidence \(reference.id): \(photos.count) local previews; OCR/labels cached; no model, upload or library changes.")
        }
        let report: [String: Any] = ["version": 2,
            "scope": "90 approved sampled previews; OCR/classification/display eligibility; captions use deterministic fallback; no aesthetics-based selection acceptance",
            "thumbnailEdge": 1024,
            "engine": MomentTextEvidenceStore.engine, "classifier": NarrativeVisualContext.version, "cases": output]
        let file = root.appendingPathComponent("local-evidence-pilot.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func testOptInMetadataBaselineWithoutLiveLibrary() throws {
        guard let directory = ProcessInfo.processInfo.environment["PHOTO_RELAY_REFERENCE_REPORT"] else {
            throw XCTSkip("Opt-in reference export metadata baseline; no Photos access")
        }
        let root = URL(fileURLWithPath: directory)
        let manifest = try JSONDecoder().decode(ReferenceManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let plan = try JSONDecoder().decode(ReferenceSamplePlan.self,
            from: Data(contentsOf: root.appendingPathComponent("reference-sample.json")))
        let heldOut = Set(plan.heldOut.map(\.sha256))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
        formatter.isLenient = false
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Amsterdam"))
        var output: [[String: Any]] = []
        for reference in plan.cases {
            let folders = Set(reference.referenceFolders)
            let samples = Set(reference.samples.map(\.sha256))
            let rows = manifest.rows.filter { $0.isPhoto && (folders.contains($0.folder) || samples.contains($0.sha256)) }
            XCTAssertFalse(rows.isEmpty)
            XCTAssertTrue(heldOut.isDisjoint(with: Set(rows.map(\.sha256))), "Never tune against the holdout")
            let photos = try rows.map { row -> IndexedPhoto in
                let capture = try XCTUnwrap(row.capture)
                let offset = try XCTUnwrap(capture.offset, "Unknown offsets require explicit handling, not a guess")
                let date = try XCTUnwrap(formatter.date(from: String(capture.value.prefix(19)) + offset))
                return IndexedPhoto(id: row.sha256, created: date, modified: nil,
                    latitude: row.gps?.latitude, longitude: row.gps?.longitude,
                    favorite: false, width: row.width ?? 0, height: row.height ?? 0)
            }
            // Folder names select evaluation cases only. The app receives no folder labels.
            let moments = MomentGrouping.group(photos, calendar: calendar)
            XCTAssertEqual(moments.flatMap(\.photos).count, photos.count)
            XCTAssertEqual(Set(moments.flatMap(\.photos).map(\.id)), Set(photos.map(\.id)))
            let sizes = moments.map { $0.photos.count }
            output.append(["case": reference.id, "photos": photos.count, "groupSizesNewestFirst": sizes,
                "groupsOverRefinementLimit": sizes.filter { $0 > 512 }.count,
                "groups": moments.map { ["id": $0.id, "members": $0.photos.map(\.id)] }])
            print("Reference \(reference.id): \(photos.count) photos -> \(sizes); metadata-only app baseline, not accepted quality.")
        }
        let report: [String: Any] = ["version": 1, "stage": "MomentGrouping metadata baseline only",
            "favorites": "unavailable in export; placeholders unused by grouping",
            "noVisionOrNarrative": true, "cases": output]
        let file = root.appendingPathComponent("metadata-baseline.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
