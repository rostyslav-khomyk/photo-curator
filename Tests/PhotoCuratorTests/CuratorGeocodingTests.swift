import XCTest
import SQLite3
@testable import PhotoCurator

private final class MockGeocodingProvider: GeocodingProvider, @unchecked Sendable {
    var lookupCount = 0
    let places: [String: ResolvedPlace]
    let fallback: ResolvedPlace?

    init(places: [String: ResolvedPlace] = [:],
         fallback: ResolvedPlace? = ResolvedPlace(locality: "Woerden", subLocality: "Woerden-West")) {
        self.places = places
        self.fallback = fallback
    }

    func reverseGeocode(latitude: Double, longitude: Double) async -> ResolvedPlace? {
        lookupCount += 1
        let key = String(format: "%.3f,%.3f", latitude, longitude)
        return places[key] ?? fallback
    }
}

final class CuratorGeocodingTests: XCTestCase {
    func testOptInCopiedOwnerJourneyEnrichment() async throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTO_CURATOR_JOURNEY_CATALOG"] else {
            throw XCTSkip("Set PHOTO_CURATOR_JOURNEY_CATALOG to an isolated Catalog v2 copy")
        }
        let store = try CatalogV2Store(url: URL(fileURLWithPath: path))
        for _ in 0..<64 {
            let result = try await store.enrichJourneyStops()
            if !result.hasMore { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        for story in try await store.storySummaries().filter({ $0.kind == .journey }) {
            print("\(story.start.formatted(.dateTime.year().month().day())) | \(story.title) | \(story.stops.count) stops")
        }
    }

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

    func testGeocodingCacheSurvivesServiceRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache.sqlite3")
        let firstProvider = MockGeocodingProvider(places: [
            "48.857,2.352": ResolvedPlace(locality: "Paris", country: "France")
        ])
        let first = CuratorGeocodingService(provider: firstProvider,
            cache: try DerivedCacheStore(url: url))
        let firstPlace = await first.place(for: 48.8566, longitude: 2.3522)
        XCTAssertEqual(firstPlace?.locality, "Paris")

        let secondProvider = MockGeocodingProvider()
        let second = CuratorGeocodingService(provider: secondProvider,
            cache: try DerivedCacheStore(url: url))
        let secondPlace = await second.place(for: 48.8566, longitude: 2.3522)
        XCTAssertEqual(secondPlace?.locality, "Paris")
        XCTAssertEqual(secondProvider.lookupCount, 0)
    }

    func testJourneyEnrichmentPersistsGroundedTitleAndStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog-v2.sqlite3")
        let store = try CatalogV2Store(url: url)
        let stop = JourneyStopEvidence(start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200), latitude: 48.8566, longitude: 2.3522,
            momentCount: 2, photoCount: 20, place: nil, confidence: 1)
        let unresolved = JourneyStopEvidence(start: stop.start, end: stop.end,
            latitude: 45.764, longitude: 4.8357, momentCount: 1, photoCount: 2,
            place: nil, confidence: 0.7)
        let alsoUnresolved = JourneyStopEvidence(start: stop.start, end: stop.end,
            latitude: 41.9028, longitude: 12.4964, momentCount: 1, photoCount: 2,
            place: nil, confidence: 0.7)
        let evidence = try JSONEncoder().encode([stop, unresolved, alsoUnresolved])
        var database: OpaquePointer?
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT INTO stories VALUES(?,?,?,?,?,?,?,?,?,?)", -1,
                                          &statement, nil), SQLITE_OK)
        sqlite3_bind_text(statement, 1, "journey", -1, transient)
        sqlite3_bind_text(statement, 2, "Journey from Home", -1, transient)
        sqlite3_bind_double(statement, 3, 100); sqlite3_bind_double(statement, 4, 200)
        sqlite3_bind_int64(statement, 5, 20); sqlite3_bind_int64(statement, 6, 2)
        sqlite3_bind_null(statement, 7); sqlite3_bind_int64(statement, 8, 2)
        sqlite3_bind_text(statement, 9, "journey", -1, transient)
        _ = evidence.withUnsafeBytes { sqlite3_bind_blob(statement, 10, $0.baseAddress, Int32(evidence.count), transient) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement); sqlite3_close(database)

        let provider = MockGeocodingProvider(places: [
            "48.857,2.352": ResolvedPlace(locality: "Paris", country: "France")
        ], fallback: nil)
        let geocoder = CuratorGeocodingService(provider: provider)
        let result = try await store.enrichJourneyStops(maximumLookups: 1, geocoder: geocoder)
        let second = try await store.enrichJourneyStops(maximumLookups: 1, geocoder: geocoder)
        let third = try await store.enrichJourneyStops(maximumLookups: 1, geocoder: geocoder)
        let stories = try await store.storySummaries()
        let story = try XCTUnwrap(stories.first)
        XCTAssertEqual(result.updated, 1)
        XCTAssertTrue(result.hasMore)
        XCTAssertTrue(second.hasMore)
        XCTAssertFalse(third.hasMore)
        XCTAssertEqual(provider.lookupCount, 3)
        XCTAssertEqual(story.title, "Journey to Paris")
        XCTAssertEqual(story.stops.first?.place, "Paris")
    }

    func testJourneyStopNamePrefersCityOverStreetLocality() {
        let street = ResolvedPlace(locality: "Avenue Carnot", administrativeArea: "Île-de-France",
                                   country: "France")
        XCTAssertEqual(street.journeyStopName, "Île-de-France")
        let city = ResolvedPlace(locality: "Paris", country: "France")
        XCTAssertEqual(city.journeyStopName, "Paris")
        XCTAssertTrue(PlaceNaming.looksStreetLevel("Parklaan 16"))
    }

    func testEnrichJourneyStopsUsesHomeGeofenceNotCityName() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogURL = root.appendingPathComponent("catalog.sqlite3")
        let store = try CatalogV2Store(url: catalogURL)
        let homeID = UUID().uuidString
        let evidence = try JSONEncoder().encode([
            JourneyStopEvidence(start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2),
                latitude: 52.086, longitude: 4.887, momentCount: 1, photoCount: 5,
                place: nil, confidence: 1)
        ])
        var database: OpaquePointer?
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        XCTAssertEqual(sqlite3_open(catalogURL.path, &database), SQLITE_OK)
        let home = MeaningfulPlace(id: UUID(uuidString: homeID) ?? UUID(), label: "Home",
            address: "Parklaan 16", latitude: 52.086, longitude: 4.887, radius: 400)
        let homePayload = try JSONEncoder().encode(home)
        var placeStatement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database,
            "INSERT INTO meaningful_places VALUES(?,?,?,?,?,?,?)", -1, &placeStatement, nil), SQLITE_OK)
        sqlite3_bind_text(placeStatement, 1, homeID, -1, transient)
        sqlite3_bind_text(placeStatement, 2, "Home", -1, transient)
        sqlite3_bind_text(placeStatement, 3, "Parklaan 16", -1, transient)
        sqlite3_bind_double(placeStatement, 4, 52.086)
        sqlite3_bind_double(placeStatement, 5, 4.887)
        sqlite3_bind_double(placeStatement, 6, 400)
        _ = homePayload.withUnsafeBytes {
            sqlite3_bind_blob(placeStatement, 7, $0.baseAddress, Int32(homePayload.count), transient)
        }
        XCTAssertEqual(sqlite3_step(placeStatement), SQLITE_DONE)
        sqlite3_finalize(placeStatement)

        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT INTO stories VALUES(?,?,?,?,?,?,?,?,?,?)", -1,
                                          &statement, nil), SQLITE_OK)
        sqlite3_bind_text(statement, 1, "j1", -1, transient)
        sqlite3_bind_text(statement, 2, "Journey from Home", -1, transient)
        sqlite3_bind_double(statement, 3, 1); sqlite3_bind_double(statement, 4, 2)
        sqlite3_bind_int64(statement, 5, 5); sqlite3_bind_int64(statement, 6, 0)
        sqlite3_bind_null(statement, 7); sqlite3_bind_int64(statement, 8, 1)
        sqlite3_bind_text(statement, 9, "journey", -1, transient)
        _ = evidence.withUnsafeBytes { sqlite3_bind_blob(statement, 10, $0.baseAddress, Int32(evidence.count), transient) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement); sqlite3_close(database)

        let provider = MockGeocodingProvider(places: [
            "52.086,4.887": ResolvedPlace(locality: "Parklaan 16", country: "Netherlands")
        ], fallback: nil)
        let geocoder = CuratorGeocodingService(provider: provider)
        let result = try await store.enrichJourneyStops(maximumLookups: 1, geocoder: geocoder)
        let stories = try await store.storySummaries()
        let story = try XCTUnwrap(stories.first)
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(story.stops.first?.place, "Home")
        XCTAssertEqual(story.title, "Journey from Home")
        // Lookup may still run for homeLocality of the configured Home place; the stop itself
        // must resolve via geofence to Home rather than the street-like provider locality.
        XCTAssertNotEqual(story.stops.first?.place, "Parklaan 16")
    }

    func testEnrichJourneyStopsReplacesStreetLevelPlaceWithCity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        let store = try CatalogV2Store(url: url)
        let stop = JourneyStopEvidence(start: Date(timeIntervalSince1970: 1),
            end: Date(timeIntervalSince1970: 2), latitude: 44.426, longitude: 26.102,
            momentCount: 2, photoCount: 8, place: "Strada Pușcariu Ion, 9", confidence: 1)
        let evidence = try JSONEncoder().encode([stop])
        var database: OpaquePointer?
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT INTO stories VALUES(?,?,?,?,?,?,?,?,?,?)", -1,
                                          &statement, nil), SQLITE_OK)
        sqlite3_bind_text(statement, 1, "bucharest", -1, transient)
        sqlite3_bind_text(statement, 2, "Journey from Home", -1, transient)
        sqlite3_bind_double(statement, 3, 1); sqlite3_bind_double(statement, 4, 2)
        sqlite3_bind_int64(statement, 5, 8); sqlite3_bind_int64(statement, 6, 0)
        sqlite3_bind_null(statement, 7); sqlite3_bind_int64(statement, 8, 1)
        sqlite3_bind_text(statement, 9, "journey", -1, transient)
        _ = evidence.withUnsafeBytes { sqlite3_bind_blob(statement, 10, $0.baseAddress, Int32(evidence.count), transient) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement); sqlite3_close(database)

        let provider = MockGeocodingProvider(places: [
            "44.426,26.102": ResolvedPlace(locality: "Bucharest", country: "Romania")
        ], fallback: nil)
        let result = try await store.enrichJourneyStops(maximumLookups: 1,
            geocoder: CuratorGeocodingService(provider: provider))
        let stories = try await store.storySummaries()
        let story = try XCTUnwrap(stories.first)
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(story.stops.first?.place, "Bucharest")
        XCTAssertEqual(story.title, "Journey to Bucharest")
        XCTAssertTrue(story.isFinalizedJourney)
    }

    func testInvalidCoordinateIsNotGeocoded() async {
        let mock = MockGeocodingProvider()
        let service = CuratorGeocodingService(provider: mock)
        let place = await service.place(for: 0, longitude: 0)
        XCTAssertNil(place)
        XCTAssertEqual(mock.lookupCount, 0)
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
        XCTAssertEqual(placeStatus, place.friendlyName)

        let titleWithPlace = MomentPresentation.title(moment, custom: nil, place: place)
        XCTAssertTrue(titleWithPlace.contains("Woerden"))
    }
}
