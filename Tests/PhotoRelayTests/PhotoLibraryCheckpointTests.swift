import XCTest
@testable import PhotoRelay

final class PhotoLibraryCheckpointTests: XCTestCase {
    private func fingerprint(count: Int = 2, suffix: String = "a") -> PhotoLibraryFingerprint {
        PhotoLibraryFingerprint(count: count, newest: [
            .init(id: "newest-\(suffix)", modified: Date(timeIntervalSince1970: 100))
        ])
    }

    func testMatchingRecentCheckpointSkipsFullReconciliation() {
        let now = Date(timeIntervalSince1970: 1_000)
        let value = fingerprint()
        let checkpoint = PhotoLibraryCheckpoint(fingerprint: value, fullyVerifiedAt: now.addingTimeInterval(-60))
        XCTAssertFalse(checkpoint.requiresFullReconciliation(current: value, now: now))
    }

    func testCountHeadOrAgeRequiresFullReconciliation() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let checkpoint = PhotoLibraryCheckpoint(fingerprint: fingerprint(), fullyVerifiedAt: now)
        XCTAssertTrue(checkpoint.requiresFullReconciliation(current: fingerprint(count: 3), now: now))
        XCTAssertTrue(checkpoint.requiresFullReconciliation(current: fingerprint(suffix: "b"), now: now))
        XCTAssertTrue(checkpoint.requiresFullReconciliation(current: fingerprint(),
            now: now.addingTimeInterval(7 * 24 * 60 * 60)))
    }

    func testReplayableTokenDefersLibraryDifferencesToPersistentHistory() throws {
        let now = Date()
        let token = try XCTUnwrap(PhotoLibraryChangeToken.capture())
        let checkpoint = PhotoLibraryCheckpoint(
            fingerprint: fingerprint(count: 1), fullyVerifiedAt: now, persistentToken: token)

        XCTAssertFalse(checkpoint.requiresFullReconciliation(
            current: fingerprint(count: 200_000, suffix: "changed"), now: now))
    }

    func testUnreadableTokenRequiresFullReconciliation() {
        let now = Date()
        let checkpoint = PhotoLibraryCheckpoint(
            fingerprint: fingerprint(), fullyVerifiedAt: now, persistentToken: Data("bad".utf8))

        XCTAssertTrue(checkpoint.requiresFullReconciliation(current: fingerprint(), now: now))
    }

    func testIncrementalFingerprintUpdatePreservesFullVerificationDate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoLibraryCheckpointStore(url: root.appendingPathComponent("checkpoint.json"))
        let date = Date(timeIntervalSince1970: 123)
        try store.save(.init(fingerprint: fingerprint(), fullyVerifiedAt: date))
        try store.updateFingerprint(fingerprint(count: 1, suffix: "new"))
        XCTAssertEqual(store.load(), .init(fingerprint: fingerprint(count: 1, suffix: "new"),
                                           fullyVerifiedAt: date))
    }
}
