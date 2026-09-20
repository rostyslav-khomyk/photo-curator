import XCTest
@testable import PhotoRelay

final class ScenerySelectionTests: XCTestCase {
    private func photo(_ id: String, favorite: Bool = false, lat: Double? = 52) -> IndexedPhoto {
        IndexedPhoto(id: id, created: Date(timeIntervalSince1970: id == "a" ? 0 : 3600), modified: nil,
                     latitude: lat, longitude: lat == nil ? nil : 5, favorite: favorite, width: 100, height: 100)
    }
    private func result(_ score: Float, faces: VisionSignal<Int> = .available(0)) -> CuratorVisionResult {
        CuratorVisionResult(version: "test", faces: faces, aesthetics: .available(.init(score: score, utility: false)), featurePrint: .unavailable)
    }
    @MainActor
    func testRepeatedSceneryBecomesAlternativeNotDuplicate() {
        let photos = [photo("a"), photo("b")]
        let input = MomentSelection(selected: ["a", "b"], pending: [], similar: [])
        let output = ScenerySelection.select(input, photos: photos, labels: ["a": ["castle"], "b": ["castle"]],
            results: ["a": result(0.9), "b": result(0.5)], distance: { _, _ in 10 })
        XCTAssertEqual(output.selected, ["a"])
        XCTAssertEqual(output.alternatives, ["b"])
        XCTAssertTrue(output.similar.isEmpty)
        XCTAssertEqual(input.selected.count, 2)
        XCTAssertEqual(Set(MomentReviewDecisions.apply(["b": .include], to: output, photos: photos).selected), ["a", "b"])
    }
    func testPeopleFavoritesUnknownAndDistantLocationsStay() {
        let input = MomentSelection(selected: ["a", "b"], pending: [], similar: [])
        for other in [photo("b", favorite: true), photo("b", lat: nil), photo("b", lat: 53)] {
            let output = ScenerySelection.select(input, photos: [photo("a"), other], labels: ["a": ["castle"], "b": ["castle"]],
                results: ["a": result(0.9), "b": result(0.5)], distance: { _, _ in 0 })
            XCTAssertEqual(output.selected, input.selected)
        }
        for faces: VisionSignal<Int> in [.available(1), .unavailable, .failed] {
            let output = ScenerySelection.select(input, photos: [photo("a"), photo("b")], labels: ["a": ["castle"], "b": ["castle"]],
                results: ["a": result(0.9), "b": result(0.5, faces: faces)], distance: { _, _ in 0 })
            XCTAssertEqual(output.selected, input.selected)
        }
    }
    func testNoSimilarityChainsOrInvalidDistances() {
        let photos = [photo("a"), photo("b"), photo("c")]
        let input = MomentSelection(selected: ["a", "b", "c"], pending: [], similar: [])
        let results = ["a": result(3), "b": result(2), "c": result(1)]
        let labels = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, ["castle"]) })
        let output = ScenerySelection.select(input, photos: photos, labels: labels, results: results) { a, b in
            a == results["c"] && b == results["a"] ? 30 : 10
        }
        XCTAssertEqual(output.selected, ["a", "c"])
        for invalid: Float in [.nan, .infinity, -1, 30] {
            XCTAssertEqual(ScenerySelection.select(input, photos: photos, labels: labels, results: results,
                distance: { _, _ in invalid }).selected, input.selected)
        }
    }
}
