import XCTest
@testable import PhotoRelay

final class MomentMergeTests: XCTestCase {
    private func moment(_ id: String, _ assets: [String]) -> PhotoMoment {
        let date = Date(timeIntervalSince1970: 100)
        return PhotoMoment(id: id, start: date, end: date, photos: assets.map {
            IndexedPhoto(id: $0, created: date, modified: nil, latitude: nil, longitude: nil,
                favorite: false, width: 100, height: 100)
        })
    }

    func testToggleForwardReverseRangesAndMissingAnchor() {
        var selection = MomentMultiSelection()
        let ordered = ["a", "b", "c", "d"]
        selection.click("b", ordered: ordered, range: false)
        selection.click("d", ordered: ordered, range: true)
        XCTAssertEqual(selection.ids, ["b", "c", "d"])
        selection.click("a", ordered: ordered, range: true)
        XCTAssertEqual(selection.ids, Set(ordered))
        selection.click("c", ordered: ordered, range: false)
        XCTAssertFalse(selection.ids.contains("c"))
        selection.click("a", ordered: ["a", "b"], range: true)
        XCTAssertFalse(selection.ids.contains("a"))
    }

    func testMergeRestartsProtectsMembershipAndRetainsSourceText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GroupReviewStore(url: root.appendingPathComponent("groups.json"))
        let a = moment("a", ["1", "2"]), b = moment("b", ["3"])
        let merged = try store.merge([a, b], title: "Our trip", sourceText: ["a": "First title\nFirst description", "b": "Second title"], expectedRevision: 0)
        let reopened = try store.load()
        XCTAssertEqual(reopened.groups.first, merged)
        let regrouped = MomentCatalogGrouping.build(a.photos + b.photos, reviews: reopened)
        XCTAssertEqual(regrouped.count, 1)
        XCTAssertEqual(regrouped[0].groupingState, .reviewed)
        XCTAssertEqual(regrouped[0].reviewedGroupTitle, "Our trip")
        XCTAssertEqual(merged.sourceText?["b"], "Second title")
        XCTAssertThrowsError(try store.merge([a, b], title: "Stale", sourceText: [:], expectedRevision: 0))
        XCTAssertEqual(try store.load().groups, reopened.groups)
        let partial = moment(merged.id, ["1"])
        let next = try store.merge([partial, moment("c", ["4"])], title: "Bigger trip", sourceText: [:], expectedRevision: 1)
        XCTAssertEqual(next.members, ["1", "2", "3", "4"])
        XCTAssertEqual(next.sourceText?["a"], "First title\nFirst description")
        let edit = SuggestedPhotoGroup(id: next.id, photos: moment(next.id, ["1", "2", "3", "4"]).photos,
            explanations: [:], title: "Renamed")
        let saved = try store.save([edit], visible: next.members, expectedRevision: 2)
        XCTAssertEqual(saved.groups[0].sourceText, next.sourceText)
    }

    func testInvalidMergeDoesNotCreateReview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GroupReviewStore(url: root.appendingPathComponent("groups.json"))
        let a = moment("a", ["1"])
        XCTAssertThrowsError(try store.merge([a], title: "Trip", sourceText: [:], expectedRevision: 0))
        XCTAssertThrowsError(try store.merge([a, moment("b", ["1"])], title: "Trip", sourceText: [:], expectedRevision: 0))
        XCTAssertEqual(try store.load().revision, 0)
    }
}
