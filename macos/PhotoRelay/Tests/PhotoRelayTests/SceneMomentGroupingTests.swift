import XCTest
import SwiftUI
@testable import PhotoRelay

final class SceneMomentGroupingTests: XCTestCase {
    private func photos(_ count: Int = 8, located: Bool = false) -> [IndexedPhoto] {
        (0..<count).map { index in
            IndexedPhoto(id: String(format: "%03d", index), created: Date(timeIntervalSince1970: Double(index)), modified: nil,
                latitude: located ? 52 : nil, longitude: located ? 4 : nil, favorite: false, width: 100, height: 100)
        }
    }
    private func distance(_ a: String, _ b: String) -> Float? {
        let lhs = Int(a)!, rhs = Int(b)!
        if (lhs < 3 && rhs < 3) || ((4...6).contains(lhs) && (4...6).contains(rhs)) { return 5 }
        if Set([lhs, rhs]) == [2, 3] { return 5 } // Neighbor-only resemblance is insufficient.
        return 30
    }

    func testInterleavedScenesHaveNoChainsAndKeepUnresolvedPhotos() throws {
        let photos = photos()
        let moment = PhotoMoment(id: "mixed", start: photos.first!.created!, end: photos.last!.created!, photos: photos)
        let record = try AutomaticMomentSegmentation.propose(moment, labels: [:], text: [:], distance: distance)
        XCTAssertEqual(record.segments.filter { $0.kind == .scene }.map(\.members), [["000", "001", "002"], ["004", "005", "006"]])
        XCTAssertEqual(record.segments.first { $0.kind == .unresolved }?.members, ["003", "007"])
        XCTAssertEqual(Set(record.segments.flatMap(\.members)), Set(photos.map(\.id)))
        let reversed = try SceneMomentGrouping.groups(photos.reversed(), labels: [:], distance: distance)
        XCTAssertEqual(reversed.map { $0.map(\.id) }, record.segments.filter { $0.kind == .scene }.map(\.members))
    }

    func testSharedRecordedVenueAndOneSceneAreNotSplit() throws {
        XCTAssertTrue(try SceneMomentGrouping.groups(photos(located: true), labels: [:], distance: distance).isEmpty)
        let uniform = try SceneMomentGrouping.groups(photos(), labels: [:], distance: { _, _ in 5 })
        XCTAssertEqual(uniform.count, 1)
        XCTAssertEqual(uniform[0].count, 8)
        let located = photos(located: true)
        let moment = PhotoMoment(id: "same-place", start: located.first!.created!, end: located.last!.created!, photos: located)
        let result = try AutomaticMomentSegmentation.propose(moment, labels: [:], text: [:], distance: distance)
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].id, moment.id)
        XCTAssertNil(result.segments[0].kind)
    }

    func testSpecificClassificationSurvivesGenericTopLabels() {
        let labels = NarrativeVisualContext.retainedLabels([
            "people": 0.99, "adult": 0.98, "outdoor": 0.97, "sky": 0.96,
            "castle": 0.8, "beach": 0.1, "boat": .nan])
        XCTAssertEqual(labels, ["people", "adult", "outdoor", "sky", "castle"])
    }

    func testMissingEvidenceAndTinyPairsAreNotPublished() throws {
        for value: Float? in [nil, .nan, .infinity, -1] {
            XCTAssertTrue(try SceneMomentGrouping.groups(photos(), labels: [:], distance: { _, _ in value }).isEmpty)
        }
        XCTAssertTrue(try SceneMomentGrouping.groups(photos(), labels: [:], distance: { a, b in
            Int(a)! / 2 == Int(b)! / 2 ? 5 : 30
        }).isEmpty)
    }

    func testConflictingSceneHintsCannotBeOverruledByResemblance() throws {
        let groups = try SceneMomentGrouping.groups(photos(), labels: ["000": ["castle"], "002": ["beach"]], distance: distance)
        XCTAssertFalse(groups.contains { Set($0.map(\.id)).isSuperset(of: ["000", "002"]) })
    }

    func testWorkBudgetFailsClosedRatherThanPublishingPartialSearch() throws {
        var calls = 0
        let result = try SceneMomentGrouping.groups(photos(512), labels: [:]) { _, _ in calls += 1; return 30 }
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(calls, 8192)
    }

    @MainActor
    func testUserTitleAndCoverPresentation() throws {
        let photo = photos()[0]
        var moment = PhotoMoment(id: "named", start: photo.created!, end: photo.created!, photos: [photo])
        moment.narrative = .init(version: MomentNarrative.version, headline: "Automatic title", deck: nil,
            story: "Automatic description", place: nil, date: "Today", confidence: 0.8, provenance: ["test"], state: .automatic)
        moment.groupingState = .ready
        XCTAssertEqual(MomentPresentation.title(moment, custom: "My family trip"), "My family trip")
        XCTAssertEqual(MomentPresentation.status(moment, pending: false, userAuthored: true), "✓ Customized")
        XCTAssertFalse(MomentPresentation.status(moment, pending: true, userAuthored: true).contains("suggestion"))
        let cover = ImageRenderer(content: SimilarityThumbnail(photo: photo, height: 190, showsTimestamp: false).frame(width: 250))
        let preview = ImageRenderer(content: SimilarityThumbnail(photo: photo, height: 190).frame(width: 250))
        XCTAssertEqual(try XCTUnwrap(cover.cgImage).height, 190)
        XCTAssertGreaterThan(try XCTUnwrap(preview.cgImage).height, 190)
        moment.groupingKind = .unresolved
        XCTAssertTrue(MomentPresentation.title(moment, custom: nil).hasPrefix("Needs review"))
        XCTAssertEqual(MomentPresentation.title(moment, custom: "My trip"), "My trip")
    }

    func testUntitledMomentShowsHonestPreparationState() {
        let photo = photos()[0]
        let moment = PhotoMoment(id: "preparing", start: photo.created!, end: photo.created!, photos: [photo])
        XCTAssertFalse(MomentPresentation.title(moment, custom: nil).contains("A look back"))
        XCTAssertEqual(MomentPresentation.status(moment, pending: true, userAuthored: false),
                       "Title preparation is in progress…")
    }
}
