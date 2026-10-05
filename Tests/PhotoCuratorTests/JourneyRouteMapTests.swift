import XCTest
import CoreLocation
@testable import PhotoCurator

final class JourneyRouteMapTests: XCTestCase {
    func testModelBuildsPinsAndLegsFromStops() throws {
        let stops = [
            JourneyStopEvidence(start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: 3_600), latitude: 52.1, longitude: 4.9,
                momentCount: 1, photoCount: 10, place: "Home", confidence: 1),
            JourneyStopEvidence(start: Date(timeIntervalSince1970: 20_000),
                end: Date(timeIntervalSince1970: 40_000), latitude: 48.14, longitude: 11.58,
                momentCount: 3, photoCount: 40, place: "Munich", confidence: 0.9,
                transportFromPrevious: JourneyLegEvidence(mode: .overland, distanceMeters: 650_000,
                    elapsedSeconds: 16_000, confidence: 0.65)),
            JourneyStopEvidence(start: Date(timeIntervalSince1970: 80_000),
                end: Date(timeIntervalSince1970: 90_000), latitude: 41.9, longitude: 12.5,
                momentCount: 2, photoCount: 20, place: "Rome", confidence: 0.9,
                transportFromPrevious: JourneyLegEvidence(mode: .air, distanceMeters: 700_000,
                    elapsedSeconds: 7_200, confidence: 0.8))
        ]
        let model = try XCTUnwrap(JourneyRouteMapModel.from(stops: stops))
        XCTAssertEqual(model.pins.count, 3)
        XCTAssertEqual(model.pins.map(\.title), ["Home", "Munich", "Rome"])
        XCTAssertEqual(model.legs.count, 2)
        XCTAssertEqual(model.legs[0].mode, .overland)
        XCTAssertEqual(model.legs[1].mode, .air)
        XCTAssertTrue(model.legs[0].prefersRoadRoute)
        XCTAssertFalse(model.legs[1].prefersRoadRoute)
        XCTAssertGreaterThan(model.region.span.latitudeDelta, 0)
        XCTAssertGreaterThan(model.endpointRadiusMeters, 1_000)
    }

    func testStopFilterUnionsSelectedFlagsAndClearsWhenEmpty() {
        let early = JourneyStopEvidence(start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 100), latitude: 48, longitude: 2,
            momentCount: 1, photoCount: 2, place: "Paris", confidence: 1)
        let late = JourneyStopEvidence(start: Date(timeIntervalSince1970: 500),
            end: Date(timeIntervalSince1970: 800), latitude: 45, longitude: 5,
            momentCount: 1, photoCount: 2, place: "Lyon", confidence: 1)
        let moments = [
            summary("paris", start: 10, end: 20),
            summary("lyon", start: 600, end: 700),
            summary("gap", start: 200, end: 300)
        ]
        XCTAssertEqual(JourneyMomentFilter.applying(moments, stops: [early, late], selected: []).map(\.id),
                       ["paris", "lyon", "gap"])
        XCTAssertEqual(JourneyMomentFilter.applying(moments, stops: [early, late], selected: [0]).map(\.id),
                       ["paris"])
        XCTAssertEqual(JourneyMomentFilter.applying(moments, stops: [early, late], selected: [0, 1]).map(\.id),
                       ["paris", "lyon"])
    }

    private func summary(_ id: String, start: TimeInterval, end: TimeInterval) -> MomentSummary {
        MomentSummary(id: id, revision: 1, start: Date(timeIntervalSince1970: start),
            end: Date(timeIntervalSince1970: end), headline: nil, photoCount: 1, highlightCount: 0,
            coverAssetID: nil, fallbackCoverAssetIDs: [], customized: false, inPhotos: false,
            inGoogle: false, narrativeReady: true, groupingReady: true)
    }

    func testModelIgnoresInvalidCoordinates() {
        let stops = [
            JourneyStopEvidence(start: Date(), end: Date(), latitude: 0, longitude: 0,
                momentCount: 1, photoCount: 1, place: "Nowhere", confidence: 0.1),
            JourneyStopEvidence(start: Date(), end: Date(), latitude: 52.1, longitude: 4.9,
                momentCount: 1, photoCount: 1, place: "Home", confidence: 1)
        ]
        XCTAssertNil(JourneyRouteMapModel.from(stops: stops))
    }

    func testDirectionsCacheKeyIsStable() {
        let leg = JourneyRouteMapModel.LegPath(
            fromIndex: 0, toIndex: 1, mode: .overland, distanceMeters: 50_000,
            elapsedSeconds: 3_600, confidence: 0.65,
            latitudeA: 52.0861, longitudeA: 4.8872, latitudeB: 48.1374, longitudeB: 11.5755)
        XCTAssertEqual(leg.directionsCacheKey, "52.0861,4.8872->48.1374,11.5755")
    }
}
