import XCTest
@testable import PhotoRelay

final class GroupReviewStoreTests: XCTestCase {
    func photo(_ id: String) -> IndexedPhoto {
        IndexedPhoto(id: id, created: Date(timeIntervalSince1970: 0), modified: nil, latitude: nil,
                     longitude: nil, favorite: false, width: 100, height: 100)
    }
    func group(_ id: String, _ members: [String], title: String = "") -> SuggestedPhotoGroup {
        SuggestedPhotoGroup(id: id, photos: members.map(photo), explanations: [:], title: title)
    }
    func testMergeSplitSaveReopenAndRegroup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GroupReviewStore(url: dir.appendingPathComponent("groups.json"))
        let merged = GroupReviewEditing.merge([group("one", ["a", "b"], title: "Trip"), group("two", ["c"])], selected: ["one", "two"])
        var split = GroupReviewEditing.split(merged, selected: ["b"])
        split[1].title = "Separate stop"
        let saved = try store.save(split, visible: ["a", "b", "c"], expectedRevision: 0)
        let reopened = try store.load()
        XCTAssertEqual(saved.groups, reopened.groups)
        let changed = GroupingProposal(groups: [group("new-auto", ["a", "b", "c", "d"])], suspiciousTimes: false)
        let resolved = reopened.applying(to: changed)
        XCTAssertEqual(resolved.groups.map { Set($0.photos.map(\.id)) }, [Set(["a", "c"]), Set(["b"]), Set(["d"])])
        XCTAssertEqual(resolved.groups[0].title, "Trip")
        XCTAssertEqual(resolved.groups[1].title, "Separate stop")
        XCTAssertEqual(resolved.groups[0].id, saved.groups[0].id)
        XCTAssertTrue(resolved.groups.allSatisfy { $0.inferredLocationSources.isEmpty })
    }
    func testPartialRangeSavePreservesHiddenMembersAndRejectsStaleWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GroupReviewStore(url: dir.appendingPathComponent("groups.json"))
        let saved = try store.save([group("one", ["a", "b"], title: "Trip")], visible: ["a", "b"], expectedRevision: 0)
        let revised = try store.save([group("new", ["a"], title: "Moved")], visible: ["a"], expectedRevision: saved.revision)
        XCTAssertEqual(Set(revised.groups.flatMap(\.members)), Set(["a", "b"]))
        XCTAssertEqual(revised.groups.first { $0.members.contains("b") }?.title, "Trip")
        XCTAssertThrowsError(try store.save([group("stale", ["a"])], visible: ["a"], expectedRevision: saved.revision))
        XCTAssertEqual(try store.load().revision, revised.revision)
    }
    func testInvalidPartitionAndCorruptArchiveAreNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GroupReviewStore(url: dir.appendingPathComponent("groups.json"))
        XCTAssertThrowsError(try store.save([group("x", ["a"]), group("y", ["a"])], visible: ["a"], expectedRevision: 0))
        try Data("bad archive".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.save([group("x", ["a"])], visible: ["a"], expectedRevision: 0))
        XCTAssertEqual(try String(contentsOf: store.url, encoding: .utf8), "bad archive")
    }
    func testSpecificSemanticsHelpButGenericLabelsDoNot() {
        let photos = [photo("a"), photo("b")]
        let generic = SemanticSceneEvidence.from(["people": 0.99, "outdoor": 0.99, "adult": 0.99])
        XCTAssertTrue(generic.clues.isEmpty)
        let castle = SemanticSceneEvidence.from(["castle": 0.95])
        let helped = EvidenceGrouping.propose(photos, text: [:], cutoff: 16, scenes: ["a": castle, "b": castle]) { _, _ in 17 }
        XCTAssertEqual(helped.groups.count, 1)
        XCTAssertTrue(helped.groups[0].explanations["b"]!.contains("castle"))
        let unchanged = EvidenceGrouping.propose(photos, text: [:], cutoff: 16, scenes: ["a": generic, "b": generic]) { _, _ in 17 }
        XCTAssertEqual(unchanged.groups.count, 2)
        let inside = SemanticSceneEvidence.from(["interior_room": 0.95])
        let conflict = EvidenceGrouping.propose(photos, text: [:], cutoff: 25, scenes: ["a": inside, "b": generic]) { _, _ in 1 }
        XCTAssertEqual(conflict.groups.count, 2)
    }
}
