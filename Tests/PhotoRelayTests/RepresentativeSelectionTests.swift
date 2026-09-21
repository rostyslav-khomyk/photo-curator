import XCTest
@testable import PhotoRelay

final class RepresentativeSelectionTests: XCTestCase {
    private func photo(_ id: String, time: Double, favorite: Bool = false) -> IndexedPhoto {
        IndexedPhoto(id: id, created: Date(timeIntervalSince1970: time), modified: nil,
                     latitude: nil, longitude: nil, favorite: favorite, width: 100, height: 100)
    }

    private func result(_ score: Float) -> CuratorVisionResult {
        CuratorVisionResult(version: "test", faces: .available(0),
                            aesthetics: .available(AestheticSignal(score: score, utility: false)),
                            featurePrint: .unavailable)
    }

    func testBudgetLimitsByCollectionSize() {
        XCTAssertEqual(RepresentativeSelector.targetBudget(for: 1), 1)
        XCTAssertEqual(RepresentativeSelector.targetBudget(for: 15), 15)
        XCTAssertEqual(RepresentativeSelector.targetBudget(for: 20), 20)
        XCTAssertEqual(RepresentativeSelector.targetBudget(for: 45), 20)
        XCTAssertEqual(RepresentativeSelector.targetBudget(for: 150), 25)
        XCTAssertEqual(RepresentativeSelector.targetBudget(for: 587), 35)
    }

    func testRepresentativeCompactionCapsOversizedMoments() {
        var photos: [IndexedPhoto] = []
        var results: [String: CuratorVisionResult] = [:]
        for i in 0..<150 {
            let p = photo("p-\(i)", time: Double(1000 + i * 60), favorite: i % 2 == 0)
            photos.append(p)
            results[p.id] = result(Float(i % 10) / 10.0)
        }
        let initialSelection = MomentSelection(selected: photos.map { $0.id }, pending: [], similar: [])

        let compacted = RepresentativeSelector.select(initialSelection, photos: photos, results: results)
        XCTAssertGreaterThanOrEqual(compacted.selected.count, photos.filter(\.favorite).count)
        XCTAssertEqual(compacted.alternatives.count, 150 - compacted.selected.count)
        XCTAssertEqual(Set(compacted.selected).count, compacted.selected.count)
        XCTAssertTrue(Set(compacted.selected).isDisjoint(with: Set(compacted.alternatives)))
        XCTAssertTrue(Set(photos.filter(\.favorite).map(\.id)).isSubset(of: Set(compacted.selected)))
        XCTAssertTrue(compacted.alternatives.allSatisfy { compacted.explanations[$0] != nil })
    }

    func testSmallCollectionsAreUncompacted() {
        var photos: [IndexedPhoto] = []
        var results: [String: CuratorVisionResult] = [:]
        for i in 0..<15 {
            let p = photo("s-\(i)", time: Double(100 + i * 10))
            photos.append(p)
            results[p.id] = result(0.5)
        }
        let initial = MomentSelection(selected: photos.map { $0.id }, pending: [], similar: [])
        let output = RepresentativeSelector.select(initial, photos: photos, results: results)
        XCTAssertEqual(output.selected.count, 15)
        XCTAssertTrue(output.alternatives.isEmpty)
    }

    func testTemporalSpreadAcrossVisit() {
        var photos: [IndexedPhoto] = []
        var results: [String: CuratorVisionResult] = [:]
        for i in 0..<60 {
            let p = photo("t-\(i)", time: Double(i * 360))
            photos.append(p)
            results[p.id] = result(Float(i) / 60.0)
        }
        let initial = MomentSelection(selected: photos.map { $0.id }, pending: [], similar: [])
        let output = RepresentativeSelector.select(initial, photos: photos, results: results)
        XCTAssertTrue((RepresentativeSelector.minimumBudget(for: 60)...20).contains(output.selected.count))

        let byID: [String: IndexedPhoto] = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        let selectedDates = output.selected.compactMap { byID[$0]?.created }
        let minDate = selectedDates.min()!
        let maxDate = selectedDates.max()!
        XCTAssertTrue(minDate.timeIntervalSince(photos.first!.created!) <= Double(3 * 360))
        XCTAssertTrue(maxDate.timeIntervalSince(minDate) >= Double(45 * 360))
    }

    func testUncuratedTripNeedsNoFavoritesToProduceAUsefulShortlist() {
        var photos: [IndexedPhoto] = [], results: [String: CuratorVisionResult] = [:]
        for i in 0..<90 {
            let p = photo("trip-\(i)", time: Double(i * 300))
            photos.append(p)
            results[p.id] = result(Float((i * 7) % 13) / 13)
        }
        XCTAssertFalse(photos.contains(where: \.favorite))
        let output = RepresentativeSelector.select(.init(selected: photos.map(\.id), pending: [], similar: []),
                                                   photos: photos, results: results)
        XCTAssertTrue((RepresentativeSelector.minimumBudget(for: photos.count)...RepresentativeSelector.targetBudget(for: photos.count))
            .contains(output.selected.count))
        let selected = Set(output.selected)
        XCTAssertTrue(selected.contains(photos.first!.id))
        XCTAssertTrue(selected.contains(photos.last!.id))
        XCTAssertEqual(selected.count + output.alternatives.count, photos.count)
    }
}
