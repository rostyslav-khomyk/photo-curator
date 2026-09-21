import XCTest
@testable import PhotoRelay

final class LargeMomentWindowsTests: XCTestCase {
    private func parent() -> PhotoMoment {
        let photos = (0..<624).map { index in
            IndexedPhoto(id: "photo-\(index)", created: Date(timeIntervalSince1970: Double(index * 60)),
                         modified: nil, latitude: nil, longitude: nil, favorite: false,
                         width: 100, height: 100, similarityCategory: .photos)
        }
        return PhotoMoment(id: "parent", start: photos.first!.created!, end: photos.last!.created!, photos: photos,
                           reviewedGroupTitle: "My visit")
    }

    func testCoverageOverlapAndStableIdentity() throws {
        let parent = parent()
        let windows = try LargeMomentWindows.make(parent)
        XCTAssertEqual(windows.map { $0.ownedIDs.count }, [256, 256, 112])
        XCTAssertEqual(windows.flatMap(\.ownedIDs), parent.photos.map(\.id))
        XCTAssertTrue(windows.allSatisfy { $0.moment.photos.count <= 512 && $0.moment.id != parent.id })
        // Each four-photo comparison across a work boundary has complete context.
        for boundary in [256, 512] {
            let ids = Set(parent.photos[(boundary - 2)...(boundary + 1)].map(\.id))
            XCTAssertTrue(windows.contains { ids.isSubset(of: Set($0.moment.photos.map(\.id))) })
        }
        let shuffled = PhotoMoment(id: parent.id, start: parent.start, end: parent.end, photos: parent.photos.reversed())
        XCTAssertEqual(try LargeMomentWindows.make(shuffled).map { $0.moment.id }, windows.map { $0.moment.id })
        XCTAssertEqual(parent.reviewedGroupTitle, "My visit")
    }

    func testRestartAndEditedParentInvalidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = parent()
        let windows = try LargeMomentWindows.make(parent)
        let store = LargeMomentWindowStore(root: root)
        let first = windows[0]
        let record = try AutomaticMomentSegmentation.propose(first.moment, labels: [:], text: [:]) { _, _ in nil }
        try store.save(record, for: first)
        XCTAssertEqual(try LargeMomentWindowStore(root: root).next(in: windows)?.moment.id, windows[1].moment.id)
        let edited = PhotoMoment(id: parent.id, start: parent.start, end: parent.end, photos: Array(parent.photos.dropLast()))
        let changed = try LargeMomentWindows.make(edited)
        XCTAssertFalse(try store.completed(changed[0]))
        // Internal checkpoints cannot be loaded through the parent catalog namespace.
        XCTAssertNil(try AutomaticMomentStore(root: root).load(parent.id))
        for window in windows.dropFirst() {
            try store.save(AutomaticMomentSegmentation.propose(window.moment, labels: [:], text: [:]) { _, _ in nil }, for: window)
        }
        XCTAssertNil(try store.next(in: windows))
    }

    func testInvalidInputsRejected() throws {
        XCTAssertThrowsError(try LargeMomentWindows.make(parent(), size: 509))
        XCTAssertThrowsError(try LargeMomentWindows.make(parent(), size: 0))
        let source = parent()
        let duplicate = PhotoMoment(id: source.id, start: source.start, end: source.end, photos: source.photos + [source.photos[0]])
        XCTAssertThrowsError(try LargeMomentWindows.make(duplicate))
    }
}
