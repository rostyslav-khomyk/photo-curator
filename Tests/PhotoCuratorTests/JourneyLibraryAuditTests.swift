import XCTest
import SQLite3
import CoreLocation
@testable import PhotoCurator

private actor JourneyAuditEvidence {
    let labels: BackgroundMomentContext
    let text: MomentTextEvidenceStore
    var sampled = 0, paired = 0, visualAir = 0, visualLand = 0, confidentText = 0

    init(root: URL, cache: DerivedCacheStore) {
        labels = BackgroundMomentContext(root: root.appendingPathComponent("background-context"), cache: cache)
        text = MomentTextEvidenceStore(directory: root.appendingPathComponent("text-evidence"), cache: cache)
    }

    func inspect(_ photos: [IndexedPhoto]) async -> JourneyLocalTransportSupport {
        var result = JourneyLocalTransportSupport()
        for photo in photos where photo.similarityCategory != .screenshots {
            sampled += 1
            let clues = await labels.cachedLabels(photo)
            let ocr = await text.cached(photo)
            if let clues {
                let names = Set(clues.map { $0.lowercased() })
                if !names.isDisjoint(with: JourneyLocalTransportSupport.airLabels) { visualAir += 1 }
                if !names.isDisjoint(with: JourneyLocalTransportSupport.overlandLabels) { visualLand += 1 }
            }
            if ocr?.lines.contains(where: { $0.confidence >= 0.8 }) == true { confidentText += 1 }
            if let clues, let ocr {
                paired += 1
                result.inspect(labels: clues, lines: ocr.lines)
            }
        }
        return result
    }

    func summary() -> String {
        "sampled=\(sampled) paired=\(paired) visualAir=\(visualAir) visualLand=\(visualLand) confidentOCR=\(confidentText)"
    }
}

final class JourneyLibraryAuditTests: XCTestCase {
    func testOptInIsolatedJourneyTransportAudit() async throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTO_CURATOR_JOURNEY_AUDIT_COPY"] else {
            throw XCTSkip("Set PHOTO_CURATOR_JOURNEY_AUDIT_COPY to an isolated temporary snapshot directory")
        }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard root.path.hasPrefix("/private/tmp/photocurator-audit-") || root.path.hasPrefix("/tmp/photocurator-audit-") else {
            XCTFail("Audit requires a temporary copy, never the live catalog"); return
        }
        let store = try CatalogV2Store(url: root.appendingPathComponent("catalog.sqlite3"))
        let started = Date()
        try await store.rebuildStories()
        let before = try await store.storySummaries()
        let projectionTime = Date().timeIntervalSince(started)
        let cache = try DerivedCacheStore(url: root.appendingPathComponent("cache.sqlite3"))
        let evidence = JourneyAuditEvidence(root: root, cache: cache)
        let transportStart = Date()
        var passes = 0, updated = 0
        while true {
            let pass = try await store.enrichJourneyTransport { photos in await evidence.inspect(photos) }
            if pass.attempted { passes += 1 }
            if pass.updated { updated += 1 }
            if !pass.hasMore { break }
            XCTAssertLessThan(passes, 10_000)
            if passes >= 10_000 { break }
        }
        let after = try await store.storySummaries()
        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertEqual(before.map(\.momentIDs), after.map(\.momentIDs))
        XCTAssertEqual(before.map(\.photoCount), after.map(\.photoCount))
        let oldLegs = before.flatMap(\.stops).compactMap(\.transportFromPrevious)
        let legs = after.flatMap(\.stops).compactMap(\.transportFromPrevious)
        XCTAssertEqual(oldLegs.map(\.mode), legs.map(\.mode))
        let changed = zip(oldLegs, legs).filter { $0.confidence != $1.confidence }.count
        print("AUDIT projectionSeconds=\(projectionTime) transportSeconds=\(Date().timeIntervalSince(transportStart)) stories=\(after.count) legs=\(legs.count) passes=\(passes) persisted=\(updated) confidenceChanges=\(changed)")
        print("AUDIT transport \(await evidence.summary())")
        print("AUDIT support air=\(legs.reduce(0) { $0 + ($1.localSupport?.airPhotos ?? 0) }) overland=\(legs.reduce(0) { $0 + ($1.localSupport?.overlandPhotos ?? 0) })")
        let formatter = ISO8601DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for year in [2020, 2022, 2026] {
            let trip = try XCTUnwrap(after.first {
                calendar.component(.year, from: $0.start) == year
                    && calendar.component(.month, from: $0.start) == (year == 2020 ? 8 : 7)
                    && $0.kind == .journey
            })
            let modes = trip.stops.compactMap { $0.transportFromPrevious?.mode }
            print("AUDIT TARGET year=\(year) air=\(modes.filter { $0 == .air }.count) overland=\(modes.filter { $0 == .overland }.count) unknown=\(modes.filter { $0 == .unknown }.count)")
        }
        for story in after {
            print("AUDIT STORY \(formatter.string(from: story.start)) through \(formatter.string(from: story.end)) kind=\(story.kind.rawValue) moments=\(story.momentIDs.count) photos=\(story.photoCount) stops=\(story.stops.count) title=\(story.title)")
        }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(root.appendingPathComponent("catalog.sqlite3").path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var query: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT payload FROM assets WHERE created < 1167609600 OR (created >= 1577836800 AND created < 1609459200) ORDER BY created", -1, &query, nil), SQLITE_OK)
        defer { sqlite3_finalize(query) }
        var cohorts: [Int: [IndexedPhoto]] = [:]
        while sqlite3_step(query) == SQLITE_ROW {
            let data = Data(bytes: sqlite3_column_blob(query, 0)!, count: Int(sqlite3_column_bytes(query, 0)))
            let photo = try JSONDecoder().decode(IndexedPhoto.self, from: data)
            let year = calendar.component(.year, from: photo.created!)
            cohorts[year, default: []].append(photo)
        }
        for year in cohorts.keys.sorted() {
            let photos = cohorts[year]!
            let cohortEvidence = JourneyAuditEvidence(root: root, cache: cache)
            _ = await cohortEvidence.inspect(photos)
            let withGPS = photos.filter { $0.latitude != nil && $0.longitude != nil }.count
            print("AUDIT COHORT year=\(year) photos=\(photos.count) withGPS=\(withGPS) \(await cohortEvidence.summary())")
        }
    }
}
