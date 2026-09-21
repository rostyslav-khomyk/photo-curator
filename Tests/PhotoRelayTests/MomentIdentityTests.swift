import XCTest
@testable import PhotoRelay

final class MomentIdentityTests: XCTestCase {
    func testAnchorRemovalPreservesIdentity() throws {
        let old = [MomentIdentityEntry(id: "trip", members: ["a", "b", "c"])]
        let result = try MomentIdentityResolver.resolve(previous: old, groups: [["b", "c", "d"]])
        XCTAssertEqual(result.current.first?.id, "trip")
        XCTAssertTrue(result.retiredIDs.isEmpty)
    }

    func testSplitAndMergeDoNotTransferTitlesByGuess() throws {
        let old = [MomentIdentityEntry(id: "trip", members: ["a", "b", "c", "d"])]
        let split = try MomentIdentityResolver.resolve(previous: old, groups: [["a", "b"], ["c", "d"]])
        XCTAssertEqual(split.retiredIDs, ["trip"])
        XCTAssertFalse(split.current.contains { $0.id == "trip" })
        let merged = try MomentIdentityResolver.resolve(previous: split.current, groups: [["a", "b", "c", "d"]])
        XCTAssertEqual(merged.retiredIDs, Set(split.current.map(\.id)))
    }

    func testDurableAnchorsDominateOverlapAndFailClosedWhenSplit() throws {
        let old = [MomentIdentityEntry(id: "trip", members: ["a", "b", "c", "d"])]
        let inherited = try MomentIdentityResolver.resolve(previous: old,
            groups: [["a"], ["b", "c", "d", "new"]], anchors: ["trip": ["b", "c"]])
        XCTAssertEqual(inherited.current[1].id, "trip")
        XCTAssertThrowsError(try MomentIdentityResolver.resolve(previous: old,
            groups: [["a", "b"], ["c", "d"]], anchors: ["trip": ["b", "c"]]))
    }

    func testScopePersistenceAndAmbiguousInputRejection() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("identities.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try MomentIdentityStore(url: url).reconcile([["a", "b"]], scope: "complete-test-library")
        let next = try MomentIdentityStore(url: url).reconcile([["b", "c"]], scope: "complete-test-library")
        XCTAssertEqual(first.current.first?.id, next.current.first?.id)
        XCTAssertThrowsError(try MomentIdentityStore(url: url).reconcile([["a"]], scope: "partial-range"))
        XCTAssertThrowsError(try MomentIdentityResolver.resolve(previous: [], groups: [["a"], ["a"]]))
    }
}
