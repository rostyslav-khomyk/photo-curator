import XCTest
@testable import PhotoRelay

final class BalancedSelectionTests: XCTestCase {
    func testLocationCoverageAndUnknownSeparation() {
        func photo(_ id: String, lat: Double?, lon: Double?) -> IndexedPhoto {
            IndexedPhoto(id: id, created: Date(timeIntervalSince1970: 100), modified: nil,
                         latitude: lat, longitude: lon, favorite: false, width: 10, height: 10)
        }
        let photos = [photo("a", lat: 52, lon: 4), photo("b", lat: 52.001, lon: 4),
                      photo("c", lat: 53, lon: 4), photo("d", lat: nil, lon: nil)]
        let groups = CuratorLocationCoverage.groups(photos).map { Set($0.map(\.id)) }
        XCTAssertEqual(groups, [Set(["a", "b"]), Set(["c"]), Set(["d"])])
        XCTAssertEqual(CuratorLocationCoverage.groups(photos.reversed()).map { Set($0.map(\.id)) }, groups)
        XCTAssertNil(CuratorLocationCoverage.location(photo("bad", lat: 200, lon: .nan)))
        let result = CuratorVisionResult(version: "test", faces: .available(0), aesthetics: .available(AestheticSignal(score: 0.5, utility: false)), featurePrint: .unavailable)
        let results = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, result) })
        let base = MomentSelection(selected: photos.map(\.id), pending: [], similar: [])
        XCTAssertEqual(Set(BalancedMomentSelector.select(base, photos: photos, results: results).selected), ["a", "c", "d"])
        let distant = MomentSelector.select([photos[0], photos[2]], results: results, threshold: 100, distance: { _, _ in 0 })
        XCTAssertEqual(distant.selected.count, 2)
    }
    func testCoverageFavoritesAndMissingQuality() {
        func photo(_ id: String, time: Double, favorite: Bool = false) -> IndexedPhoto {
            IndexedPhoto(id: id, created: Date(timeIntervalSince1970: time), modified: nil,
                         latitude: nil, longitude: nil, favorite: favorite, width: 10, height: 10)
        }
        let photos = [photo("a", time: 100, favorite: true), photo("b", time: 110),
                      photo("c", time: 2000), photo("d", time: 2010), photo("e", time: 2020)]
        func result(_ score: Float) -> CuratorVisionResult {
            CuratorVisionResult(version: "test", faces: .available(0), aesthetics: .available(AestheticSignal(score: score, utility: false)), featurePrint: .unavailable)
        }
        let base = MomentSelection(selected: photos.map(\.id), pending: [], similar: [])
        let output = BalancedMomentSelector.select(base, photos: photos, results: ["a": result(0), "b": result(1), "c": result(0.8), "d": result(0.2)])
        XCTAssertEqual(Set(output.selected), ["a", "c", "e"])
        XCTAssertEqual(Set(output.alternatives), ["b", "d"])
        XCTAssertTrue(output.similar.isEmpty)
        XCTAssertEqual(base.selected.count, 5)
    }
}
