import XCTest
@testable import PhotoRelay

final class MomentSelectionTests: XCTestCase {
    func testCategoriesNeverSuppressEachOther() {
        var a = fixture("a")
        var b = fixture("b")
        a.similarityCategory = .photos
        b.similarityCategory = .screenshots
        let result = CuratorVisionResult(version: "test", faces: .available(0), aesthetics: .unavailable, featurePrint: .unavailable)
        let selection = MomentSelector.select([a, b], results: ["a": result, "b": result], threshold: 100, distance: { _, _ in 0 })
        XCTAssertEqual(selection.selected.count, 2)
    }

    func testCategorySpecificCutoff() {
        var a = fixture("a")
        var b = fixture("b")
        a.similarityCategory = .selfies
        b.similarityCategory = .selfies
        let result = CuratorVisionResult(version: "test", faces: .available(0), aesthetics: .unavailable, featurePrint: .unavailable)
        let results = ["a": result, "b": result]
        XCTAssertEqual(MomentSelector.select([a, b], results: results, thresholds: [.photos: 100, .selfies: 1], distance: { _, _ in 2 }).similar.count, 0)
        XCTAssertEqual(MomentSelector.select([a, b], results: results, thresholds: [.selfies: 3], distance: { _, _ in 2 }).similar.count, 1)
    }

    private func fixture(_ id: String, time: Double = 100, favorite: Bool = false) -> IndexedPhoto {
        IndexedPhoto(id: id, created: Date(timeIntervalSince1970: time), modified: nil,
                     latitude: nil, longitude: nil, favorite: favorite, width: 10, height: 10)
    }

    func testThresholdBoundaryAndInvalidDistances() {
        let photos = [fixture("a"), fixture("b")]
        let result = CuratorVisionResult(version: "test", faces: .available(0), aesthetics: .unavailable, featurePrint: .unavailable)
        let results = ["a": result, "b": result]
        XCTAssertEqual(MomentSelector.select(photos, results: results, threshold: 5, distance: { _, _ in 5 }).similar.count, 1)
        XCTAssertEqual(MomentSelector.select(photos, results: results, threshold: 4, distance: { _, _ in 5 }).similar.count, 0)
        for invalid: Float in [-1, .nan, .infinity] {
            XCTAssertEqual(MomentSelector.select(photos, results: results, threshold: 5, distance: { _, _ in invalid }).selected.count, 2)
        }
    }

    func testBoundaryExamplesMoveWithSlider() {
        let pairs = [Float(1), 3, 5].map { SimilarityPair(first: fixture("a"), second: fixture("b"), distance: $0) }
        XCTAssertNil(SimilarityPair.boundary(pairs, threshold: 0, similar: true))
        XCTAssertEqual(SimilarityPair.boundary(pairs, threshold: 3, similar: true)?.distance, 3)
        XCTAssertEqual(SimilarityPair.boundary(pairs, threshold: 3, similar: false)?.distance, 5)
        XCTAssertEqual(SimilarityPair.boundary(pairs, threshold: 2, similar: true)?.distance, 1)
        XCTAssertNil(SimilarityPair.boundary(pairs, threshold: 5, similar: false))
    }

    func testNearbyRepresentativeNotLostBehindUnrelatedFavorites() {
        let photos = [fixture("a", favorite: true)] + (0..<40).map { fixture("m\($0)", time: Double($0 + 1) * 1000, favorite: true) } + [fixture("z")]
        let result = CuratorVisionResult(version: "test", faces: .available(0), aesthetics: .unavailable, featurePrint: .unavailable)
        let results = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, result) })
        XCTAssertEqual(MomentSelector.select(photos, results: results, distance: { _, _ in 0 }).similar, ["z"])
    }

    func testFavoritesPendingAndNearDuplicates() {
        func photo(_ id: String, favorite: Bool = false) -> IndexedPhoto {
            IndexedPhoto(id: id, created: Date(timeIntervalSince1970: 100), modified: nil,
                         latitude: nil, longitude: nil, favorite: favorite, width: 10, height: 10)
        }
        let result = CuratorVisionResult(version: "test", faces: .available(0), aesthetics: .unavailable, featurePrint: .unavailable)
        let selection = MomentSelector.select([photo("a", favorite: true), photo("b", favorite: true), photo("c"), photo("d")],
                                             results: ["a": result, "b": result, "c": result], distance: { _, _ in 0 })
        XCTAssertEqual(Set(selection.selected), ["a", "b"])
        XCTAssertEqual(selection.similar, ["c"])
        XCTAssertEqual(selection.pending, ["d"])
        XCTAssertTrue(selection.explanations["a"]?.contains("Favorite") == true)
        XCTAssertTrue(selection.explanations["c"]?.contains("distance") == true)
        XCTAssertTrue(selection.explanations["d"]?.contains("not a rejection") == true)
    }

    func testUnknownSimilarityPreservesPhotos() {
        let photos = ["a", "b"].map { IndexedPhoto(id: $0, created: nil, modified: nil, latitude: nil, longitude: nil, favorite: false, width: 10, height: 10) }
        let result = CuratorVisionResult(version: "test", faces: .failed, aesthetics: .failed, featurePrint: .failed)
        let selection = MomentSelector.select(photos, results: ["a": result, "b": result])
        XCTAssertEqual(selection.selected.count, 2)
        XCTAssertTrue(selection.similar.isEmpty)
    }
}
