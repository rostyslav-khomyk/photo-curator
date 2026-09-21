import XCTest
@testable import PhotoRelay

final class MomentCatalogGroupingTests: XCTestCase {
    private func photo(_ id: String, _ time: Double) -> IndexedPhoto {
        IndexedPhoto(id: id, created: Date(timeIntervalSince1970: time), modified: nil,
                     latitude: nil, longitude: nil, favorite: false, width: 100, height: 100)
    }

    func testCrossDateReviewBecomesOneNamedMomentWithoutDuplicates() {
        let photos = [photo("a", 1), photo("b", 10), photo("c", 200_000)]
        let archive = GroupReviewArchive(groups: [.init(id: "saved", title: "Our weekend", members: ["a", "c"])])
        let output = MomentCatalogGrouping.build(photos, reviews: archive)
        let saved = output.first { $0.id == "saved" }
        XCTAssertEqual(saved?.reviewedGroupTitle, "Our weekend")
        XCTAssertEqual(saved?.photos.map(\.id), ["a", "c"])
        XCTAssertEqual(output.flatMap(\.photos).count, photos.count)
        XCTAssertEqual(Set(output.flatMap(\.photos).map(\.id)), Set(photos.map(\.id)))
    }

    func testUneditedGroupsKeepLegacyIDsAndPartialRemainderDoesNotInheritTitleID() {
        let photos = [photo("a", 1), photo("b", 10), photo("c", 200_000)]
        let original = MomentGrouping.group(photos)
        let untouched = MomentCatalogGrouping.build(photos, reviews: GroupReviewArchive())
        XCTAssertEqual(untouched.map(\.id), original.map(\.id))
        let edited = MomentCatalogGrouping.build(photos, reviews: GroupReviewArchive(groups: [
            .init(id: "saved", title: "New group", members: ["a"]) ]))
        let oldPair = original.first { $0.photos.count == 2 }!
        XCTAssertFalse(edited.contains { $0.id == oldPair.id })
        XCTAssertTrue(edited.contains { $0.photos.map(\.id) == ["b"] && $0.id.hasPrefix("remainder-") })
    }

    func testMissingMemberDoesNotEraseSavedDecisionAndNewPhotosRemainUnassigned() {
        let archive = GroupReviewArchive(groups: [.init(id: "saved", title: "Trip", members: ["a", "missing"])])
        let result = MomentCatalogGrouping.build([photo("a", 1), photo("new", 2)], reviews: archive)
        XCTAssertEqual(result.first { $0.id == "saved" }?.photos.map(\.id), ["a"])
        XCTAssertTrue(result.contains { $0.photos.map(\.id) == ["new"] })
        XCTAssertEqual(archive.groups[0].members, ["a", "missing"])
    }
}
