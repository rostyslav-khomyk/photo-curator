import XCTest
@testable import PhotoCurator

final class AnalysisPhaseTextTests: XCTestCase {
    func testEachPhaseNamesItsWorkAndIsRecognizedAsAnalysisStatus() {
        let visual = AnalysisPhaseText.visual(remaining: 12)
        let text = AnalysisPhaseText.text((done: 3, total: 9))
        let moments = AnalysisPhaseText.moments((done: 40, total: 7138))

        XCTAssertTrue(visual.hasPrefix("Analyzing photos:"))
        XCTAssertTrue(text.hasPrefix("Reading text in photos: 3 of 9"))
        XCTAssertTrue(moments.hasPrefix("Refining Moments: 40 of"))
        for status in [AnalysisPhaseText.starting, visual, text, moments] {
            XCTAssertTrue(AnalysisPhaseText.isPhase(status))
        }
        XCTAssertFalse(AnalysisPhaseText.isPhase("Available local evidence processed."))
        XCTAssertTrue(AnalysisPhaseText.isSettled(AnalysisPhaseText.settled))
        XCTAssertFalse(AnalysisPhaseText.isSettled(AnalysisPhaseText.starting))
    }
}
