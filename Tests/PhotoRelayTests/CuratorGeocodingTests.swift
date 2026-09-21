import XCTest
@testable import PhotoRelay

private final class MockGeocodingProvider: GeocodingProvider, @unchecked Sendable {
    var lookupCount = 0
    let places: [String: ResolvedPlace]

    init(places: [String: ResolvedPlace] = [:]) {
        self.places = places
    }

    func reverseGeocode(latitude: Double, longitude: Double) async -> ResolvedPlace? {
        lookupCount += 1
        let key = String(format: "%.3f,%.3f", latitude, longitude)
        return places[key] ?? ResolvedPlace(locality: "Woerden", subLocality: "Woerden-West")
    }
}

final class CuratorGeocodingTests: XCTestCase {
    func testMeaningfulPlaceRadiusAndFriendlyNamePrecedence() async {
        let home = MeaningfulPlace(label: "Home", address: "Test Street", latitude: 52.086, longitude: 4.887, radius: 250)
        XCTAssertTrue(home.contains(latitude: 52.0865, longitude: 4.887))
        XCTAssertFalse(home.contains(latitude: 52.09, longitude: 4.887))

        let provider = MockGeocodingProvider(places: [
            "52.086,4.887": ResolvedPlace(locality: "Woerden", subLocality: "Woerden-West", venueName: "Nearby Shop")
        ])
        let service = CuratorGeocodingService(provider: provider, meaningfulPlaces: { [home] })
        let resolved = await service.place(for: 52.086, longitude: 4.887)

        XCTAssertEqual(resolved?.friendlyName, "Home")
        XCTAssertEqual(resolved?.meaningfulLabel, "Home")
        XCTAssertEqual(resolved?.venueName, "Nearby Shop")
        XCTAssertEqual(resolved?.address, "Test Street")
    }

    func testMeaningfulPlaceUsesNaturalCaptionGrammar() {
        let photo = makePhoto(id: "home", time: 1_756_550_000, lat: 52.086, lon: 4.887)
        let moment = PhotoMoment(id: "home", start: photo.created!, end: photo.created!, photos: [photo])
        let place = ResolvedPlace(locality: "Woerden", meaningfulLabel: "Home")
        XCTAssertTrue(MomentPresentation.title(moment, custom: nil, place: place).hasSuffix("at home"))
    }

    @MainActor
    func testMeaningfulPlaceStorePersistsInAndDeleting() {
        let name = "MeaningfulPlacesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MeaningfulPlacesStore(defaults: defaults)
        store.save(MeaningfulPlace(label: "Studio", address: "Canal 1", latitude: 1, longitude: 2))
        XCTAssertEqual(MeaningfulPlacesStore.snapshot(defaults: defaults).map(\.label), ["Studio"])
        let place = store.places[0]
        store.save(MeaningfulPlace(id: place.id, label: "Office", address: "Canal 2", latitude: 3, longitude: 4))
        XCTAssertEqual(MeaningfulPlacesStore.snapshot(defaults: defaults).map(\.label), ["Office"])
        store.remove(place)
        XCTAssertTrue(MeaningfulPlacesStore.snapshot(defaults: defaults).isEmpty)
    }

    private func makePhoto(id: String, time: Double = 1756500000, lat: Double? = nil, lon: Double? = nil) -> IndexedPhoto {
        IndexedPhoto(
            id: id,
            created: Date(timeIntervalSince1970: time),
            modified: nil,
            latitude: lat,
            longitude: lon,
            favorite: false,
            width: 100,
            height: 100
        )
    }

    func testGeocodingCacheAndMedianResolution() async {
        let mock = MockGeocodingProvider()
        let service = CuratorGeocodingService(provider: mock)

        // First lookup
        let place1 = await service.place(for: 52.086, longitude: 4.887)
        XCTAssertEqual(place1?.locality, "Woerden")
        XCTAssertEqual(place1?.friendlyName, "Woerden-West, Woerden")

        // Second lookup nearby (~10m away, same 3 decimal places) -> Cache hit
        let place2 = await service.place(for: 52.0861, longitude: 4.8872)
        XCTAssertEqual(place2?.locality, "Woerden")
        let count = mock.lookupCount
        XCTAssertEqual(count, 1, "Nearby query should hit cache without calling provider")

        // Moment median resolution
        let baseTime = 1756500000.0
        let p1 = makePhoto(id: "p1", time: baseTime, lat: 52.080, lon: 4.880)
        let p2 = makePhoto(id: "p2", time: baseTime + 60, lat: 52.086, lon: 4.887)
        let p3 = makePhoto(id: "p3", time: baseTime + 120, lat: 52.090, lon: 4.890)
        let moment = PhotoMoment(id: "m1", start: p1.created!, end: p3.created!, photos: [p1, p2, p3])

        let momentPlace = await service.place(for: moment)
        XCTAssertEqual(momentPlace?.locality, "Woerden")
    }

    func testSameDayTimestampExtrapolationNearAnchor() {
        let calendar = Calendar.current
        let baseTime = 1756550000.0 // midday

        let gpsPhoto = makePhoto(id: "gps1", time: baseTime, lat: 52.086, lon: 4.887)
        let nonGpsPhoto = makePhoto(id: "nogps1", time: baseTime + (25 * 60)) // 25 min later

        let moment = PhotoMoment(id: "m_nogps", start: nonGpsPhoto.created!, end: nonGpsPhoto.created!, photos: [nonGpsPhoto])

        let extrapolated = CuratorLocationExtrapolator.extrapolate(
            target: nonGpsPhoto,
            in: moment,
            allDayPhotos: [gpsPhoto, nonGpsPhoto],
            calendar: calendar
        )

        XCTAssertNotNil(extrapolated)
        XCTAssertEqual(extrapolated?.latitude, 52.086)
        XCTAssertEqual(extrapolated?.longitude, 4.887)
        XCTAssertGreaterThanOrEqual(extrapolated?.confidence ?? 0, 0.70)
    }

    func testSandwichBracketingExtrapolation() {
        let calendar = Calendar.current
        let baseTime = 1756550000.0

        // Photo before at 1:00 PM in Woerden
        let before = makePhoto(id: "b", time: baseTime, lat: 52.086, lon: 4.887)
        // Photo in middle at 2:00 PM without GPS
        let middle = makePhoto(id: "m", time: baseTime + 3600)
        // Photo after at 3:00 PM in Woerden (same area, ~200m away)
        let after = makePhoto(id: "a", time: baseTime + 7200, lat: 52.087, lon: 4.888)

        let moment = PhotoMoment(id: "m_mid", start: middle.created!, end: middle.created!, photos: [middle])

        let extrapolated = CuratorLocationExtrapolator.extrapolate(
            target: middle,
            in: moment,
            allDayPhotos: [before, middle, after],
            calendar: calendar
        )

        XCTAssertNotNil(extrapolated)
        XCTAssertGreaterThanOrEqual(extrapolated?.confidence ?? 0, 0.70)
    }

    func testDistantConflictingCitiesRejectsExtrapolation() {
        let calendar = Calendar.current
        let baseTime = 1756550000.0

        // Photo before in Rotterdam (51.924, 4.477)
        let before = makePhoto(id: "b", time: baseTime, lat: 51.924, lon: 4.477)
        // Photo in transit
        let middle = makePhoto(id: "m", time: baseTime + 3600)
        // Photo after in Amsterdam (52.367, 4.904, ~55km away)
        let after = makePhoto(id: "a", time: baseTime + 7200, lat: 52.367, lon: 4.904)

        let moment = PhotoMoment(id: "m_transit", start: middle.created!, end: middle.created!, photos: [middle])

        let extrapolated = CuratorLocationExtrapolator.extrapolate(
            target: middle,
            in: moment,
            allDayPhotos: [before, middle, after],
            calendar: calendar
        )

        XCTAssertNil(extrapolated, "Should reject extrapolation when bracketed by conflicting distant cities")
    }

    func testTimeGapOverFourHoursRejectsExtrapolation() {
        let calendar = Calendar.current
        let baseTime = 1756550000.0

        let gpsPhoto = makePhoto(id: "morning", time: baseTime, lat: 52.086, lon: 4.887)
        // Photo 6 hours later without GPS
        let evening = makePhoto(id: "evening", time: baseTime + (6 * 3600))

        let moment = PhotoMoment(id: "m_eve", start: evening.created!, end: evening.created!, photos: [evening])

        let extrapolated = CuratorLocationExtrapolator.extrapolate(
            target: evening,
            in: moment,
            allDayPhotos: [gpsPhoto, evening],
            calendar: calendar
        )

        XCTAssertNil(extrapolated, "Should not extrapolate when time gap exceeds threshold without corroborating bracket")
    }

    func testPresentationEliminatesPlaceNotVerified() {
        let baseTime = 1756550000.0
        let p = makePhoto(id: "p1", time: baseTime)
        var moment = PhotoMoment(id: "m1", start: p.created!, end: p.created!, photos: [p])
        moment.groupingState = MomentGroupingState.conservative

        let status = MomentPresentation.status(moment, pending: false, userAuthored: false)
        XCTAssertFalse(status.contains("place not verified"))
        XCTAssertFalse(status.contains("unverified"))

        let place = ResolvedPlace(locality: "Woerden", subLocality: "Woerden-West")
        let placeStatus = MomentPresentation.status(moment, pending: false, userAuthored: false, place: place)
        XCTAssertEqual(placeStatus, "Title preparation is in progress…")

        let titleWithPlace = MomentPresentation.title(moment, custom: nil, place: place)
        XCTAssertTrue(titleWithPlace.contains("Woerden"))
    }
}
