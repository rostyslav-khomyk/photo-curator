import XCTest
@testable import PhotoRelay

final class AutomaticMomentSegmentationTests: XCTestCase {
    private func moment() -> PhotoMoment {
        let photos = (0..<4).map { index in
            IndexedPhoto(id: String(index), created: Date(timeIntervalSince1970: Double(index)), modified: nil,
                         latitude: nil, longitude: nil, favorite: false, width: 100, height: 100)
        }
        return PhotoMoment(id: "parent", start: photos.first!.created!, end: photos.last!.created!, photos: photos)
    }
    private let labels = ["0": ["castle"], "1": ["castle"], "2": ["beach"], "3": ["beach"]]
    private func distance(_ a: String, _ b: String) -> Float? { a == "1" && b == "2" ? 25 : 5 }

    func testRepeatedScenesAndVisualBoundarySplitWithCompleteCoverage() throws {
        let record = try AutomaticMomentSegmentation.propose(moment(), labels: labels, text: [:], distance: distance)
        XCTAssertEqual(record.segments.map(\.members), [["0", "1"], ["2", "3"]])
        XCTAssertTrue(record.segments[1].reason.contains("unverified"))
    }

    func testMissingEvidenceAndVisualChangeAloneDoNotSplit() throws {
        XCTAssertEqual(try AutomaticMomentSegmentation.propose(moment(), labels: labels, text: [:], distance: { _, _ in nil }).segments.count, 1)
        XCTAssertEqual(try AutomaticMomentSegmentation.propose(moment(), labels: [:], text: [:], distance: distance).segments.count, 1)
    }

    func testPersistenceAndProtectedParent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutomaticMomentStore(root: root)
        let input = moment()
        let record = try AutomaticMomentSegmentation.propose(input, labels: labels, text: [:], distance: distance)
        try store.save(record, for: input)
        XCTAssertEqual(try store.apply(input, protected: []).count, 2)
        XCTAssertEqual(try store.apply(input, protected: [input.id]).map(\.id), [input.id])
        XCTAssertEqual(try store.load(input.id)?.fingerprint, record.fingerprint)
    }

    func testDuplicateMembershipRejected() throws {
        let input = moment()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = AutomaticMomentRecord(fingerprint: try AutomaticMomentSegmentation.fingerprint(input), segments: [
            .init(id: "a", members: ["0", "1", "2", "3"], reason: "test"),
            .init(id: "b", members: ["0"], reason: "test")])
        XCTAssertThrowsError(try AutomaticMomentStore(root: root).save(bad, for: input))
    }

    func testMetadataEditInvalidatesProposalAndProtectedChildRetainsIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutomaticMomentStore(root: root)
        let input = moment()
        let record = try AutomaticMomentSegmentation.propose(input, labels: labels, text: [:], distance: distance)
        try store.save(record, for: input)
        let edited = input.photos.map {
            IndexedPhoto(id: $0.id, created: $0.created, modified: Date(timeIntervalSince1970: 99),
                latitude: nil, longitude: nil, favorite: false, width: 100, height: 100)
        }
        let updated = PhotoMoment(id: input.id, start: input.start, end: input.end, photos: edited)
        let stale = try store.apply(updated, protected: [])
        XCTAssertEqual(stale.count, 1)
        XCTAssertEqual(stale[0].groupingState, .preparing)
        let retained = try store.apply(updated, protected: [record.segments[0].id])
        XCTAssertEqual(retained.map(\.id), record.segments.map(\.id))
        XCTAssertEqual(Set(retained.flatMap(\.photos).map(\.id)), Set(edited.map(\.id)))
    }

    func testOversizeCollectionWaitsForInternalWindows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let photos = (0..<513).map { index in
            IndexedPhoto(id: "\(index)", created: Date(timeIntervalSince1970: Double(index)), modified: nil,
                latitude: nil, longitude: nil, favorite: false, width: 100, height: 100)
        }
        let input = PhotoMoment(id: "large", start: photos.first!.created!, end: photos.last!.created!, photos: photos)
        let projected = try AutomaticMomentStore(root: root).apply(input, protected: [])
        XCTAssertEqual(projected[0].groupingState, .preparing)
        XCTAssertEqual(projected.count, 1)
        XCTAssertTrue(projected[0].groupingReason?.contains("0 of 3") == true)
        XCTAssertEqual(projected[0].photos.count, 513)
        XCTAssertThrowsError(try AutomaticMomentSegmentation.propose(input, labels: [:], text: [:], distance: distance))
    }
}
