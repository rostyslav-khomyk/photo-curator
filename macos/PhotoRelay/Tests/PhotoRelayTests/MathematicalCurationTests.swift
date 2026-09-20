import XCTest
@testable import PhotoRelay

final class MathematicalCurationTests: XCTestCase {
    func testMissingEvidenceStaysUnknown() {
        let evidence = CuratorCalibration.percentile(nil, cutoffs: [0.1, 0.2])
        XCTAssertFalse(evidence.available)
        XCTAssertEqual(evidence.confidence, 0)
    }

    func testPlaceConflictRaisesBoundaryProbability() {
        func observation(conflict: Bool) -> BoundaryObservation {
            .init(earlierID: "a", laterID: "b", logTimeGap: log1p(60),
                  geoMeters: .init(value: nil, confidence: 0, source: "gps", version: "1"),
                  visualPercentile: .init(value: nil, confidence: 0, source: "vision", version: "1"),
                  ocrOverlap: .init(value: nil, confidence: 0, source: "ocr", version: "1"), placeConflict: conflict)
        }
        XCTAssertGreaterThan(ProbabilisticBoundaryModel.estimate(observation(conflict: true)).probability,
                             ProbabilisticBoundaryModel.estimate(observation(conflict: false)).probability)
    }

    func testProtectedHighlightsAreHardConstraintsAndCoverageAddsVariety() {
        let candidates = [
            SubmodularHighlightSelector.Candidate(id: "favorite", quality: 0, protected: true, roles: ["portrait"]),
            .init(id: "duplicate", quality: 1, protected: false, roles: ["portrait"]),
            .init(id: "scene", quality: 0.6, protected: false, roles: ["establishing"])
        ]
        let selected = SubmodularHighlightSelector.select(candidates, maximum: 2) { a, b in
            if a == b { return 1 }; return Set([a, b]) == Set(["favorite", "duplicate"]) ? 0.99 : 0.05
        }
        XCTAssertEqual(Set(selected), Set(["favorite", "scene"]))
    }

    func testNarrativeSalienceRejectsSingletonAndPenalizesRepetition() {
        XCTAssertEqual(NarrativeInformationScorer.salience(support: 1, inspected: 8, documentFrequency: 1, corpusSize: 100, confidence: 1), 0)
        let fresh = NarrativeInformationScorer.score(grounding: 1, specificity: 1, unsupportedClaims: 0, metadataDuplication: false, similarityToRecent: 0)
        let repeated = NarrativeInformationScorer.score(grounding: 1, specificity: 1, unsupportedClaims: 0, metadataDuplication: false, similarityToRecent: 1)
        XCTAssertGreaterThan(fresh, repeated)
    }
}
