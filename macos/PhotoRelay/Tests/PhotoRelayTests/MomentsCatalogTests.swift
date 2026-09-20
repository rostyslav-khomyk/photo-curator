import XCTest
@testable import PhotoRelay

final class MomentsCatalogTests: XCTestCase {
    func testSnapshotSurvivesReopenWithoutPriorityFilter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("catalog.json")
        let dates = [Date(timeIntervalSince1970: 900_000_000), Date()]
        let photos = dates.enumerated().map { index, date in
            IndexedPhoto(id: "photo-\(index)", created: date, modified: nil, latitude: nil,
                         longitude: nil, favorite: false, width: 100, height: 100)
        }
        let moments = MomentGrouping.group(photos)
        try MomentsCatalog(updated: Date(), moments: moments).save(to: file)
        let reopened = try XCTUnwrap(MomentsCatalog.load(from: file))
        XCTAssertEqual(reopened.moments.map(\.id), moments.map(\.id))
        XCTAssertEqual(reopened.moments.count, 2)
    }

    func testNewestPhotoClaimedBeforeAlphabeticalID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try CuratorStore(url: root.appendingPathComponent("index.sqlite3"))
        let photos = [IndexedPhoto(id: "a-old", created: Date(timeIntervalSince1970: 1), modified: nil,
            latitude: nil, longitude: nil, favorite: false, width: 100, height: 100),
            IndexedPhoto(id: "z-new", created: Date(), modified: nil,
            latitude: nil, longitude: nil, favorite: false, width: 100, height: 100)]
        try db.save(photos, generation: "test")
        for photo in photos { try db.enqueueAnalysis(asset: photo.id, revision: "r", analyzer: "v") }
        XCTAssertEqual(try db.claimAnalysis()?.asset, "z-new")
    }
}
