import XCTest
@testable import PhotoCurator

/// Opt-in repair for empty `story_moments` shells. Never runs in normal CI.
final class LiveStoryMembershipRepairTests: XCTestCase {
    func testRepairLiveEmptyStoryMembership() async throws {
        guard ProcessInfo.processInfo.environment["PHOTO_CURATOR_REPAIR_LIVE_STORIES"] == "1" else {
            throw XCTSkip("Set PHOTO_CURATOR_REPAIR_LIVE_STORIES=1 to repair the live catalog")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("Photo Curator/curator/catalog-v2.sqlite3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let store = try CatalogV2Store(url: url)
        let beforeMissing = try await store.needsStoryProjection()
        XCTAssertTrue(beforeMissing, "Expected empty story_moments before repair")
        try await store.rebuildStories()
        let afterMissing = try await store.needsStoryProjection()
        XCTAssertFalse(afterMissing)
        let stories = try await store.storySummaries()
        XCTAssertFalse(stories.isEmpty)
        XCTAssertTrue(stories.contains { !$0.momentIDs.isEmpty })
        let linked = stories.reduce(0) { $0 + $1.momentIDs.count }
        print("Repaired \(stories.count) stories with \(linked) moment links")
    }
}
