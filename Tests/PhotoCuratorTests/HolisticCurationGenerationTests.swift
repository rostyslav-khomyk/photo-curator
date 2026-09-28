import XCTest
import CoreLocation
@testable import PhotoCurator

final class HolisticCurationGenerationTests: XCTestCase {
    func testOptInCopiedOwnerStoryProjection() async throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTO_CURATOR_PHASE6_STORY_CATALOG"] else {
            throw XCTSkip("Set PHOTO_CURATOR_PHASE6_STORY_CATALOG to an isolated Catalog v2 copy")
        }
        let store = try CatalogV2Store(url: URL(fileURLWithPath: path))
        let started = Date()
        try await store.rebuildStories(calendar: calendar())
        let stories = try await store.storySummaries()
        print("Phase 6 owner Stories: \(stories.count) in \(String(format: "%.3f", Date().timeIntervalSince(started)))s")
        XCTAssertFalse(stories.isEmpty)
        XCTAssertTrue(stories.contains { Calendar.current.component(.year, from: $0.start) == 2026
            && Calendar.current.component(.month, from: $0.start) == 7
            && $0.momentIDs.count >= 20 && $0.photoCount >= 500 })
        XCTAssertTrue(stories.contains { Calendar.current.component(.year, from: $0.start) == 2022
            && Calendar.current.component(.month, from: $0.start) == 7
            && $0.momentIDs.count >= 60 && $0.photoCount >= 5_000 })
    }

    func testOptInCopiedOwnerCorpusCandidateGeneration() async throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTO_CURATOR_PHASE6_CATALOG"] else {
            throw XCTSkip("Set PHOTO_CURATOR_PHASE6_CATALOG to an isolated owner-catalog copy")
        }
        let root = URL(fileURLWithPath: path)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "local.icloudpd.photocurator"))
        let input = try CatalogV2Migrator.loadInput(root: root, defaults: defaults)
        let store = try CatalogV2Store(url: root.appendingPathComponent(CatalogV2Migrator.catalogName))
        _ = try await store.migrate(input)
        try await store.prepareWorkspace(input)
        let evaluationCalendar = calendar()
        let activeMetrics = HolisticLibraryMetrics.measure(input.moments, calendar: evaluationCalendar)
        _ = try await store.snapshotActiveGeneration(algorithmVersion: "shipping-v1",
            evidenceVersion: "owner-copy", metrics: activeMetrics, id: "owner-active-generation")

        let started = Date()
        let protectedIDs = Set(input.titles.keys).union(input.descriptions.keys)
            .union(input.protectedMembership.keys)
        let candidateMoments = HolisticCurationGenerator.refiningRoutineSingletons(input.moments,
            places: input.places, protectedMomentIDs: protectedIDs, calendar: evaluationCalendar)
        let candidateMetrics = HolisticLibraryMetrics.measure(candidateMoments, calendar: evaluationCalendar)
        let generation = try await store.beginCandidateGeneration(
            algorithmVersion: HolisticCurationGenerator.algorithmVersion,
            evidenceVersion: "owner-copy", id: "owner-candidate-generation")
        try await store.stageCandidateGeneration(id: generation.id, moments: candidateMoments,
            metrics: candidateMetrics)
        let elapsed = Date().timeIntervalSince(started)
        let stagedSummaries = try await store.candidateSummaries(generationID: generation.id)
        let comparison = CurationGenerationComparison.compare(active: activeMetrics, candidate: candidateMetrics)

        XCTAssertEqual(candidateMetrics.photoCount, activeMetrics.photoCount)
        XCTAssertEqual(stagedSummaries.count, candidateMetrics.momentCount)
        XCTAssertLessThan(candidateMetrics.singletonCount, activeMetrics.singletonCount)
        XCTAssertLessThanOrEqual(candidateMetrics.fragmentedDayCount, activeMetrics.fragmentedDayCount)
        XCTAssertEqual(candidateMetrics.highlightCount, activeMetrics.highlightCount)
        XCTAssertEqual(candidateMetrics.giantMomentCount, activeMetrics.giantMomentCount)
        XCTAssertTrue(comparison.structuralQualityPassed)
        XCTAssertFalse(comparison.canRecommendActivation)
        print("Phase 6 owner candidate: \(String(format: "%.3f", elapsed))s")
        print("Active: \(activeMetrics)")
        print("Candidate: \(candidateMetrics)")
    }

    func testAdaptiveCadenceKeepsBurstAndSplitsLongPause() {
        let photos = [photo("a", 0), photo("b", 300), photo("c", 600), photo("d", 7_800)]
        let candidates = HolisticCurationGenerator.candidates(photos, calendar: calendar())
        XCTAssertEqual(candidates.map { $0.members.map(\.id) }, [["a", "b", "c"], ["d"]])
        XCTAssertNotNil(candidates.last?.boundaryBefore)
    }

    func testRoutineSingletonsRollUpByHabitualPlaceMonthAndRole() {
        let home = MeaningfulPlace(label: "Home", address: "Home", latitude: 52, longitude: 4, radius: 200)
        let day: TimeInterval = 86_400
        let everyday = [locatedMoment("a", 0), locatedMoment("b", 5 * day)]
        let documentPhoto = photo("photo-c", 6 * day, latitude: 52.005, longitude: 4)
        let documentEvidence = PhotoDisplayEvidence(revision: documentPhoto.visualContentRevision,
            engine: PhotoDisplayEvidence.version, reason: .document)
        let document = PhotoMoment(id: "c", start: documentPhoto.created!, end: documentPhoto.created!,
            photos: [documentPhoto], displayEvidence: [documentPhoto.id: documentEvidence])
        let secondDocumentPhoto = photo("photo-d", 8 * day, latitude: 52.005, longitude: 4)
        let secondDocumentEvidence = PhotoDisplayEvidence(revision: secondDocumentPhoto.visualContentRevision,
            engine: PhotoDisplayEvidence.version, reason: .document)
        let secondDocument = PhotoMoment(id: "d", start: secondDocumentPhoto.created!,
            end: secondDocumentPhoto.created!, photos: [secondDocumentPhoto],
            displayEvidence: [secondDocumentPhoto.id: secondDocumentEvidence])

        let refined = HolisticCurationGenerator.refiningRoutineSingletons(
            everyday + [document, secondDocument], places: [home], calendar: calendar())

        XCTAssertEqual(refined.count, 2)
        XCTAssertEqual(Set(refined.map { $0.photos.count }), [2])
        XCTAssertTrue(refined.contains { $0.narrative?.headline.hasPrefix("Everyday life at Home") == true })
        XCTAssertTrue(refined.contains { $0.narrative?.headline.hasPrefix("Notes and records at Home") == true })
    }

    func testRoutineRefinementLeavesSignificantProtectedAndFavoriteMomentsAlone() {
        let home = MeaningfulPlace(label: "Home", address: "Home", latitude: 52, longitude: 4)
        let favorite = IndexedPhoto(id: "favorite", created: Date(timeIntervalSince1970: 0), modified: nil,
            latitude: 52, longitude: 4, favorite: true, width: 100, height: 100)
        let favoriteMoment = PhotoMoment(id: "favorite-moment", start: favorite.created!, end: favorite.created!,
            photos: [favorite])
        let protected = moment("protected", 86_400)
        let visitPhotos = (0..<200).map { photo("visit-\($0)", 2 * 86_400 + Double($0)) }
        let visit = PhotoMoment(id: "visit", start: visitPhotos.first!.created!, end: visitPhotos.last!.created!,
            photos: visitPhotos)

        let refined = HolisticCurationGenerator.refiningRoutineSingletons(
            [favoriteMoment, protected, visit], places: [home], protectedMomentIDs: [protected.id],
            calendar: calendar())

        XCTAssertEqual(Set(refined.map(\.id)), [favoriteMoment.id, protected.id, visit.id])
        XCTAssertEqual(refined.first(where: { $0.id == visit.id })?.photos.count, 200)
    }

    func testStrongRecordedLocationConflictSplitsWithoutInventingMissingGPS() {
        let near = [photo("a", 0, latitude: 52, longitude: 4),
                    photo("b", 60, latitude: 52.0001, longitude: 4.0001)]
        XCTAssertEqual(HolisticCurationGenerator.candidates(near, calendar: calendar()).count, 1)
        let far = near + [photo("c", 120, latitude: 51, longitude: 5)]
        XCTAssertEqual(HolisticCurationGenerator.candidates(far, calendar: calendar()).count, 2)
        let unknown = [photo("a", 0), photo("b", 60)]
        XCTAssertEqual(HolisticCurationGenerator.candidates(unknown, calendar: calendar()).count, 1)
    }

    func testLogicalDaysRespectCalendarTimeZone() {
        var utc = calendar(); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var west = calendar(); west.timeZone = TimeZone(secondsFromGMT: -2 * 3600)!
        let photos = [photo("a", 23 * 3600 + 50 * 60), photo("b", 24 * 3600 + 10 * 60)]
        XCTAssertEqual(HolisticCurationGenerator.candidates(photos, calendar: utc).count, 2)
        XCTAssertEqual(HolisticCurationGenerator.candidates(photos, calendar: west).count, 1)
    }

    func testGenerationAndMetricsAreDeterministicAndExposeDensityProblems() {
        let photos = (0..<5).map { photo("p\($0)", Double($0 * 4 * 3600)) }
        let forward = HolisticCurationGenerator.moments(photos, calendar: calendar())
        let reversed = HolisticCurationGenerator.moments(photos.reversed(), calendar: calendar())
        XCTAssertEqual(forward.map(\.id), reversed.map(\.id))
        let metrics = HolisticLibraryMetrics.measure(forward, calendar: calendar())
        XCTAssertEqual(metrics.photoCount, 5)
        XCTAssertEqual(metrics.momentCount, 5)
        XCTAssertEqual(metrics.singletonCount, 5)
        XCTAssertEqual(metrics.smallMomentCount, 5)
        XCTAssertEqual(metrics.fragmentedDayCount, 1)
        XCTAssertEqual(metrics.genericTitleCount, 5)
    }

    func testComparisonWeightsFalseJoinsAndRequiresCompleteCoverageAndBenchmark() {
        let active = metrics(photos: 100, moments: 10, joins: 2, splits: 0)
        let better = metrics(photos: 100, moments: 12, joins: 0, splits: 3)
        let comparison = CurationGenerationComparison.compare(active: active, candidate: better)
        XCTAssertEqual(comparison.activeBenchmarkCost, 6)
        XCTAssertEqual(comparison.candidateBenchmarkCost, 3)
        XCTAssertTrue(comparison.canRecommendActivation)
        XCTAssertFalse(CurationGenerationComparison.compare(active: active,
            candidate: metrics(photos: 99, moments: 12, joins: 0, splits: 0)).canRecommendActivation)
        XCTAssertFalse(CurationGenerationComparison.compare(active: active,
            candidate: metrics(photos: 100, moments: 12, joins: nil, splits: nil)).canRecommendActivation)
        let fragmented = metrics(photos: 100, moments: 12, joins: 0, splits: 0,
            fragmentedDays: 1)
        let structuralRegression = CurationGenerationComparison.compare(active: active, candidate: fragmented)
        XCTAssertFalse(structuralRegression.structuralQualityPassed)
        XCTAssertFalse(structuralRegression.canRecommendActivation)

        let significantVisit = CurationGenerationMetrics(photoCount: 100, momentCount: 8, highlightCount: 0,
            singletonCount: 0, smallMomentCount: 0, largeMomentCount: 1, giantMomentCount: 1,
            fragmentedDayCount: 0, crossDayMomentCount: 0, genericTitleCount: 0,
            falseJoinCount: 0, falseSplitCount: 0)
        let largeButCoherent = CurationGenerationComparison.compare(active: active, candidate: significantVisit)
        XCTAssertTrue(largeButCoherent.structuralQualityPassed)
        XCTAssertTrue(largeButCoherent.canRecommendActivation)
    }

    func testOverviewReportsSeasonalityWithoutChangingCandidates() {
        let january = PhotoMoment(id: "jan", start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 60), photos: [photo("a", 0), photo("b", 60)])
        let julyDate = Date(timeIntervalSince1970: 181 * 86_400)
        let july = PhotoMoment(id: "jul", start: julyDate, end: julyDate,
            photos: [IndexedPhoto(id: "c", created: julyDate, modified: nil, latitude: nil,
                longitude: nil, favorite: false, width: 100, height: 100)])
        let periods = HolisticLibraryOverview.periods([january, july], calendar: calendar())
        XCTAssertEqual(periods.map(\.photoCount), [2, 1])
        XCTAssertEqual(periods.map(\.momentCount), [1, 1])
    }

    func testCrossDayRoutineMomentIsNotCountedAsSameDayFragmentation() {
        let photos = (0..<5).map { photo("p\($0)", Double($0 * 60)) }
        let sameDay = photos.map { item in
            PhotoMoment(id: item.id, start: item.created!, end: item.created!, photos: [item])
        }
        XCTAssertEqual(HolisticLibraryMetrics.measure(sameDay, calendar: calendar()).fragmentedDayCount, 1)
        let rollup = PhotoMoment(id: "routine", start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 2 * 86_400), photos: photos)
        let metrics = HolisticLibraryMetrics.measure([rollup], calendar: calendar())
        XCTAssertEqual(metrics.fragmentedDayCount, 0)
        XCTAssertEqual(metrics.crossDayMomentCount, 1)
    }

    func testProtectedAnchorKeepsIdentityAcrossBoundaryChange() throws {
        let photos = [photo("a", 0), photo("b", 60), photo("c", 20_000)]
        let previous = [MomentIdentityEntry(id: "reviewed", members: Set(photos.map(\.id)))]
        var ids = ["new"]
        let moments = try HolisticCurationGenerator.reconciledMoments(photos, previous: previous,
            anchors: ["reviewed": ["a", "b"]], calendar: calendar()) { ids.removeFirst() }
        XCTAssertEqual(moments.map(\.id), ["new", "reviewed"])
        XCTAssertEqual(moments.last?.photos.map(\.id), ["a", "b"])
    }

    func testAmbiguousProtectedSplitFailsClosed() {
        let photos = [photo("a", 0), photo("b", 20_000)]
        let previous = [MomentIdentityEntry(id: "reviewed", members: Set(photos.map(\.id)))]
        XCTAssertThrowsError(try HolisticCurationGenerator.reconciledMoments(photos, previous: previous,
            anchors: ["reviewed": ["a", "b"]], calendar: calendar()))
    }

    func testStoryKeepsExcursionInsideRepeatedTripBase() {
        let moments = [
            moment("a", 0), moment("b", 25 * 3600), moment("c", 26 * 3600),
            moment("d", 27 * 3600), moment("e", 28 * 3600)
        ]
        let places: [String: String?] = ["a": "trip", "b": "trip", "c": nil,
                                           "d": "trip", "e": "trip"]
        let stories = ConservativeStoryBuilder.stories(moments, calendar: calendar()) { places[$0.id] ?? nil }
        XCTAssertEqual(stories.map(\.momentIDs), [["a", "b", "c", "d", "e"]])
    }

    func testTripIncludesArrivalAndDepartureShoulders() {
        let moments = [moment("arrival", 2 * 3600), moment("base-1", 25 * 3600),
                       moment("base-2", 50 * 3600), moment("departure", 70 * 3600)]
        let stories = ConservativeStoryBuilder.stories(moments, calendar: calendar()) {
            $0.id.hasPrefix("base") ? "Fréjus" : nil
        }
        XCTAssertEqual(stories.first?.momentIDs, ["arrival", "base-1", "base-2", "departure"])
    }

    func testSameDayPlaceContinuationBecomesStory() {
        let moments = [moment("morning", 9 * 3600), moment("evening", 16 * 3600)]
        let stories = ConservativeStoryBuilder.stories(moments, calendar: calendar()) { _ in "Efteling" }
        XCTAssertEqual(stories.map(\.momentIDs), [["morning", "evening"]])
    }

    func testSameCityDistrictsBecomeOneStory() {
        let moments = [moment("nieuwmarkt", 9 * 3600), moment("burgwallen", 16 * 3600)]
        let places = ["nieuwmarkt": "Nieuwmarkt / Lastage, Amsterdam",
                      "burgwallen": "Burgwallen-Nieuwe Zijde, Amsterdam"]
        let stories = ConservativeStoryBuilder.stories(moments, calendar: calendar()) { places[$0.id] }
        XCTAssertEqual(stories.first?.placeID, "Amsterdam")
        XCTAssertEqual(stories.first?.momentIDs, ["nieuwmarkt", "burgwallen"])
    }

    func testJourneyStoryUsesClosedHomeToHomeRouteAndKeepsStopsOrdered() {
        let home = MeaningfulPlace(label: "Home", address: "Home", latitude: 52.1, longitude: 4.9,
                                   radius: 1_000)
        let moments = [moment("home-before", 0), moment("salzburg", 86_400),
                       moment("verona", 2 * 86_400), moment("rome", 5 * 86_400),
                       moment("home-after", 8 * 86_400)]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home-before": .init(latitude: 52.1, longitude: 4.9),
            "salzburg": .init(latitude: 47.8, longitude: 13.0),
            "verona": .init(latitude: 45.4, longitude: 11.0),
            "rome": .init(latitude: 41.9, longitude: 12.5),
            "home-after": .init(latitude: 52.1, longitude: 4.9),
        ]
        let places = ["salzburg": "Salzburg", "verona": "Verona", "rome": "Rome"]
        let stories = JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] })

        XCTAssertEqual(stories.count, 1)
        XCTAssertEqual(stories[0].momentIDs, ["salzburg", "verona", "rome"])
        XCTAssertEqual(stories[0].placeID, "Journey via Salzburg, Verona, and Rome")
        let district = JourneyStopEvidence(start: moments[0].start, end: moments[0].end,
            latitude: 44.4, longitude: 26.1, momentCount: 1, photoCount: 4,
            place: "Sector 4, Bucharest", confidence: 1)
        let city = JourneyStopEvidence(start: moments[0].start, end: moments[0].end,
            latitude: 44.5, longitude: 26.0, momentCount: 1, photoCount: 2,
            place: "Bucharest", confidence: 1)
        let homeStop = JourneyStopEvidence(start: moments[0].start, end: moments[0].end,
            latitude: 52.1, longitude: 4.9, momentCount: 1, photoCount: 10,
            place: "Home", confidence: 1)
        XCTAssertEqual(JourneyStoryBuilder.title(homeLabel: "Home", stops: [homeStop, district, city]),
                       "Journey to Bucharest")
    }

    func testJourneyTitleRejectsStreetLevelStopLabels() {
        let street = JourneyStopEvidence(start: Date(), end: Date(), latitude: 48.8, longitude: 2.3,
            momentCount: 1, photoCount: 40, place: "Avenue Carnot", confidence: 1)
        let city = JourneyStopEvidence(start: Date(), end: Date(), latitude: 48.9, longitude: 2.4,
            momentCount: 1, photoCount: 20, place: "Paris", confidence: 1)
        XCTAssertEqual(JourneyStoryBuilder.title(homeLabel: "Home", stops: [street]),
                       "Journey from Home")
        XCTAssertEqual(JourneyStoryBuilder.title(homeLabel: "Home", stops: [street, city]),
                       "Journey to Paris")
        XCTAssertTrue(PlaceNaming.looksStreetLevel("Parklaan 16"))
        XCTAssertFalse(PlaceNaming.looksStreetLevel("Rotterdam"))
    }

    func testJourneyTitleIgnoresThinSecondaryHomeWaypoint() {
        // Bucharest round-trip with a 1-photo "Home in Ukraine" ping must not title as
        // Journey to Home in Ukraine (street labels wait for city geocode).
        let transit = JourneyStopEvidence(start: Date(), end: Date(), latitude: 45.45, longitude: 22.83,
            momentCount: 1, photoCount: 1, place: "337415", confidence: 0.6)
        let bucharestStreet = JourneyStopEvidence(start: Date(), end: Date(), latitude: 44.41, longitude: 26.10,
            momentCount: 2, photoCount: 5, place: "Strada Pușcariu Ion, 9", confidence: 1)
        let ukraineHome = JourneyStopEvidence(start: Date(), end: Date(), latitude: 49.80, longitude: 24.02,
            momentCount: 1, photoCount: 1, place: "Home in Ukraine", confidence: 0.6)
        let bucharestReturn = JourneyStopEvidence(start: Date(), end: Date(), latitude: 44.42, longitude: 26.10,
            momentCount: 4, photoCount: 8, place: "Strada Pușcariu Ion, 7", confidence: 1)
        XCTAssertEqual(
            JourneyStoryBuilder.title(homeLabel: "Home",
                                      stops: [transit, bucharestStreet, ukraineHome, bucharestReturn]),
            "Journey from Home")
        let bucharestCity = JourneyStopEvidence(start: Date(), end: Date(), latitude: 44.42, longitude: 26.10,
            momentCount: 4, photoCount: 8, place: "Bucharest", confidence: 1)
        XCTAssertEqual(
            JourneyStoryBuilder.title(homeLabel: "Home",
                                      stops: [transit, bucharestCity, ukraineHome]),
            "Journey to Bucharest")
        XCTAssertTrue(JourneyStoryBuilder.isSecondaryHomeLabel("Home in Ukraine", primaryHome: "Home"))
    }

    func testLocalTransportSupportRequiresAgreementAndCannotChangeMode() throws {
        let air = JourneyLegEvidence(mode: .air, distanceMeters: 600_000, elapsedSeconds: 7200, confidence: 0.8)
        var support = JourneyLocalTransportSupport()
        support.inspect(labels: ["airplane"], lines: [.init(text: "Boarding pass", confidence: 0.3)])
        support.inspect(labels: ["flower"], lines: [.init(text: "Boarding pass", confidence: 1)])
        XCTAssertEqual(support.airPhotos, 0)
        support.inspect(labels: ["airplane"], lines: [.init(text: "Boarding pass", confidence: 1)])
        XCTAssertEqual(support.applying(to: air).confidence, 0.8)
        support.inspect(labels: ["airport"], lines: [.init(text: "Boarding gate", confidence: 0.9)])
        let enriched = support.applying(to: air)
        XCTAssertEqual(enriched.confidence, 0.9, accuracy: 0.001)
        XCTAssertEqual(support.applying(to: enriched), enriched)
        let unknown = JourneyLegEvidence(mode: .unknown, distanceMeters: 600_000, elapsedSeconds: 30, confidence: 0.25)
        XCTAssertEqual(support.applying(to: unknown).mode, .unknown)
        XCTAssertEqual(support.applying(to: unknown).confidence, 0.25)
        support.inspect(labels: ["train"], lines: [.init(text: "Train ticket", confidence: 1)])
        XCTAssertEqual(support.applying(to: air).confidence, 0.8)
        let legacy = Data("{\"mode\":\"air\",\"distanceMeters\":600000,\"elapsedSeconds\":7200,\"confidence\":0.8}".utf8)
        XCTAssertNil(try JSONDecoder().decode(JourneyLegEvidence.self, from: legacy).localSupport)
    }

    func testJourneyTransportInferenceIsConservativeAndLegacyEvidenceStillDecodes() throws {
        let base = Date(timeIntervalSince1970: 1_000)
        let stops = [
            JourneyStopEvidence(start: base, end: base, latitude: 52.37, longitude: 4.90,
                momentCount: 1, photoCount: 3, place: "Amsterdam", confidence: 1),
            JourneyStopEvidence(start: base.addingTimeInterval(2 * 3600),
                end: base.addingTimeInterval(2 * 3600), latitude: 48.14, longitude: 11.58,
                momentCount: 1, photoCount: 4, place: "Munich", confidence: 1),
            JourneyStopEvidence(start: base.addingTimeInterval(8 * 3600),
                end: base.addingTimeInterval(8 * 3600), latitude: 45.44, longitude: 12.32,
                momentCount: 1, photoCount: 5, place: "Venice", confidence: 1),
            JourneyStopEvidence(start: base.addingTimeInterval(8 * 3600 + 5 * 60),
                end: base.addingTimeInterval(8 * 3600 + 5 * 60), latitude: 40.71, longitude: -74.01,
                momentCount: 1, photoCount: 2, place: "New York", confidence: 1),
        ]
        let inferred = JourneyTransportInference.applying(to: stops)
        XCTAssertNil(inferred[0].transportFromPrevious)
        XCTAssertEqual(inferred[1].transportFromPrevious?.mode, .air)
        XCTAssertEqual(inferred[2].transportFromPrevious?.mode, .overland)
        XCTAssertEqual(inferred[3].transportFromPrevious?.mode, .unknown)

        let legacy = try JSONEncoder().encode(stops)
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("transportFromPrevious"))
        XCTAssertNoThrow(try JSONDecoder().decode([JourneyStopEvidence].self, from: legacy))
    }

    func testJourneyStoryRejectsRoutineLocalMovementAndOpenTrips() {
        let home = MeaningfulPlace(label: "Home", address: "Home", latitude: 52.1, longitude: 4.9,
                                   radius: 1_000)
        let moments = [moment("home", 0), moment("local", 2 * 86_400), moment("far-open", 4 * 86_400)]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home": .init(latitude: 52.1, longitude: 4.9),
            "local": .init(latitude: 52.11, longitude: 4.9),
            "far-open": .init(latitude: 48.8, longitude: 2.3),
        ]
        XCTAssertTrue(JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] }, placeID: { _ in nil }).isEmpty)
    }

    func testHomePhotoFromAnotherPhoneDoesNotSplitJourney() {
        let home = MeaningfulPlace(label: "Home", address: "Home", latitude: 52.1, longitude: 4.9,
                                   radius: 1_000)
        let moments = [moment("home-before", 0), moment("france-1", 86_400),
                       moment("family-at-home", 3 * 86_400), moment("france-2", 3 * 86_400 + 3600),
                       moment("home-after", 6 * 86_400)]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home-before": .init(latitude: 52.1, longitude: 4.9),
            "france-1": .init(latitude: 43.4, longitude: 6.7),
            "family-at-home": .init(latitude: 52.1, longitude: 4.9),
            "france-2": .init(latitude: 43.5, longitude: 6.8),
            "home-after": .init(latitude: 52.1, longitude: 4.9),
        ]
        let stories = JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] }, placeID: { _ in nil })
        XCTAssertEqual(stories.first?.momentIDs, ["france-1", "france-2"])
    }

    func testInvalidZeroCoordinateCannotCreateJourneyEvidence() {
        let home = MeaningfulPlace(label: "Home", address: "Home", latitude: 52.1, longitude: 4.9,
                                   radius: 1_000)
        let moments = [moment("home-before", 0), moment("zero-1", 86_400),
                       moment("zero-2", 2 * 86_400), moment("home-after", 4 * 86_400)]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home-before": .init(latitude: 52.1, longitude: 4.9),
            "home-after": .init(latitude: 52.1, longitude: 4.9),
        ]
        XCTAssertTrue(JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] }, placeID: { _ in nil }).isEmpty)
        XCTAssertFalse(RecordedCoordinate.isValid(latitude: 0, longitude: 0))
    }

    func testWeakOverlappingFamilyPhoneBranchDoesNotSteerJourneyTitle() {
        let home = MeaningfulPlace(label: "Home", address: "Home", latitude: 52.1, longitude: 4.9,
                                   radius: 1_000)
        let moments = [moment("home-before", 0), moment("france-1", 86_400),
                       moment("remote-family", 86_400 + 1800), moment("france-2", 3 * 86_400),
                       moment("home-after", 5 * 86_400)]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home-before": .init(latitude: 52.1, longitude: 4.9),
            "france-1": .init(latitude: 43.4, longitude: 6.7),
            "remote-family": .init(latitude: 49.8, longitude: 24.0),
            "france-2": .init(latitude: 43.5, longitude: 6.8),
            "home-after": .init(latitude: 52.1, longitude: 4.9),
        ]
        let support = ["france-1": 20, "remote-family": 1, "france-2": 15]
        let places = ["france-1": "Fréjus", "remote-family": "Lviv", "france-2": "Fréjus"]
        let story = JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: { support[$0.id] ?? 1 }).first

        XCTAssertEqual(story?.placeID, "Journey to Fréjus")
        XCTAssertEqual(story?.momentIDs, ["france-1", "remote-family", "france-2"])
        XCTAssertEqual(story?.kind, .journey)
        XCTAssertEqual(story?.stops.count, 1)
    }

    func testRoutineHomeCapturesDoNotBecomeStory() {
        let moments = [moment("a", 0), moment("b", 25 * 3600), moment("c", 48 * 3600)]
        XCTAssertTrue(ConservativeStoryBuilder.stories(moments, calendar: calendar()) { _ in "Home" }.isEmpty)
    }

    func testFrequentlyVisitedPlaceIsInferredAsRoutine() {
        let moments = (0..<15).map { moment("routine-\($0)", Double($0) * 86_400) }
        XCTAssertTrue(ConservativeStoryBuilder.stories(moments, calendar: calendar()) { _ in "Local school" }.isEmpty)
    }

    func testHierarchicalHighlightsRepresentMomentsWithoutFavorites() {
        let candidates = [
            HierarchicalHighlightCandidate(id: "a1", momentID: "a", quality: 0.7, protected: false, roles: ["portrait"]),
            .init(id: "a2", momentID: "a", quality: 0.6, protected: false, roles: ["scene"]),
            .init(id: "b1", momentID: "b", quality: 0.5, protected: false, roles: ["detail"]),
            .init(id: "b2", momentID: "b", quality: 0.4, protected: false, roles: ["scene"])
        ]
        let result = HierarchicalHighlightAllocator.allocate(candidates) { lhs, rhs in lhs == rhs ? 1 : 0 }
        XCTAssertFalse(result.byMoment["a", default: []].isEmpty)
        XCTAssertFalse(result.byMoment["b", default: []].isEmpty)
        XCTAssertTrue(result.storyHighlights.contains { $0.hasPrefix("a") })
        XCTAssertTrue(result.storyHighlights.contains { $0.hasPrefix("b") })
    }

    private func calendar() -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func photo(_ id: String, _ time: TimeInterval,
                       latitude: Double? = nil, longitude: Double? = nil) -> IndexedPhoto {
        IndexedPhoto(id: id, created: Date(timeIntervalSince1970: time), modified: nil,
            latitude: latitude, longitude: longitude, favorite: false, width: 100, height: 100)
    }

    private func moment(_ id: String, _ time: TimeInterval) -> PhotoMoment {
        let item = photo("photo-\(id)", time)
        return PhotoMoment(id: id, start: item.created!, end: item.created!, photos: [item])
    }

    private func locatedMoment(_ id: String, _ time: TimeInterval) -> PhotoMoment {
        let item = photo("photo-\(id)", time, latitude: 52, longitude: 4)
        return PhotoMoment(id: id, start: item.created!, end: item.created!, photos: [item])
    }


    private func metrics(photos: Int, moments: Int, joins: Int?, splits: Int?,
                         fragmentedDays: Int = 0) -> CurationGenerationMetrics {
        CurationGenerationMetrics(photoCount: photos, momentCount: moments, highlightCount: 0,
            singletonCount: 0, smallMomentCount: 0, largeMomentCount: 0, giantMomentCount: 0,
            fragmentedDayCount: fragmentedDays, crossDayMomentCount: 0, genericTitleCount: 0,
            falseJoinCount: joins, falseSplitCount: splits)
    }
}
