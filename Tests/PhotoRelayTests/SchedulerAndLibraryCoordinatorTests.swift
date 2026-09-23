import XCTest
@testable import PhotoRelay

final class SchedulerAndLibraryCoordinatorTests: XCTestCase {
    func testSchedulerCoalescesWakeups() async {
        let scheduler = CurationScheduler()
        await scheduler.wake(.startup)
        await scheduler.wake(.startup)
        await scheduler.wake(.userRequested)
        let events = await scheduler.next()
        XCTAssertEqual(events, [.startup, .userRequested])
        await scheduler.stop()
    }

    func testSchedulerWakesAtDeadlineWithoutPolling() async {
        let scheduler = CurationScheduler()
        await scheduler.wake(.retryDue, at: Date().addingTimeInterval(0.02))
        let events = await scheduler.next()
        XCTAssertEqual(events, [.retryDue])
        await scheduler.stop()
    }

    func testImmediateWakeReplacesScheduledWakeForSameEvent() async {
        let scheduler = CurationScheduler()
        await scheduler.wake(.retryDue, at: Date().addingTimeInterval(0.02))
        await scheduler.wake(.retryDue)
        let immediate = await scheduler.next()
        XCTAssertEqual(immediate, [.retryDue])
        await scheduler.wake(.startup, at: Date().addingTimeInterval(0.04))
        let later = await scheduler.next()
        XCTAssertEqual(later, [.startup])
        await scheduler.stop()
    }

    func testExpectedMutationIsSuppressedButExternalChangesRemain() {
        var buffer = LibraryChangeBuffer()
        let operation = UUID()
        buffer.expect(operation: operation, assetIDs: ["favorite", "deleted"], effect: .update)
        buffer.expect(operation: operation, assetIDs: ["deleted"], effect: .removal)
        buffer.receive(updated: ["favorite", "external"], removed: ["deleted"], full: false)

        let batch = buffer.drain(limit: 100)
        XCTAssertEqual(batch.updated, ["external"])
        XCTAssertTrue(batch.removed.isEmpty)
        XCTAssertFalse(batch.requiresVerification)
    }

    func testLibraryChangesCoalesceAndDrainInBoundedBatches() {
        var buffer = LibraryChangeBuffer()
        buffer.receive(updated: ["a", "b", "c"], removed: [], full: false)
        buffer.receive(updated: [], removed: ["b"], full: true)

        let first = buffer.drain(limit: 2)
        XCTAssertEqual(first.removed, ["b"])
        XCTAssertEqual(first.updated.count, 1)
        XCTAssertTrue(first.requiresVerification)
        XCTAssertTrue(first.hasMore)

        let second = buffer.drain(limit: 2)
        XCTAssertEqual(first.updated.union(second.updated), ["a", "c"])
        XCTAssertFalse(second.hasMore)
    }
}
