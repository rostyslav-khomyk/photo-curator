import XCTest
@testable import PhotoRelay

final class MomentReviewTests: XCTestCase {
    @MainActor
    func testDescriptionPersistenceDoesNotReplaceTitle() {
        let name = "PhotoRelay.description.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MomentReviewDecisions(defaults: defaults)
        store.setTitle("My title", for: "moment")
        store.setDescription("My description", for: "moment")
        let restored = MomentReviewDecisions(defaults: defaults)
        XCTAssertEqual(restored.descriptions["moment"], "My description")
        XCTAssertEqual(restored.titles["moment"], "My title")
        store.setDescription("", for: "moment")
        XCTAssertNil(store.descriptions["moment"])
    }
    @MainActor
    func testTitlePersistsAndResetsWithoutChangingChoices() {
        let name = "PhotoRelay.titles.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MomentReviewDecisions(defaults: defaults)
        store.set(.include, for: "photo")
        store.setTitle("Summer trip", for: "moment")
        XCTAssertEqual(MomentReviewDecisions(defaults: defaults).titles["moment"], "Summer trip")
        store.setTitle("Summer ", for: "moment")
        XCTAssertEqual(store.titles["moment"], "Summer ")
        store.setTitle(" ", for: "moment")
        XCTAssertNil(MomentReviewDecisions(defaults: defaults).titles["moment"])
        XCTAssertEqual(store.values["photo"], .include)
    }
    @MainActor
    func testChoicesPersistAndAutomaticRemovesOverride() {
        let name = "PhotoRelay.review.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = MomentReviewDecisions(defaults: defaults)
        first.set(.exclude, for: "asset")
        XCTAssertEqual(MomentReviewDecisions(defaults: defaults).values["asset"], .exclude)
        first.set(nil, for: "asset")
        XCTAssertNil(MomentReviewDecisions(defaults: defaults).values["asset"])
    }

    @MainActor
    func testManualChoiceOverridesAutomaticWithoutChangingPhotos() {
        let photos = ["a", "b", "c"].map {
            IndexedPhoto(id: $0, created: nil, modified: nil, latitude: nil, longitude: nil, favorite: true, width: 10, height: 10)
        }
        let automatic = MomentSelection(selected: ["a"], pending: ["c"], similar: ["b"])
        let effective = MomentReviewDecisions.apply(["a": .exclude, "b": .include], to: automatic, photos: photos)
        XCTAssertEqual(effective.selected, ["b"])
        XCTAssertEqual(effective.pending, ["c"])
        XCTAssertTrue(effective.similar.isEmpty)
        XCTAssertEqual(automatic.selected, ["a"])
    }
}
