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
        XCTAssertEqual(stories[0].placeID, "Journey to Italy and Austria in 1970")
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
        // Same-city street labels without a city name stay unresolved until geocode.
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

    func testJourneyTitlePrefersCountrySeasonAndYearOverATownList() {
        let start = Date(timeIntervalSince1970: 1_751_328_000) // 2025-07-01
        let paris = JourneyStopEvidence(start: start, end: start.addingTimeInterval(2 * 86_400),
            latitude: 48.86, longitude: 2.35, momentCount: 2, photoCount: 40,
            place: "Paris", confidence: 1)
        let lyon = JourneyStopEvidence(start: start.addingTimeInterval(3 * 86_400),
            end: start.addingTimeInterval(8 * 86_400),
            latitude: 45.76, longitude: 4.84, momentCount: 3, photoCount: 30,
            place: "Lyon", confidence: 1)
        XCTAssertEqual(JourneyStoryBuilder.title(homeLabel: "Home", stops: [paris, lyon]),
                       "Summer holidays in France")
        // Landmark / border labels must not force the old city list when coordinates are clear.
        let park = JourneyStopEvidence(start: start, end: start.addingTimeInterval(86_400),
            latitude: 41.41, longitude: 2.15, momentCount: 2, photoCount: 40,
            place: "Park Güell", confidence: 1)
        let beach = JourneyStopEvidence(start: start.addingTimeInterval(2 * 86_400),
            end: start.addingTimeInterval(4 * 86_400),
            latitude: 41.26, longitude: 2.0, momentCount: 2, photoCount: 20,
            place: "Platja de Gavà", confidence: 1)
        let border = JourneyStopEvidence(start: start.addingTimeInterval(5 * 86_400),
            end: start.addingTimeInterval(7 * 86_400),
            latitude: 42.40, longitude: 2.53, momentCount: 1, photoCount: 8,
            place: "Prats-de-Mollo", confidence: 1)
        XCTAssertEqual(JourneyStoryBuilder.title(homeLabel: "Home", stops: [park, beach, border]),
                       "Summer holidays in Spain")
        XCTAssertTrue(PlaceNaming.looksLandmarkOrTransit("Park Güell"))
        XCTAssertTrue(PlaceNaming.looksStreetLevel("Avenida Tomás Grau Gurrea"))
        XCTAssertEqual(JourneyRegionNames.country(latitude: 48.14, longitude: 11.58), "Germany")
        XCTAssertEqual(JourneyRegionNames.country(latitude: 48.26, longitude: 24.25), "Ukraine")
        XCTAssertEqual(JourneyRegionNames.country(latitude: 48.24, longitude: 24.25), "Ukraine")
        XCTAssertEqual(JourneyRegionNames.country(latitude: 47.65, longitude: 26.25), "Romania")
        XCTAssertEqual(JourneyRegionNames.country(latitude: 41.9, longitude: 12.5), "Italy")
        XCTAssertNil(JourneyRegionNames.country(latitude: 0, longitude: 0))
        let summer = StorySummary(id: "s", title: "Summer holidays in France", start: start,
            end: start.addingTimeInterval(8 * 86_400), momentIDs: ["a"], photoCount: 1,
            highlightCount: 0, coverAssetID: nil, kind: .journey, stops: [paris, lyon],
            synopsis: nil, customized: false)
        XCTAssertTrue(summer.isFinalizedJourney)
        let shell = StorySummary(id: "shell", title: "Journey from Home", start: start, end: start,
            momentIDs: ["a"], photoCount: 1, highlightCount: 0, coverAssetID: nil, kind: .journey,
            stops: [], synopsis: nil, customized: false)
        XCTAssertFalse(shell.isFinalizedJourney)
    }

    func testJourneyUsesMappedHomesAndDropsThinMessengerStops() {
        let nlHome = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.1, longitude: 4.9,
                                     radius: 1_000)
        let uaHome = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.84,
                                     longitude: 24.03, radius: 1_000)
        func rich(_ id: String, _ time: TimeInterval, count: Int) -> PhotoMoment {
            let photos = (0..<count).map { photo("\(id)-\($0)", time + Double($0)) }
            return PhotoMoment(id: id, start: Date(timeIntervalSince1970: time),
                               end: Date(timeIntervalSince1970: time + Double(count)), photos: photos)
        }
        let moments = [
            rich("home-nl", 0, count: 4),
            rich("dublin", 86_400, count: 20),
            rich("messenger", 2 * 86_400, count: 1),
            rich("cork", 3 * 86_400, count: 12),
            rich("home-nl-back", 6 * 86_400, count: 3)
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home-nl": .init(latitude: 52.1, longitude: 4.9),
            "dublin": .init(latitude: 53.34, longitude: -6.26),
            "messenger": .init(latitude: 53.39, longitude: -2.59), // Warrington-like ping
            "cork": .init(latitude: 51.9, longitude: -8.47),
            "home-nl-back": .init(latitude: 52.1, longitude: 4.9),
        ]
        let places = ["dublin": "Dublin", "messenger": "Warrington", "cork": "Cork"]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nlHome, uaHome],
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: { $0.photos.count })
        XCTAssertEqual(stories.count, 1)
        let stops = stories[0].stops
        XCTAssertEqual(stops.first?.place, "Home")
        XCTAssertEqual(stops.last?.place, "Home")
        XCTAssertFalse(stops.contains { $0.place == "Warrington" })
        XCTAssertTrue(stops.contains { $0.place == "Dublin" })
        XCTAssertTrue(stops.contains { $0.place == "Cork" })
        XCTAssertEqual(stories[0].placeID, "Journey to Ireland in 1970")
    }

    func testMallAndStreetLabelsDoNotBecomeJourneysOrPanamaTownLists() {
        XCTAssertTrue(PlaceNaming.looksLandmarkOrTransit("Woodland Mall"))
        XCTAssertTrue(PlaceNaming.looksStreetLevel("Vía Nusagandi"))
        let start = Date(timeIntervalSince1970: 1_400_000_000)
        let sanBlas = JourneyStopEvidence(start: start, end: start.addingTimeInterval(2 * 86_400),
            latitude: 9.55, longitude: -78.9, momentCount: 3, photoCount: 40,
            place: "San Blas", confidence: 1)
        let panamaCity = JourneyStopEvidence(start: start.addingTimeInterval(3 * 86_400),
            end: start.addingTimeInterval(6 * 86_400),
            latitude: 8.98, longitude: -79.52, momentCount: 4, photoCount: 50,
            place: "Panama City", confidence: 1)
        let via = JourneyStopEvidence(start: start.addingTimeInterval(7 * 86_400),
            end: start.addingTimeInterval(8 * 86_400),
            latitude: 9.3, longitude: -79.0, momentCount: 1, photoCount: 5,
            place: "Vía Nusagandi", confidence: 1)
        XCTAssertEqual(JourneyStoryBuilder.title(homeLabel: "Home", stops: [sanBlas, panamaCity, via]),
                       "Spring holidays in Panama")
        XCTAssertEqual(JourneyStoryBuilder.title(homeLabel: "Home",
            stops: [JourneyStopEvidence(start: start, end: start.addingTimeInterval(2 * 86_400),
                latitude: 42.9, longitude: -85.6, momentCount: 2, photoCount: 12,
                place: "Woodland Mall", confidence: 1)]),
                       "Journey from Home")

        let home = MeaningfulPlace(label: "Home", address: "Home", latitude: 52.1, longitude: 4.9,
                                   radius: 1_000)
        func rich(_ id: String, _ time: TimeInterval, count: Int) -> PhotoMoment {
            let photos = (0..<count).map { photo("\(id)-\($0)", time + Double($0)) }
            return PhotoMoment(id: id, start: Date(timeIntervalSince1970: time),
                               end: Date(timeIntervalSince1970: time + Double(count)), photos: photos)
        }
        let mallTrip = [
            rich("home-a", 0, count: 3),
            rich("mall-1", 86_400, count: 8),
            rich("mall-2", 3 * 86_400, count: 6),
            rich("home-b", 5 * 86_400, count: 3)
        ]
        let mallCoords: [String: CLLocationCoordinate2D] = [
            "home-a": .init(latitude: 52.1, longitude: 4.9),
            "mall-1": .init(latitude: 42.91, longitude: -85.67),
            "mall-2": .init(latitude: 42.92, longitude: -85.66),
            "home-b": .init(latitude: 52.1, longitude: 4.9),
        ]
        XCTAssertTrue(JourneyStoryBuilder.stories(mallTrip, home: home,
            coordinate: { mallCoords[$0.id] },
            placeID: { $0.id.hasPrefix("mall") ? "Woodland Mall" : nil },
            support: { $0.photos.count }).isEmpty)
    }

    func testJourneyMergePlanCollapsesAnExactMomentSet() {
        let left = CurationStory(id: "a", start: Date(timeIntervalSince1970: 10),
            end: Date(timeIntervalSince1970: 20), momentIDs: ["m1", "m2"], placeID: "Journey to Paris",
            kind: .journey, stops: [])
        let right = CurationStory(id: "b", start: Date(timeIntervalSince1970: 30),
            end: Date(timeIntervalSince1970: 40), momentIDs: ["m3"], placeID: "Journey to Lyon",
            kind: .journey, stops: [])
        let outing = CurationStory(id: "o", start: Date(timeIntervalSince1970: 5),
            end: Date(timeIntervalSince1970: 6), momentIDs: ["local"], placeID: "Market",
            kind: .outing, stops: [])
        let merge = JourneyMergeRecord(id: JourneyMergePlan.id(momentIDs: ["m1", "m2", "m3"]),
            momentIDs: ["m3", "m1", "m2"], title: "Summer holidays in France")
        let applied = JourneyMergePlan.applying([left, right, outing], merges: [merge])
        XCTAssertEqual(applied.map(\.id).sorted(), [merge.id, "o"].sorted())
        XCTAssertEqual(applied.first { $0.id == merge.id }?.placeID, "Summer holidays in France")
        XCTAssertEqual(applied.first { $0.id == merge.id }?.momentIDs, ["m1", "m2", "m3"])
        let drifted = JourneyMergePlan.applying([left, outing], merges: [merge])
        XCTAssertEqual(drifted.map(\.id), ["a", "o"])
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
        var ferry = JourneyLocalTransportSupport()
        ferry.inspect(labels: ["ferry"], lines: [.init(text: "Veerdienst", confidence: 0.95)])
        ferry.inspect(labels: ["boat"], lines: [.init(text: "Ferry", confidence: 0.9)])
        let overland = JourneyLegEvidence(mode: .overland, distanceMeters: 40_000, elapsedSeconds: 3600, confidence: 0.65)
        XCTAssertEqual(ferry.applying(to: overland).confidence, 0.75, accuracy: 0.001)
        var boarding = JourneyLocalTransportSupport()
        boarding.inspect(labels: ["jet"], lines: [.init(text: "Boardingkaart 12A", confidence: 0.9)])
        boarding.inspect(labels: ["airplane"], lines: [.init(text: "Carte d'embarquement", confidence: 0.85)])
        XCTAssertEqual(boarding.applying(to: air).confidence, 0.9, accuracy: 0.001)
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

        // Multi-day continental gap (photos at Home after Panama) is still air.
        let panama = Date(timeIntervalSince1970: 2_000_000)
        let gapStops = [
            JourneyStopEvidence(start: panama, end: panama, latitude: 9.0, longitude: -79.5,
                momentCount: 1, photoCount: 20, place: "Panama City", confidence: 1),
            JourneyStopEvidence(start: panama.addingTimeInterval(2 * 86_400),
                end: panama.addingTimeInterval(2 * 86_400), latitude: 52.08, longitude: 4.85,
                momentCount: 1, photoCount: 3, place: "Home", confidence: 1),
        ]
        let gap = JourneyTransportInference.applying(to: gapStops)
        XCTAssertEqual(gap[1].transportFromPrevious?.mode, .air)
        XCTAssertLessThan(gap[1].transportFromPrevious?.confidence ?? 1, 0.8)

        // Home → Fontainebleau ~437 km over ~39 h is a car trip with overnight stops, not air.
        let road = Date(timeIntervalSince1970: 3_000_000)
        let roadStops = [
            JourneyStopEvidence(start: road, end: road, latitude: 52.08, longitude: 4.85,
                momentCount: 1, photoCount: 8, place: "Home", confidence: 1),
            JourneyStopEvidence(start: road.addingTimeInterval(39 * 3600),
                end: road.addingTimeInterval(40 * 3600), latitude: 48.40, longitude: 2.70,
                momentCount: 2, photoCount: 20, place: "Fontainebleau", confidence: 1),
        ]
        let roadInferred = JourneyTransportInference.applying(to: roadStops)
        XCTAssertEqual(roadInferred[1].transportFromPrevious?.mode, .overland)

        // Bucharest → Home 7 days later, 1,780 km: still a flight, not an unknown grey line.
        let bucharest = Date(timeIntervalSince1970: 4_000_000)
        let homebound = [
            JourneyStopEvidence(start: bucharest, end: bucharest, latitude: 44.43, longitude: 26.10,
                momentCount: 3, photoCount: 13, place: "Bucharest", confidence: 1),
            JourneyStopEvidence(start: bucharest.addingTimeInterval(7 * 86_400),
                end: bucharest.addingTimeInterval(7 * 86_400), latitude: 52.08, longitude: 4.85,
                momentCount: 1, photoCount: 2, place: "Home", confidence: 1),
        ]
        XCTAssertEqual(JourneyTransportInference.applying(to: homebound)[1].transportFromPrevious?.mode, .air)

        // Garraf → Home ~1,230 km in 18 h at driving-like speed is still a flight.
        let garraf = Date(timeIntervalSince1970: 5_000_000)
        let spainHome = [
            JourneyStopEvidence(start: garraf, end: garraf, latitude: 41.18, longitude: 1.90,
                momentCount: 1, photoCount: 3, place: "Costes del Garraf", confidence: 1),
            JourneyStopEvidence(start: garraf.addingTimeInterval(18 * 3600),
                end: garraf.addingTimeInterval(18 * 3600), latitude: 52.08, longitude: 4.85,
                momentCount: 1, photoCount: 3, place: "Home", confidence: 1),
        ]
        XCTAssertEqual(JourneyTransportInference.applying(to: spainHome)[1].transportFromPrevious?.mode, .air)

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

    func testMessengerOceanPinDoesNotKinkPanamaRoute() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let start = Date(timeIntervalSince1970: 1_765_000_000)
        let stops = [
            JourneyStopEvidence(start: start, end: start, latitude: 52.08, longitude: 4.85,
                momentCount: 1, photoCount: 16, place: "Home", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(86_400), end: start.addingTimeInterval(86_400),
                latitude: 9.07, longitude: -79.39, momentCount: 1, photoCount: 2,
                place: "Aeropuerto Internacional de Tocumen", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(2 * 86_400),
                end: start.addingTimeInterval(2 * 86_400 + 10 * 3600),
                latitude: 9.51, longitude: -78.90, momentCount: 3, photoCount: 178,
                place: "San Blas", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(3 * 86_400),
                end: start.addingTimeInterval(3 * 86_400),
                latitude: 8.99, longitude: -79.52, momentCount: 1, photoCount: 2,
                place: "Panama City", confidence: 1),
        // Messenger noise: unlabeled mid-Atlantic pin between Panama City days.
        JourneyStopEvidence(start: start.addingTimeInterval(3 * 86_400 + 12 * 3600),
            end: start.addingTimeInterval(3 * 86_400 + 14 * 3600),
            latitude: 30.53, longitude: -37.33, momentCount: 1, photoCount: 5,
            place: nil, confidence: 0.6),
        JourneyStopEvidence(start: start.addingTimeInterval(4 * 86_400),
            end: start.addingTimeInterval(5 * 86_400),
            latitude: 9.00, longitude: -79.50, momentCount: 8, photoCount: 27,
            place: "Panama City", confidence: 1),
        ]
        let cleaned = JourneyStopSanitizer.removingRouteNoise(stops, homes: [home])
        XCTAssertFalse(cleaned.contains { abs($0.latitude - 30.53) < 0.1 })
        XCTAssertTrue(cleaned.contains { $0.place == "San Blas" })
        XCTAssertEqual(cleaned.first?.place, "Home")
        XCTAssertEqual(cleaned.filter { $0.place == "Home" }.count, 1)
    }

    func testUnlabeledOceanPinBetweenNearbyStaysIsDropped() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let start = Date(timeIntervalSince1970: 1_765_000_000)
        let stops = [
            JourneyStopEvidence(start: start, end: start, latitude: 8.99, longitude: -79.52,
                momentCount: 1, photoCount: 2, place: "Panama City", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(12 * 3600),
                end: start.addingTimeInterval(14 * 3600),
                latitude: 30.53, longitude: -37.33, momentCount: 1, photoCount: 5,
                place: nil, confidence: 0.6),
            JourneyStopEvidence(start: start.addingTimeInterval(24 * 3600),
                end: start.addingTimeInterval(36 * 3600),
                latitude: 9.00, longitude: -79.50, momentCount: 8, photoCount: 27,
                place: "Panama City", confidence: 1),
        ]
        let cleaned = JourneyStopSanitizer.removingRouteNoise(stops, homes: [home])
        XCTAssertEqual(cleaned.count, 1, "Nearby Panama City stays merge after the ocean pin drops")
        XCTAssertFalse(cleaned.contains { abs($0.latitude - 30.53) < 0.1 })
        XCTAssertEqual(cleaned.first?.place, "Panama City")
    }

    func testFranceDriveDropsHighwayMotelPinsAndStaysOverland() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let start = Date(timeIntervalSince1970: 1_784_500_000)
        let day: TimeInterval = 86_400
        let stops = [
            JourneyStopEvidence(start: start, end: start, latitude: 52.08, longitude: 4.85,
                momentCount: 1, photoCount: 2, place: "Home", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(day),
                end: start.addingTimeInterval(2 * day),
                latitude: 48.40, longitude: 2.70, momentCount: 3, photoCount: 626,
                place: "Fontainebleau", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(3 * day),
                end: start.addingTimeInterval(4 * day),
                latitude: 45.53, longitude: 4.87, momentCount: 2, photoCount: 296,
                place: "Cours Charlemagne", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(5 * day),
                end: start.addingTimeInterval(12 * day),
                latitude: 43.33, longitude: 6.69, momentCount: 20, photoCount: 631,
                place: "Sainte-Maxime", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(13 * day),
                end: start.addingTimeInterval(13 * day + 3600),
                latitude: 43.51, longitude: 5.50, momentCount: 1, photoCount: 4,
                place: "Meyreuil", confidence: 0.5),
            JourneyStopEvidence(start: start.addingTimeInterval(13 * day + 2 * 3600),
                end: start.addingTimeInterval(13 * day + 3 * 3600),
                latitude: 44.30, longitude: 4.73, momentCount: 1, photoCount: 2,
                place: "A 7", confidence: 0.4),
            JourneyStopEvidence(start: start.addingTimeInterval(15 * day),
                end: start.addingTimeInterval(15 * day + 8 * 3600),
                latitude: 49.25, longitude: 4.04, momentCount: 3, photoCount: 591,
                place: "Basilique Saint-Remi", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(16 * day),
                end: start.addingTimeInterval(16 * day),
                latitude: 52.08, longitude: 4.85, momentCount: 1, photoCount: 8,
                place: "Home", confidence: 1),
        ]
        let cleaned = JourneyStopSanitizer.removingRouteNoise(stops, homes: [home])
        let places = cleaned.compactMap(\.place)
        XCTAssertFalse(places.contains("Meyreuil"), places.joined(separator: " → "))
        XCTAssertFalse(places.contains("A 7"), places.joined(separator: " → "))
        XCTAssertTrue(places.contains("Sainte-Maxime"))
        XCTAssertTrue(places.contains("Basilique Saint-Remi") || places.contains("Fontainebleau"))
        let inferred = JourneyTransportInference.applying(to: cleaned)
        XCTAssertTrue(inferred.dropFirst().allSatisfy { $0.transportFromPrevious?.mode != .air },
                      inferred.compactMap { $0.transportFromPrevious?.mode.rawValue }.joined(separator: ","))
    }

    func testParisWeekendDropsTractaatwegAndStaysOverland() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let start = Date(timeIntervalSince1970: 1_748_500_000)
        let stops = [
            JourneyStopEvidence(start: start, end: start.addingTimeInterval(20 * 3600),
                latitude: 52.08, longitude: 4.85, momentCount: 1, photoCount: 4,
                place: "Home", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(40 * 3600),
                end: start.addingTimeInterval(40 * 3600),
                latitude: 51.227, longitude: 3.841, momentCount: 1, photoCount: 2,
                place: "Tractaatweg", confidence: 0.4),
            JourneyStopEvidence(start: start.addingTimeInterval(45 * 3600),
                end: start.addingTimeInterval(3 * 86_400),
                latitude: 48.861, longitude: 2.328, momentCount: 10, photoCount: 658,
                place: "Paris", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(4 * 86_400 + 20 * 3600),
                end: start.addingTimeInterval(5 * 86_400),
                latitude: 52.08, longitude: 4.85, momentCount: 1, photoCount: 4,
                place: "Home", confidence: 1),
        ]
        let cleaned = JourneyStopSanitizer.removingRouteNoise(stops, homes: [home])
        XCTAssertFalse(cleaned.contains { $0.place == "Tractaatweg" },
                       cleaned.compactMap(\.place).joined(separator: " → "))
        let inferred = JourneyTransportInference.applying(to: cleaned)
        XCTAssertTrue(inferred.dropFirst().allSatisfy { $0.transportFromPrevious?.mode == .overland },
                      inferred.compactMap { $0.transportFromPrevious?.mode.rawValue }.joined(separator: ","))
        XCTAssertEqual(JourneyStoryBuilder.title(homeLabel: "Home", stops: cleaned),
                       "Journey to Paris")
    }

    func testFrance2017DriveTitlesParisNotDisneyland() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_494_244_800) // 2017-05-08
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("home0", stamp(0)),
            moment("paris", stamp(0.4)),
            moment("disney", stamp(1)),
            moment("pont", stamp(3)),
            moment("home-end", stamp(4)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home0": .init(latitude: 52.08, longitude: 4.85),
            "paris": .init(latitude: 48.878, longitude: 2.352),
            "disney": .init(latitude: 48.869, longitude: 2.784),
            "pont": .init(latitude: 48.857, longitude: 2.323),
            "home-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let places = [
            "paris": "Paris",
            "disney": "Disneyland Paris",
            "pont": "Pont d'Iéna",
        ]
        let stories = JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: {
                if $0.id == "disney" { return 80 }
                if $0.id == "pont" { return 40 }
                if $0.id == "paris" { return 4 }
                return 8
            })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertFalse(stories[0].placeID.contains("Disney"), stories[0].placeID)
        XCTAssertFalse(stories[0].placeID.contains("Iéna") || stories[0].placeID.contains("Pont"),
                       stories[0].placeID)
        XCTAssertTrue(stories[0].placeID.contains("Paris") || stories[0].placeID.contains("France"),
                      stories[0].placeID)
        XCTAssertEqual(stories[0].stops.first?.place, "Home")
        XCTAssertEqual(stories[0].stops.last?.place, "Home")
        let inferred = JourneyTransportInference.applying(to: stories[0].stops)
        XCTAssertTrue(inferred.dropFirst().allSatisfy { $0.transportFromPrevious?.mode == .overland },
                      inferred.compactMap { $0.transportFromPrevious?.mode.rawValue }.joined(separator: ","))
        XCTAssertTrue(PlaceNaming.looksLandmarkOrTransit("Disneyland Paris"))
        XCTAssertTrue(PlaceNaming.looksLandmarkOrTransit("Pont d'Iéna"))
    }

    func testBerlin2016WeekendFliesHomeHopsAndKeepsGorzowDrive() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_464_134_400) // 2016-05-25
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("home0", stamp(0)),
            moment("berlin", stamp(0.3)),
            moment("gorzow", stamp(2)),
            moment("garden", stamp(3)),
            moment("oranienburg", stamp(4)),
            moment("home-end", stamp(4.55)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home0": .init(latitude: 52.08, longitude: 4.85),
            "berlin": .init(latitude: 52.513, longitude: 13.362),
            "gorzow": .init(latitude: 53.038, longitude: 14.690),
            "garden": .init(latitude: 52.472, longitude: 13.502),
            "oranienburg": .init(latitude: 52.766, longitude: 13.262),
            "home-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let places = [
            "berlin": "Berlin",
            "gorzow": "al Róż",
            "garden": "Kleingartenanlage Oberspree",
            "oranienburg": "Oranienburg",
        ]
        let stories = JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: {
                switch $0.id {
                case "berlin": return 80
                case "gorzow": return 50
                case "garden": return 7
                case "oranienburg": return 80
                default: return 8
                }
            })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertTrue(stories[0].placeID.contains("Germany") || stories[0].placeID.contains("Berlin"),
                      stories[0].placeID)
        XCTAssertTrue(stories[0].placeID.contains("Poland") || stories[0].placeID.contains("Gorzów")
                        || stories[0].stops.contains { abs($0.latitude - 53.038) < 0.05 },
                      stories[0].placeID)
        XCTAssertFalse(stories[0].placeID.contains("Róż") || stories[0].placeID.contains("Kleingarten"),
                       stories[0].placeID)
        XCTAssertEqual(stories[0].stops.first?.place, "Home")
        XCTAssertEqual(stories[0].stops.last?.place, "Home")
        let inferred = JourneyTransportInference.applying(to: stories[0].stops)
        let route = inferred.map { "\($0.place ?? "?") \($0.transportFromPrevious?.mode.rawValue ?? "-")" }
            .joined(separator: " → ")
        XCTAssertEqual(inferred.dropFirst().first?.transportFromPrevious?.mode, .air, route)
        XCTAssertEqual(inferred.last?.transportFromPrevious?.mode, .air, route)
        XCTAssertTrue(inferred.contains {
            abs($0.latitude - 53.038) < 0.05 && $0.transportFromPrevious?.mode == .overland
        }, route)
        XCTAssertTrue(PlaceNaming.looksStreetLevel("al Róż"))
        XCTAssertTrue(PlaceNaming.looksLandmarkOrTransit("Kleingartenanlage Oberspree"))

        let bavaria = [
            JourneyStopEvidence(start: origin, end: origin, latitude: 52.08, longitude: 4.85,
                momentCount: 1, photoCount: 4, place: "Home", confidence: 1),
            JourneyStopEvidence(start: origin.addingTimeInterval(day), end: origin.addingTimeInterval(2 * day),
                latitude: 52.49, longitude: 13.30, momentCount: 1, photoCount: 8, place: "Berlin", confidence: 1),
            JourneyStopEvidence(start: origin.addingTimeInterval(3 * day), end: origin.addingTimeInterval(6 * day),
                latitude: 49.09, longitude: 12.95, momentCount: 4, photoCount: 80, place: "Viechtach", confidence: 1),
            JourneyStopEvidence(start: origin.addingTimeInterval(8 * day), end: origin.addingTimeInterval(8 * day),
                latitude: 52.08, longitude: 4.85, momentCount: 1, photoCount: 4, place: "Home", confidence: 1),
        ]
        let bavariaLegs = JourneyTransportInference.applying(to: bavaria)
        XCTAssertEqual(bavariaLegs.last?.transportFromPrevious?.mode, .overland,
                       "Home ↔ Viechtach without a Berlin bookend stays overland")
    }

    func testViechtach2016FliesBerlinHopsDropsThinTransit() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_454_112_000) // 2016-01-30
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("home0", stamp(0)),
            moment("berlin1", stamp(0.3)),
            moment("viechtach", stamp(1)),
            moment("hof", stamp(7)),
            moment("sandersdorf", stamp(7.5)),
            moment("berlin2", stamp(8)),
            moment("home-end", stamp(9)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home0": .init(latitude: 52.08, longitude: 4.85),
            "berlin1": .init(latitude: 52.487, longitude: 13.302),
            "viechtach": .init(latitude: 49.092, longitude: 12.954),
            "hof": .init(latitude: 50.341, longitude: 11.939),
            "sandersdorf": .init(latitude: 51.609, longitude: 12.188),
            "berlin2": .init(latitude: 52.428, longitude: 13.450),
            "home-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let places = [
            "berlin1": "Berlin", "berlin2": "Berlin",
            "viechtach": "Viechtach",
            "hof": "Hof",
            "sandersdorf": "Sandersdorf-Brehna",
        ]
        let stories = JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: {
                switch $0.id {
                case "viechtach": return 80
                case "hof": return 3
                case "sandersdorf": return 4
                case let id where id.hasPrefix("berlin"): return 2
                default: return 6
                }
            })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertFalse(stories[0].placeID.contains("Hof") || stories[0].placeID.contains("Sandersdorf"),
                       stories[0].placeID)
        XCTAssertTrue(stories[0].placeID.contains("Germany") || stories[0].placeID.contains("Viechtach")
                        || stories[0].placeID.contains("Bavaria") || stories[0].placeID.contains("Berlin"),
                      stories[0].placeID)
        XCTAssertEqual(stories[0].stops.first?.place, "Home")
        XCTAssertEqual(stories[0].stops.last?.place, "Home")
        let placesOnRoute = stories[0].stops.compactMap(\.place)
        XCTAssertFalse(placesOnRoute.contains("Hof"))
        XCTAssertFalse(placesOnRoute.contains("Sandersdorf-Brehna"))
        XCTAssertTrue(stories[0].stops.contains { $0.place == "Viechtach" || abs($0.latitude - 49.092) < 0.05 })
        let inferred = JourneyTransportInference.applying(to: stories[0].stops)
        let route = inferred.map { "\($0.place ?? "?") \($0.transportFromPrevious?.mode.rawValue ?? "-")" }
            .joined(separator: " → ")
        XCTAssertEqual(inferred.dropFirst().first?.transportFromPrevious?.mode, .air, route)
        XCTAssertEqual(inferred.last?.transportFromPrevious?.mode, .air, route)
        XCTAssertTrue(inferred.contains {
            abs($0.latitude - 49.092) < 0.05 && $0.transportFromPrevious?.mode == .overland
        }, route)
    }

    func testUkraine2015DropsStanickiLasForestAndFliesToBerlin() {
        let nl = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                 radius: 50)
        let ua = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.80, longitude: 24.02,
                                 radius: 100)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_440_850_000) // 2015-08-29
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("ua0", stamp(0)),
            moment("las", stamp(1)),
            moment("berlin", stamp(2.5)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "ua0": .init(latitude: 49.80, longitude: 24.02),
            "las": .init(latitude: 52.517, longitude: 15.239),
            "berlin": .init(latitude: 52.431, longitude: 13.391),
        ]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] },
            placeID: {
                switch $0.id {
                case "las": return "Stanicki Las"
                case "berlin": return "Berlin"
                default: return nil
                }
            },
            support: { $0.id == "las" ? 99 : ($0.id == "berlin" ? 6 : 50) })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        guard let story = stories.first else { return }
        XCTAssertFalse(story.placeID.contains("Las") || story.placeID.contains("Poland"),
                       story.placeID)
        XCTAssertTrue(story.placeID.contains("Berlin") || story.placeID.contains("Germany"),
                      story.placeID)
        XCTAssertFalse(story.stops.contains { ($0.place ?? "").contains("Las") })
        XCTAssertFalse(story.stops.contains { abs($0.latitude - 52.517) < 0.05 })
        let inferred = JourneyTransportInference.applying(to: story.stops)
        let route = inferred.map { "\($0.place ?? "?") \($0.transportFromPrevious?.mode.rawValue ?? "-")" }
            .joined(separator: " → ")
        XCTAssertTrue(inferred.contains {
            JourneyRegionNames.isBerlinMetro(latitude: $0.latitude, longitude: $0.longitude)
                && $0.transportFromPrevious?.mode == .air
        }, route)
        XCTAssertTrue(PlaceNaming.looksForest("Stanicki Las"))
        XCTAssertFalse(PlaceNaming.CivilAirports.near(latitude: 52.517, longitude: 15.239))
        XCTAssertTrue(PlaceNaming.CivilAirports.near(latitude: 52.366, longitude: 13.503))
    }

    func testJune2015BerlinDriveStaysOverland() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_435_392_000) // 2015-06-27
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("home0", stamp(-2)),
            moment("berlin1", stamp(0)),
            moment("berlin2", stamp(2)),
            moment("home-end", stamp(3.5)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home0": .init(latitude: 52.08, longitude: 4.85),
            "berlin1": .init(latitude: 52.477, longitude: 13.367),
            "berlin2": .init(latitude: 52.477, longitude: 13.367),
            "home-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let stories = JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] },
            placeID: { $0.id.hasPrefix("berlin") ? "Berlin" : nil },
            support: { $0.id.hasPrefix("berlin") ? 45 : 20 })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertTrue(stories[0].placeID.contains("Berlin") || stories[0].placeID.contains("Germany"),
                      stories[0].placeID)
        XCTAssertEqual(stories[0].stops.last?.place, "Home")
        let inferred = JourneyTransportInference.applying(to: stories[0].stops)
        let route = inferred.map { "\($0.place ?? "?") \($0.transportFromPrevious?.mode.rawValue ?? "-")" }
            .joined(separator: " → ")
        XCTAssertTrue(inferred.dropFirst().allSatisfy { $0.transportFromPrevious?.mode == .overland },
                      route)
        XCTAssertFalse(inferred.contains { $0.transportFromPrevious?.mode == .air }, route)
    }

    func testMay2015IvanoWeekendFliesAndDropsRynokSquareTitle() {
        let nl = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                 radius: 50)
        let ua = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.80, longitude: 24.02,
                                 radius: 100)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_432_944_000) // 2015-05-30
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("home0", stamp(-1)),
            moment("rynok1", stamp(0)),
            moment("rynok2", stamp(1.8)),
            moment("home-end", stamp(2.5)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home0": .init(latitude: 52.08, longitude: 4.85),
            "rynok1": .init(latitude: 48.921, longitude: 24.706),
            "rynok2": .init(latitude: 48.921, longitude: 24.706),
            "home-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] },
            placeID: { $0.id.hasPrefix("rynok") ? "Rynok Square" : nil },
            support: { $0.id.hasPrefix("rynok") ? 58 : 8 })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertTrue(stories[0].placeID.contains("Ukraine"), stories[0].placeID)
        XCTAssertFalse(stories[0].placeID.contains("Rynok") || stories[0].placeID.contains("Square"),
                       stories[0].placeID)
        XCTAssertEqual(stories[0].stops.first?.place, "Home")
        XCTAssertEqual(stories[0].stops.last?.place, "Home")
        XCTAssertFalse(stories[0].stops.contains { ($0.place ?? "").contains("Rynok") })
        let inferred = JourneyTransportInference.applying(to: stories[0].stops)
        let route = inferred.map { "\($0.place ?? "?") \($0.transportFromPrevious?.mode.rawValue ?? "-")" }
            .joined(separator: " → ")
        XCTAssertEqual(inferred.dropFirst().first?.transportFromPrevious?.mode, .air, route)
        XCTAssertEqual(inferred.last?.transportFromPrevious?.mode, .air, route)
        XCTAssertTrue(PlaceNaming.looksLandmarkOrTransit("Rynok Square"))
    }

    func testApril2015BerlinDriveWipesStationAndParkTitles() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_429_977_600) // 2015-04-25
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("home0", stamp(-2)),
            moment("muenster", stamp(0)),
            moment("berlin1", stamp(0.2)),
            moment("berlin2", stamp(1.8)),
            moment("home-end", stamp(4)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home0": .init(latitude: 52.08, longitude: 4.85),
            "muenster": .init(latitude: 51.957, longitude: 7.635),
            "berlin1": .init(latitude: 52.477, longitude: 13.378),
            "berlin2": .init(latitude: 52.477, longitude: 13.378),
            "home-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let places = [
            "muenster": "Münster (Westf) Hbf",
            "berlin1": "Tiergarten",
            "berlin2": "Tiergarten",
        ]
        let stories = JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: {
                switch $0.id {
                case "muenster": return 4
                case let id where id.hasPrefix("berlin"): return 49
                default: return 8
                }
            })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertTrue(stories[0].placeID.contains("Germany") || stories[0].placeID.contains("Berlin"),
                      stories[0].placeID)
        XCTAssertFalse(stories[0].placeID.contains("Hbf") || stories[0].placeID.contains("Münster")
                        || stories[0].placeID.contains("Tiergarten"),
                       stories[0].placeID)
        XCTAssertEqual(stories[0].stops.first?.place, "Home")
        XCTAssertEqual(stories[0].stops.last?.place, "Home")
        let inferred = JourneyTransportInference.applying(to: stories[0].stops)
        let route = inferred.map { "\($0.place ?? "?") \($0.transportFromPrevious?.mode.rawValue ?? "-")" }
            .joined(separator: " → ")
        XCTAssertTrue(inferred.dropFirst().allSatisfy { $0.transportFromPrevious?.mode == .overland },
                      route)
        XCTAssertTrue(PlaceNaming.looksLandmarkOrTransit("Münster (Westf) Hbf"))
        XCTAssertTrue(PlaceNaming.looksLandmarkOrTransit("Tiergarten"))
    }

    func testNovember2014LeavesUkraineViaKyivWithoutInventingNLStart() {
        let nl = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                 radius: 50)
        let ua = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.80, longitude: 24.02,
                                 radius: 100)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_416_700_800) // 2014-11-23
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("ua0", stamp(0)),
            moment("kyiv1", stamp(2)),
            moment("kyiv2", stamp(4)),
            moment("nl-end", stamp(5)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "ua0": .init(latitude: 49.80, longitude: 24.02),
            "kyiv1": .init(latitude: 50.445, longitude: 30.514),
            "kyiv2": .init(latitude: 50.445, longitude: 30.514),
            "nl-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] },
            placeID: { $0.id.hasPrefix("kyiv") ? "Kyiv" : nil },
            support: { $0.id.hasPrefix("kyiv") ? 11 : 8 })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertTrue(stories[0].placeID.contains("Kyiv") || stories[0].placeID.contains("Ukraine"),
                      stories[0].placeID)
        XCTAssertEqual(stories[0].stops.first?.place, "Home in Ukraine")
        XCTAssertEqual(stories[0].stops.last?.place, "Home")
        XCTAssertFalse(stories[0].stops.dropLast().contains {
            ($0.place ?? "").compare("Home", options: [.caseInsensitive]) == .orderedSame
        })
        XCTAssertTrue(stories[0].stops.contains { $0.place == "Kyiv" || abs($0.latitude - 50.445) < 0.05 })
        let inferred = JourneyTransportInference.applying(to: stories[0].stops)
        let route = inferred.map { "\($0.place ?? "?") \($0.transportFromPrevious?.mode.rawValue ?? "-")" }
            .joined(separator: " → ")
        XCTAssertEqual(inferred.last?.transportFromPrevious?.mode, .air, route)
        XCTAssertTrue(inferred.dropFirst().dropLast().allSatisfy {
            $0.transportFromPrevious?.mode != .air
        }, route)
        XCTAssertTrue(JourneyRegionNames.isKyivMetro(latitude: 50.445, longitude: 30.514))
    }

    func testAugust2014TurkeyFliesFromUkraineHomeAndDropsMuratpasaTitle() {
        let nl = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                 radius: 50)
        let ua = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.80, longitude: 24.02,
                                 radius: 100)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_408_636_800) // 2014-08-21
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("ua0", stamp(0)),
            moment("coast", stamp(1)),
            moment("muratpasa", stamp(8)),
            moment("ua-end", stamp(10)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "ua0": .init(latitude: 49.80, longitude: 24.02),
            "coast": .init(latitude: 36.559, longitude: 31.937),
            "muratpasa": .init(latitude: 36.897, longitude: 30.802),
            "ua-end": .init(latitude: 49.80, longitude: 24.02),
        ]
        let places = ["coast": "Türkiye", "muratpasa": "Muratpasa"]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: { $0.id == "coast" ? 77 : ($0.id == "muratpasa" ? 11 : 8) })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertTrue(stories[0].placeID.contains("Turkey") || stories[0].placeID.contains("Türkiye"),
                      stories[0].placeID)
        XCTAssertFalse(stories[0].placeID.contains("Muratpasa") || stories[0].placeID.contains("Muratpaşa"),
                       stories[0].placeID)
        XCTAssertEqual(stories[0].stops.first?.place, "Home in Ukraine")
        XCTAssertEqual(stories[0].stops.last?.place, "Home in Ukraine")
        let inferred = JourneyTransportInference.applying(to: stories[0].stops)
        let route = inferred.map { "\($0.place ?? "?") \($0.transportFromPrevious?.mode.rawValue ?? "-")" }
            .joined(separator: " → ")
        XCTAssertEqual(inferred.dropFirst().first?.transportFromPrevious?.mode, .air, route)
        XCTAssertEqual(inferred.last?.transportFromPrevious?.mode, .air, route)
        XCTAssertTrue(PlaceNaming.looksLandmarkOrTransit("Muratpasa"))
        XCTAssertTrue(PlaceNaming.looksLandmarkOrTransit("Muratpaşa"))
    }

    func testJune2014SlavskaKeepsVillageTitleAndStartsAtUkraineHome() {
        let nl = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                 radius: 50)
        let ua = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.80, longitude: 24.02,
                                 radius: 100)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_402_156_800) // 2014-06-07
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("ua0", stamp(-2)),
            moment("slav1", stamp(0)),
            moment("slav2", stamp(2)),
            moment("ua-end", stamp(8)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "ua0": .init(latitude: 49.80, longitude: 24.02),
            "slav1": .init(latitude: 48.803, longitude: 23.462),
            "slav2": .init(latitude: 48.803, longitude: 23.462),
            "ua-end": .init(latitude: 49.80, longitude: 24.02),
        ]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] },
            placeID: { $0.id.hasPrefix("slav") ? "Slavs'ka" : nil },
            support: { $0.id.hasPrefix("slav") ? 80 : 6 })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertTrue(stories[0].placeID.contains("Slavs'ka") || stories[0].placeID.contains("Slavska"),
                      stories[0].placeID)
        XCTAssertFalse(stories[0].placeID.contains("Germany") || stories[0].placeID.contains("Netherlands"),
                       stories[0].placeID)
        XCTAssertEqual(stories[0].stops.first?.place, "Home in Ukraine")
        XCTAssertEqual(stories[0].stops.last?.place, "Home in Ukraine")
        let inferred = JourneyTransportInference.applying(to: stories[0].stops)
        let route = inferred.map { "\($0.place ?? "?") \($0.transportFromPrevious?.mode.rawValue ?? "-")" }
            .joined(separator: " → ")
        XCTAssertTrue(inferred.dropFirst().allSatisfy { $0.transportFromPrevious?.mode == .overland },
                      route)
    }

    func testApril2014USAAlreadyInCaliforniaFliesHomeAndDropsLaterKyiv() {
        let nl = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                 radius: 50)
        let ua = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.80, longitude: 24.02,
                                 radius: 100)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_397_433_600) // 2014-04-13
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("ua-old", stamp(-50)),
            moment("mv", stamp(0)),
            moment("sf", stamp(2)),
            moment("austin", stamp(3)),
            moment("bay", stamp(10)),
            moment("ua-end", stamp(16)),
            moment("kyiv", stamp(19)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "ua-old": .init(latitude: 49.80, longitude: 24.02),
            "mv": .init(latitude: 37.420, longitude: -122.087),
            "sf": .init(latitude: 37.801, longitude: -122.470),
            "austin": .init(latitude: 30.307, longitude: -97.732),
            "bay": .init(latitude: 37.329, longitude: -122.118),
            "ua-end": .init(latitude: 49.80, longitude: 24.02),
            "kyiv": .init(latitude: 50.445, longitude: 30.514),
        ]
        let places = [
            "mv": "Mountain View", "sf": "San Francisco", "austin": "Austin",
            "bay": "Los Altos", "kyiv": "Kyiv",
        ]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: {
                switch $0.id {
                case "austin": return 66
                case "kyiv": return 4
                case "ua-old", "ua-end": return 3
                default: return 40
                }
            })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertTrue(stories[0].placeID.contains("USA") || stories[0].placeID.contains("United"),
                      stories[0].placeID)
        XCTAssertFalse(stories[0].placeID.contains("Kyiv") || stories[0].placeID.contains("Ukraine"),
                       stories[0].placeID)
        XCTAssertNotEqual(stories[0].stops.first?.place, "Home in Ukraine")
        XCTAssertEqual(stories[0].stops.last?.place, "Home in Ukraine")
        XCTAssertFalse(stories[0].stops.contains { $0.place == "Kyiv" || abs($0.latitude - 50.445) < 0.05 })
        let inferred = JourneyTransportInference.applying(to: stories[0].stops)
        let route = inferred.map { "\($0.place ?? "?") \($0.transportFromPrevious?.mode.rawValue ?? "-")" }
            .joined(separator: " → ")
        XCTAssertEqual(inferred.last?.transportFromPrevious?.mode, .air, route)
        XCTAssertTrue(inferred.contains {
            abs($0.latitude - 30.307) < 0.05 && $0.transportFromPrevious?.mode == .air
        }, route)
    }

    func testJanuary2014SplitsBukovelOutingFromMunichCaliforniaCircuit() {
        let nl = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                 radius: 50)
        let ua = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.80, longitude: 24.02,
                                 radius: 100)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_389_744_000) // 2014-01-15
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("ua0", stamp(0)),
            moment("buk1", stamp(2)),
            moment("buk2", stamp(5)),
            moment("ua1", stamp(7)),
            moment("redwood", stamp(8)),
            moment("bay-mid", stamp(30)),
            moment("monterey", stamp(68)),
            moment("munich", stamp(70)),
            moment("ua-end", stamp(73)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "ua0": .init(latitude: 49.80, longitude: 24.02),
            "buk1": .init(latitude: 48.36, longitude: 24.41),
            "buk2": .init(latitude: 48.36, longitude: 24.41),
            "ua1": .init(latitude: 49.80, longitude: 24.02),
            "redwood": .init(latitude: 37.50, longitude: -122.21),
            "bay-mid": .init(latitude: 37.50, longitude: -122.21),
            "monterey": .init(latitude: 36.62, longitude: -121.90),
            "munich": .init(latitude: 48.17, longitude: 11.56),
            "ua-end": .init(latitude: 49.80, longitude: 24.02),
        ]
        let places = [
            "buk1": "Polianyts'ka", "buk2": "Polianyts'ka",
            "redwood": "Redwood City", "monterey": "Monterey", "munich": "Munich",
        ]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: {
                if $0.id.hasPrefix("buk") { return 80 }
                if $0.id == "munich" { return 80 }
                if $0.id.hasPrefix("ua") { return 8 }
                return 50
            })
        XCTAssertEqual(stories.count, 2, stories.map(\.placeID).joined(separator: ", "))
        let outing = stories.first {
            $0.placeID.contains("Polianyts") || $0.stops.contains { abs($0.latitude - 48.36) < 0.05 }
        }
        let usa = stories.first {
            $0.placeID.contains("USA") || $0.stops.contains { abs($0.latitude - 37.50) < 0.1 }
        }
        XCTAssertNotNil(outing, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertNotNil(usa, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertTrue(outing!.placeID.contains("Polianyts") || outing!.placeID.contains("Bukovel"),
                      outing!.placeID)
        XCTAssertTrue(usa!.placeID.contains("USA"), usa!.placeID)
        XCTAssertFalse(usa!.placeID.contains("Germany") || usa!.placeID.contains("Munich"),
                       usa!.placeID)
        XCTAssertFalse(usa!.stops.contains { abs($0.latitude - 48.36) < 0.05 })
        XCTAssertEqual(usa!.stops.first?.place, "Home in Ukraine")
        XCTAssertEqual(usa!.stops.last?.place, "Home in Ukraine")
        XCTAssertTrue(usa!.stops.contains {
            JourneyRegionNames.isMunichMetro(latitude: $0.latitude, longitude: $0.longitude)
        })
        let inferred = JourneyTransportInference.applying(to: usa!.stops)
        let route = inferred.map { "\($0.place ?? "?") \($0.transportFromPrevious?.mode.rawValue ?? "-")" }
            .joined(separator: " → ")
        XCTAssertEqual(inferred.last?.transportFromPrevious?.mode, .air, route)
        XCTAssertTrue(inferred.contains {
            JourneyRegionNames.isMunichMetro(latitude: $0.latitude, longitude: $0.longitude)
                && $0.transportFromPrevious?.mode == .air
        }, route)
        XCTAssertTrue(inferred.contains {
            abs($0.latitude - 36.62) < 0.05 && $0.transportFromPrevious?.mode == .overland
        }, route)
        let bukovelLegs = JourneyTransportInference.applying(to: outing!.stops)
        XCTAssertTrue(bukovelLegs.dropFirst().allSatisfy { $0.transportFromPrevious?.mode != .air })
    }

    func testDecember2013SplitsKrakowDriveFromCaliforniaFlightHome() {
        let nl = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                 radius: 50)
        let ua = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.80, longitude: 24.02,
                                 radius: 100)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_386_345_600) // 2013-12-06
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("ua-old", stamp(-50)),
            moment("ca1", stamp(0)),
            moment("ca2", stamp(1)),
            moment("krakow", stamp(15)),
            moment("ua-end", stamp(22)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "ua-old": .init(latitude: 49.80, longitude: 24.02),
            "ca1": .init(latitude: 37.516, longitude: -122.258),
            "ca2": .init(latitude: 37.516, longitude: -122.258),
            "krakow": .init(latitude: 50.058, longitude: 19.938),
            "ua-end": .init(latitude: 49.80, longitude: 24.02),
        ]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] },
            placeID: {
                if $0.id.hasPrefix("ca") { return "San Carlos" }
                if $0.id == "krakow" { return "Kraków" }
                return nil
            },
            support: {
                if $0.id.hasPrefix("ca") { return 12 }
                if $0.id == "krakow" { return 94 }
                return 8
            })
        XCTAssertEqual(stories.count, 2, stories.map(\.placeID).joined(separator: ", "))
        let usa = stories.first {
            $0.stops.contains { abs($0.latitude - 37.516) < 0.05 }
        }
        let poland = stories.first {
            $0.stops.contains { abs($0.latitude - 50.058) < 0.05 }
        }
        XCTAssertNotNil(usa, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertNotNil(poland, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertTrue(usa!.placeID.contains("USA") || usa!.placeID.contains("San Carlos"),
                      usa!.placeID)
        XCTAssertFalse(usa!.placeID.contains("Poland") || usa!.placeID.contains("Krak"),
                       usa!.placeID)
        XCTAssertFalse(usa!.stops.contains { abs($0.latitude - 50.058) < 0.05 })
        XCTAssertEqual(usa!.stops.last?.place, "Home in Ukraine")
        XCTAssertNotEqual(usa!.stops.first?.place, "Home in Ukraine")
        let usaLegs = JourneyTransportInference.applying(to: usa!.stops)
        XCTAssertEqual(usaLegs.last?.transportFromPrevious?.mode, .air)
        XCTAssertTrue(poland!.placeID.contains("Krak") || poland!.placeID.contains("Poland"),
                      poland!.placeID)
        XCTAssertEqual(poland!.stops.first?.place, "Home in Ukraine")
        XCTAssertEqual(poland!.stops.last?.place, "Home in Ukraine")
        let drive = JourneyTransportInference.applying(to: poland!.stops)
        XCTAssertTrue(drive.dropFirst().allSatisfy { $0.transportFromPrevious?.mode != .air })
        let hierarchy = StoryHierarchyBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] },
            placeID: {
                if $0.id.hasPrefix("ca") { return "San Carlos" }
                if $0.id == "krakow" { return "Kraków" }
                return nil
            },
            support: {
                if $0.id.hasPrefix("ca") { return 12 }
                if $0.id == "krakow" { return 94 }
                return 8
            })
        let claimed = hierarchy.flatMap(\.momentIDs)
        XCTAssertEqual(claimed.count, Set(claimed).count, claimed.joined(separator: ","))
    }

    func testJune2013SplitsCarpathianOutingAndAzovFlightFromCaliforniaStay() {
        let nl = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                 radius: 50)
        let ua = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.80, longitude: 24.02,
                                 radius: 100)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_371_340_800) // 2013-06-16
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("ua-old", stamp(-80)),
            moment("carp", stamp(0)),
            moment("ca1", stamp(13)),
            moment("ca2", stamp(51)),
            moment("azov1", stamp(64)),
            moment("azov2", stamp(71)),
            moment("kyiv", stamp(77)),
            moment("ca3", stamp(89)),
            moment("ca4", stamp(141)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "ua-old": .init(latitude: 49.80, longitude: 24.02),
            "carp": .init(latitude: 48.6337, longitude: 23.383),
            "ca1": .init(latitude: 37.6, longitude: -122.3),
            "ca2": .init(latitude: 37.6, longitude: -122.3),
            "azov1": .init(latitude: 46.937, longitude: 37.380),
            "azov2": .init(latitude: 47.123, longitude: 37.559),
            "kyiv": .init(latitude: 50.353, longitude: 30.898),
            "ca3": .init(latitude: 37.5, longitude: -122.2),
            "ca4": .init(latitude: 37.6, longitude: -122.3),
        ]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] },
            placeID: {
                switch $0.id {
                case "carp": return "Synevyr"
                case let id where id.hasPrefix("ca"): return "San Carlos"
                case "azov1": return "Melekine"
                case "azov2": return "Mariupol"
                case "kyiv": return "Kyiv"
                default: return nil
                }
            },
            support: {
                switch $0.id {
                case "carp": return 69
                case "azov1": return 200
                case "azov2": return 140
                case "kyiv": return 1
                case let id where id.hasPrefix("ca"): return 40
                default: return 8
                }
            })
        let dump = stories.map {
            "\($0.placeID) [\($0.momentIDs.joined(separator: ","))] "
                + $0.stops.map { "\($0.place ?? "?") \(String(format: "%.2f", $0.latitude))" }
                .joined(separator: " → ")
        }.joined(separator: " | ")
        XCTAssertEqual(stories.count, 3, dump)
        let usa = stories.first { $0.momentIDs.contains("ca1") }
        let azov = stories.first { $0.momentIDs.contains("azov1") }
        let carp = stories.first { $0.momentIDs.contains("carp") }
        XCTAssertNotNil(usa, dump)
        XCTAssertNotNil(azov, dump)
        XCTAssertNotNil(carp, dump)
        guard let usa, let azov, let carp else { return }
        XCTAssertTrue(usa.placeID.contains("USA") || usa.placeID.contains("San Carlos"),
                      usa.placeID)
        XCTAssertFalse(usa.placeID.contains("Ukraine") || usa.placeID.contains("Melek")
                       || usa.placeID.contains("Mariupol") || usa.placeID.contains("Synevyr"),
                       usa.placeID)
        XCTAssertFalse(usa.stops.contains { $0.place == "Kyiv" || abs($0.latitude - 50.353) < 0.05 })
        XCTAssertNotEqual(usa.stops.first?.place, "Home in Ukraine")
        XCTAssertTrue(usa.momentIDs.contains("ca3"), usa.momentIDs.joined(separator: ","))
        XCTAssertFalse(usa.momentIDs.contains("azov1") || usa.momentIDs.contains("kyiv")
                       || usa.momentIDs.contains("carp"))
        XCTAssertTrue(azov.placeID.contains("Ukraine") || azov.placeID.contains("Melek")
                      || azov.placeID.contains("Mariupol"), azov.placeID)
        XCTAssertFalse(azov.placeID.contains("Kyiv") || azov.placeID.contains("USA"),
                       azov.placeID)
        XCTAssertFalse(azov.momentIDs.contains("kyiv") || azov.momentIDs.contains("ca1"))
        let azovLegs = JourneyTransportInference.applying(to: azov.stops)
        XCTAssertEqual(azovLegs.dropFirst().first?.transportFromPrevious?.mode, .air, dump)
        XCTAssertEqual(azovLegs.last?.transportFromPrevious?.mode, .air, dump)
        XCTAssertTrue(carp.placeID.contains("Synevyr") || carp.placeID.contains("Ukraine"),
                      carp.placeID)
        XCTAssertEqual(carp.stops.first?.place, "Home in Ukraine")
        XCTAssertEqual(carp.stops.last?.place, "Home in Ukraine")
        let carpLegs = JourneyTransportInference.applying(to: carp.stops)
        XCTAssertTrue(carpLegs.dropFirst().allSatisfy { $0.transportFromPrevious?.mode != .air })
    }

    func testApril2013CaliforniaStayDoesNotTitleBrisbane() {
        let nl = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                 radius: 50)
        let ua = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.80, longitude: 24.02,
                                 radius: 100)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_364_947_200) // 2013-04-03
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("ua-old", stamp(-80)),
            moment("ca1", stamp(0)),
            moment("sf", stamp(3)),
            moment("cruz", stamp(10)),
            moment("ca2", stamp(23)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "ua-old": .init(latitude: 49.80, longitude: 24.02),
            "ca1": .init(latitude: 37.558, longitude: -122.281),
            "sf": .init(latitude: 37.798, longitude: -122.450),
            "cruz": .init(latitude: 36.961, longitude: -122.020),
            "ca2": .init(latitude: 37.559, longitude: -122.277),
        ]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] },
            placeID: { $0.id == "ua-old" ? nil : "Brisbane" },
            support: { $0.id == "cruz" || $0.id == "sf" ? 70 : 12 })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertTrue(stories[0].placeID.contains("USA") || stories[0].placeID.contains("California"),
                      stories[0].placeID)
        XCTAssertFalse(stories[0].placeID.contains("Brisbane"), stories[0].placeID)
        XCTAssertNotEqual(stories[0].stops.first?.place, "Home in Ukraine")
        XCTAssertFalse(stories[0].stops.contains { $0.place == "Brisbane" })
        XCTAssertTrue(PlaceNaming.labelConflictsWithCoordinates("Brisbane", latitude: 37.68, longitude: -122.40))
        XCTAssertFalse(PlaceNaming.labelConflictsWithCoordinates("Brisbane", latitude: -27.47, longitude: 153.03))
    }

    func testJanuary2012SplitsMariupolCarpathiansAndOdesa() {
        let nl = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                 radius: 50)
        let ua = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.80, longitude: 24.02,
                                 radius: 100)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_327_593_600) // 2012-01-26
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("ua-old", stamp(-80)),
            moment("mari1", stamp(0)),
            moment("yare", stamp(24)),
            moment("mari2", stamp(31)),
            moment("odesa", stamp(51)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "ua-old": .init(latitude: 49.80, longitude: 24.02),
            "mari1": .init(latitude: 47.069, longitude: 37.485),
            "yare": .init(latitude: 48.24, longitude: 24.25),
            "mari2": .init(latitude: 47.091, longitude: 37.508),
            "odesa": .init(latitude: 46.48, longitude: 30.768),
        ]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] },
            placeID: {
                switch $0.id {
                case "yare": return "Yaremche"
                case "mari1", "mari2": return "Mariupol"
                case "odesa": return "Odesa"
                default: return nil
                }
            },
            support: {
                switch $0.id {
                case "yare": return 62
                case "odesa": return 17
                case "mari2": return 3
                case "mari1": return 1
                default: return 8
                }
            })
        let dump = stories.map {
            "\($0.placeID) [\($0.momentIDs.joined(separator: ","))]"
        }.joined(separator: " | ")
        let carpathians = stories.first { $0.momentIDs.contains("yare") }
        let mariupol = stories.first { $0.momentIDs.contains("mari2") }
        let odesa = stories.first { $0.momentIDs.contains("odesa") }
        XCTAssertNotNil(carpathians, dump)
        XCTAssertNotNil(mariupol, dump)
        XCTAssertNotNil(odesa, dump)
        guard let carpathians, let mariupol, let odesa else { return }
        XCTAssertFalse(carpathians.momentIDs.contains("mari2") || carpathians.momentIDs.contains("odesa"),
                       dump)
        XCTAssertFalse(mariupol.momentIDs.contains("yare") || mariupol.momentIDs.contains("odesa"), dump)
        XCTAssertFalse(odesa.momentIDs.contains("yare") || odesa.momentIDs.contains("mari2"), dump)
        XCTAssertFalse(carpathians.placeID.contains("Romania") || mariupol.placeID.contains("Romania")
                       || odesa.placeID.contains("Romania"), dump)
        XCTAssertTrue(carpathians.placeID.contains("Yaremche") || carpathians.placeID.contains("Ukraine"),
                      carpathians.placeID)
        XCTAssertTrue(mariupol.placeID.contains("Mariupol") || mariupol.placeID.contains("Ukraine"),
                      mariupol.placeID)
        XCTAssertTrue(odesa.placeID.contains("Odesa") || odesa.placeID.contains("Ukraine"),
                      odesa.placeID)
        XCTAssertEqual(carpathians.stops.first?.place, "Home in Ukraine")
        XCTAssertEqual(carpathians.stops.last?.place, "Home in Ukraine")
    }

    func testWinter2010YaremcheIsLvivSkiTripNotBerlinPoland() {
        let nl = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                 radius: 50)
        let ua = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.80, longitude: 24.02,
                                 radius: 100)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_285_123_200) // 2010-09-22
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("ua-old", stamp(-40)),
            moment("berlin", stamp(0)),
            moment("lviv", stamp(0.2)),
            moment("life1", stamp(20)),
            moment("life2", stamp(60)),
            moment("life3", stamp(100)),
            moment("yare", stamp(129)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "ua-old": .init(latitude: 49.80, longitude: 24.02),
            "berlin": .init(latitude: 52.466, longitude: 13.378),
            "lviv": .init(latitude: 49.832, longitude: 23.999),
            "yare": .init(latitude: 48.247, longitude: 24.228),
        ]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] },
            placeID: {
                switch $0.id {
                case "berlin": return "Berlin"
                case "yare": return "Yaremche"
                default: return nil
                }
            },
            support: {
                switch $0.id {
                case "yare": return 39
                case "berlin": return 4
                case "life1", "life2", "life3": return 80
                default: return 3
                }
            })
        let dump = stories.map {
            "\($0.placeID) [\($0.momentIDs.joined(separator: ","))]"
        }.joined(separator: " | ")
        XCTAssertEqual(stories.count, 1, dump)
        XCTAssertTrue(stories[0].momentIDs.contains("yare"), dump)
        XCTAssertFalse(stories[0].momentIDs.contains("berlin"), dump)
        XCTAssertFalse(stories[0].placeID.contains("Berlin") || stories[0].placeID.contains("Poland")
                       || stories[0].placeID.contains("Romania") || stories[0].placeID.contains("Germany"),
                       stories[0].placeID)
        XCTAssertTrue(stories[0].placeID.contains("Yaremche") || stories[0].placeID.contains("Ukraine"),
                      stories[0].placeID)
        XCTAssertEqual(stories[0].stops.first?.place, "Home in Ukraine")
        XCTAssertEqual(stories[0].stops.last?.place, "Home in Ukraine")
        XCTAssertFalse(stories[0].stops.contains { abs($0.latitude - 52.466) < 0.05 })
    }

    func testJanuary2010YasinyaKeepsVillageTitleAndStartsAtUkraineHome() {
        let nl = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                 radius: 50)
        let ua = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.80, longitude: 24.02,
                                 radius: 100)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_264_809_600) // 2010-01-30
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("ua-old", stamp(-20)),
            moment("yas1", stamp(0)),
            moment("yas2", stamp(2)),
            moment("ua-end", stamp(3)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "ua-old": .init(latitude: 49.80, longitude: 24.02),
            "yas1": .init(latitude: 48.248, longitude: 24.228),
            "yas2": .init(latitude: 48.247, longitude: 24.238),
            "ua-end": .init(latitude: 49.80, longitude: 24.02),
        ]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] },
            placeID: { $0.id.hasPrefix("yas") ? "Yasinians'ka" : nil },
            support: { $0.id.hasPrefix("yas") ? 40 : 6 })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        guard stories.count == 1 else { return }
        XCTAssertTrue(stories[0].placeID.contains("Yasinians") || stories[0].placeID.contains("Yasinya"),
                      stories[0].placeID)
        XCTAssertFalse(stories[0].placeID.contains("Romania") || stories[0].placeID.contains("Netherlands"),
                       stories[0].placeID)
        XCTAssertEqual(stories[0].stops.first?.place, "Home in Ukraine")
        XCTAssertEqual(stories[0].stops.last?.place, "Home in Ukraine")
        let inferred = JourneyTransportInference.applying(to: stories[0].stops)
        XCTAssertTrue(inferred.dropFirst().allSatisfy { $0.transportFromPrevious?.mode != .air })
    }

    func testBarcelonaWeekendKeepsSchipholFlightPhotosAndFlies() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let day: TimeInterval = 86_400
        let moments = [
            moment("home", 0),
            moment("schiphol", 3 * 3600),
            moment("bcn-air", 7 * 3600),
            moment("gaudi", day + 8 * 3600),
            moment("gaudi2", 2 * day),
            moment("home-end", 4 * day),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home": .init(latitude: 52.08, longitude: 4.85),
            "schiphol": .init(latitude: 52.304, longitude: 4.763),
            "bcn-air": .init(latitude: 41.297, longitude: 2.078),
            "gaudi": .init(latitude: 41.403, longitude: 2.174),
            "gaudi2": .init(latitude: 41.403, longitude: 2.174),
            "home-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let places = ["schiphol": "Schiphol", "gaudi": "Barcelona", "gaudi2": "Barcelona"]
        let support = ["home": 10, "schiphol": 15, "bcn-air": 8, "gaudi": 200, "gaudi2": 80, "home-end": 20]
        let stories = JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: { support[$0.id] ?? 1 })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        let stops = stories[0].stops
        XCTAssertTrue(stops.contains { abs($0.latitude - 52.304) < 0.05 },
                      stops.compactMap(\.place).joined(separator: " → "))
        XCTAssertTrue(stops.contains { $0.place == "Barcelona" || abs($0.latitude - 41.40) < 0.15 })
        let toSpain = stops.first { abs($0.latitude - 41.3) < 0.2 }
        XCTAssertEqual(toSpain?.transportFromPrevious?.mode, .air)
        XCTAssertFalse(stories[0].placeID.contains("Netherlands"))
        XCTAssertFalse(stories[0].placeID.contains("Schiphol"))
    }

    func testRhodesDropsSteigraAndFliesFromHome() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let start = Date(timeIntervalSince1970: 1_721_480_000)
        let stops = [
            JourneyStopEvidence(start: start, end: start.addingTimeInterval(25 * 3600),
                latitude: 52.08, longitude: 4.85, momentCount: 1, photoCount: 3,
                place: "Home", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(31 * 3600),
                end: start.addingTimeInterval(32 * 3600),
                latitude: 51.282, longitude: 11.692, momentCount: 1, photoCount: 13,
                place: "Steigra", confidence: 0.6),
            JourneyStopEvidence(start: start.addingTimeInterval(34 * 3600),
                end: start.addingTimeInterval(12 * 86_400),
                latitude: 36.403, longitude: 28.187, momentCount: 20, photoCount: 1639,
                place: "Ialysos", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(12 * 86_400 + 5 * 3600),
                end: start.addingTimeInterval(13 * 86_400),
                latitude: 52.08, longitude: 4.85, momentCount: 4, photoCount: 311,
                place: "Home", confidence: 1),
        ]
        let cleaned = JourneyStopSanitizer.removingRouteNoise(stops, homes: [home])
        XCTAssertFalse(cleaned.contains { $0.place == "Steigra" },
                       cleaned.compactMap(\.place).joined(separator: " → "))
        XCTAssertTrue(cleaned.contains { $0.place == "Ialysos" })
        let inferred = JourneyTransportInference.applying(to: cleaned)
        XCTAssertEqual(inferred[1].transportFromPrevious?.mode, .air)
        XCTAssertEqual(inferred.last?.transportFromPrevious?.mode, .air)
        let title = JourneyStoryBuilder.title(homeLabel: "Home", stops: cleaned)
        XCTAssertFalse(title.contains("Steigra"), title)
        XCTAssertTrue(title.contains("Greece") || title.contains("Ialysos"), title)
    }

    func testItalyRoadTripKeepsGermanStopsStartsAtHomeAndStaysOverland() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_657_968_000) // 2022-07-16
        func stamp(_ offset: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + offset }
        let moments = [
            moment("home0", stamp(0)),
            moment("neustadt", stamp(4 * 3600)),
            moment("munich", stamp(day)),
            moment("achensee", stamp(3 * day)),
            moment("milan", stamp(6 * day)),
            moment("home-end", stamp(10 * day)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home0": .init(latitude: 52.08, longitude: 4.85),
            "neustadt": .init(latitude: 50.599, longitude: 7.433),
            "munich": .init(latitude: 48.14, longitude: 11.58),
            "achensee": .init(latitude: 47.46, longitude: 11.71),
            "milan": .init(latitude: 45.47, longitude: 9.18),
            "home-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let places = [
            "neustadt": "Neustadt (Wied)", "munich": "Munich",
            "achensee": "Eben am Achensee", "milan": "Milan",
        ]
        let support = [
            "home0": 4, "neustadt": 6, "munich": 80, "achensee": 40, "milan": 200, "home-end": 10,
        ]
        let stories = JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: { support[$0.id] ?? 1 })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        let stops = stories[0].stops
        XCTAssertEqual(stops.first?.place, "Home")
        XCTAssertEqual(stops.last?.place, "Home")
        XCTAssertTrue(stops.contains { $0.place?.contains("Neustadt") == true },
                      stops.compactMap(\.place).joined(separator: " → "))
        let inferred = JourneyTransportInference.applying(to: stops)
        XCTAssertTrue(inferred.dropFirst().allSatisfy { $0.transportFromPrevious?.mode != .air },
                      inferred.compactMap { $0.transportFromPrevious?.mode.rawValue }.joined(separator: ","))
        XCTAssertTrue(stories[0].placeID.contains("Italy"), stories[0].placeID)
    }

    func testUkraineHomeCircuitIsOneDriveFromNLAndBack() {
        let nl = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                 radius: 50)
        let ua = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.80, longitude: 24.02,
                                 radius: 100)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_641_300_000) // 2022-01-04
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("ua1", stamp(-2)),
            moment("buk1", stamp(0)),
            moment("buk2", stamp(2)),
            moment("ua2", stamp(3)),
            moment("nl-end", stamp(9)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "ua1": .init(latitude: 49.80, longitude: 24.02),
            "buk1": .init(latitude: 48.36, longitude: 24.41),
            "buk2": .init(latitude: 48.36, longitude: 24.41),
            "ua2": .init(latitude: 49.80, longitude: 24.02),
            "nl-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] },
            placeID: { $0.id.hasPrefix("buk") ? "Буковель" : nil },
            support: { $0.id.hasPrefix("buk") ? 70 : 4 })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        let stops = stories[0].stops
        let places = stops.compactMap(\.place)
        XCTAssertEqual(stops.first?.place, "Home", places.joined(separator: " → "))
        XCTAssertEqual(stops.last?.place, "Home")
        XCTAssertGreaterThanOrEqual(places.filter { $0 == "Home in Ukraine" }.count, 1)
        XCTAssertTrue(places.contains("Буковель"))
        let inferred = JourneyTransportInference.applying(to: stops)
        XCTAssertTrue(inferred.dropFirst().allSatisfy { $0.transportFromPrevious?.mode != .air },
                      inferred.compactMap { $0.transportFromPrevious?.mode.rawValue }.joined(separator: ","))
    }

    func testUkraine2018BukovelAssumesNLStartKeepsIvanoAndStaysOverland() {
        let nl = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                 radius: 50)
        let ua = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.80, longitude: 24.02,
                                 radius: 100)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_514_980_800) // 2018-01-03
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("ua1", stamp(0)),
            moment("buk1", stamp(0.4)),
            moment("buk2", stamp(2)),
            moment("ivano", stamp(3.2)),
            moment("nl-end", stamp(4)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "ua1": .init(latitude: 49.80, longitude: 24.02),
            "buk1": .init(latitude: 48.36, longitude: 24.41),
            "buk2": .init(latitude: 48.36, longitude: 24.41),
            "ivano": .init(latitude: 48.93, longitude: 24.74),
            "nl-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let places = ["buk1": "Буковель", "buk2": "Буковель", "ivano": "Ivano-Frankivsk"]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: {
                if $0.id.hasPrefix("buk") { return 80 }
                if $0.id == "ivano" { return 9 }
                return 8
            })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        let stops = stories[0].stops
        let route = stops.compactMap(\.place).joined(separator: " → ")
        XCTAssertEqual(stops.first?.place, "Home", route)
        XCTAssertEqual(stops.last?.place, "Home", route)
        XCTAssertTrue(stops.contains { $0.place == "Home in Ukraine" }, route)
        XCTAssertTrue(stops.contains { $0.place == "Буковель" }, route)
        XCTAssertTrue(stops.contains { $0.place == "Ivano-Frankivsk" }, route)
        XCTAssertTrue(stories[0].placeID.contains("Ukraine"), stories[0].placeID)
        let inferred = JourneyTransportInference.applying(to: stops)
        XCTAssertTrue(inferred.dropFirst().allSatisfy { $0.transportFromPrevious?.mode != .air },
                      inferred.compactMap { $0.transportFromPrevious?.mode.rawValue }.joined(separator: ","))
    }

    func testHungaryAustriaRoadTripStartsAtUkraineHomeKeepsKosiceAndStaysOverland() {
        let nl = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                 radius: 50)
        let ua = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.80, longitude: 24.02,
                                 radius: 100)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_629_480_000) // 2021-08-20
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("ua1", stamp(-7)),
            moment("ua2", stamp(-3)),
            moment("ua3", stamp(-1)),
            moment("kosice", stamp(0)),
            moment("budapest", stamp(1)),
            moment("vienna", stamp(4)),
            moment("nl-end", stamp(9)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "ua1": .init(latitude: 49.80, longitude: 24.02),
            "ua2": .init(latitude: 49.80, longitude: 24.02),
            "ua3": .init(latitude: 49.80, longitude: 24.02),
            "kosice": .init(latitude: 48.72, longitude: 21.26),
            "budapest": .init(latitude: 47.50, longitude: 19.06),
            "vienna": .init(latitude: 48.21, longitude: 16.38),
            "nl-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let places = ["kosice": "Košice", "budapest": "Budapest", "vienna": "Vienna"]
        let support = [
            "ua1": 8, "ua2": 8, "ua3": 8, "kosice": 40, "budapest": 80, "vienna": 20, "nl-end": 5,
        ]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: { support[$0.id] ?? 1 })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        let stops = stories[0].stops
        let route = stops.compactMap(\.place).joined(separator: " → ")
        XCTAssertEqual(stops.first?.place, "Home in Ukraine", route)
        XCTAssertEqual(stops.last?.place, "Home", route)
        XCTAssertTrue(stops.contains { $0.place == "Košice" }, route)
        let inferred = JourneyTransportInference.applying(to: stops)
        XCTAssertTrue(inferred.dropFirst().allSatisfy { $0.transportFromPrevious?.mode != .air },
                      inferred.compactMap { $0.transportFromPrevious?.mode.rawValue }.joined(separator: ","))
        XCTAssertEqual(JourneyRegionNames.country(latitude: 48.72, longitude: 21.26), "Slovakia")
        XCTAssertTrue(stories[0].placeID.contains("Slovakia") || stories[0].placeID.contains("Hungary"),
                      stories[0].placeID)
    }

    func testFrance2020DriveClosesAtHomeAfterQuietDays() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_596_888_000) // 2020-08-09
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("home0", stamp(0)),
            moment("paris", stamp(1)),
            moment("lyon", stamp(5)),
            moment("pampelonne", stamp(12)),
            moment("home-end", stamp(26)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home0": .init(latitude: 52.08, longitude: 4.85),
            "paris": .init(latitude: 48.86, longitude: 2.33),
            "lyon": .init(latitude: 45.76, longitude: 4.83),
            "pampelonne": .init(latitude: 43.30, longitude: 6.68),
            "home-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let places = ["paris": "Paris", "lyon": "Lyon", "pampelonne": "Pampelonne"]
        let stories = JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: { $0.id.hasPrefix("home") ? 4 : 50 })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertTrue(stories[0].placeID.contains("France"), stories[0].placeID)
        XCTAssertEqual(stories[0].stops.first?.place, "Home")
        XCTAssertEqual(stories[0].stops.last?.place, "Home")
        let inferred = JourneyTransportInference.applying(to: stories[0].stops)
        XCTAssertTrue(inferred.dropFirst().allSatisfy { $0.transportFromPrevious?.mode == .overland },
                      inferred.compactMap { $0.transportFromPrevious?.mode.rawValue }.joined(separator: ","))
    }

    func testBrusselsDriveTitlesBelgiumNotMiniEurope() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_572_084_000) // 2019-10-26
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("home0", stamp(0)),
            moment("mini1", stamp(1)),
            moment("mini2", stamp(3)),
            moment("home-end", stamp(10)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home0": .init(latitude: 52.08, longitude: 4.85),
            "mini1": .init(latitude: 50.86, longitude: 4.36),
            "mini2": .init(latitude: 50.86, longitude: 4.36),
            "home-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let stories = JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] },
            placeID: { $0.id.hasPrefix("mini") ? "Mini-Europe" : nil },
            support: { $0.id.hasPrefix("home") ? 4 : 80 })
        XCTAssertEqual(JourneyRegionNames.country(latitude: 50.86, longitude: 4.36), "Belgium")
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertFalse(stories[0].placeID.contains("Mini-Europe"), stories[0].placeID)
        XCTAssertTrue(stories[0].placeID.contains("Belgium") || stories[0].placeID.contains("Brussels"),
                      stories[0].placeID)
        XCTAssertEqual(stories[0].stops.first?.place, "Home")
        XCTAssertEqual(stories[0].stops.last?.place, "Home")
        let inferred = JourneyTransportInference.applying(to: stories[0].stops)
        XCTAssertTrue(inferred.dropFirst().allSatisfy { $0.transportFromPrevious?.mode == .overland },
                      inferred.compactMap { $0.transportFromPrevious?.mode.rawValue }.joined(separator: ","))
    }

    func testLondonSchoolVisitFliesAndTitlesUnitedKingdom() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_561_316_000) // 2019-06-23
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("home0", stamp(0)),
            moment("school", stamp(0.4)),
            moment("school2", stamp(2)),
            moment("home-end", stamp(2.7)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home0": .init(latitude: 52.08, longitude: 4.85),
            "school": .init(latitude: 51.517, longitude: -0.106),
            "school2": .init(latitude: 51.517, longitude: -0.106),
            "home-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let stories = JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] },
            placeID: { $0.id.hasPrefix("school") ? "City of London School" : nil },
            support: { $0.id.hasPrefix("home") ? 8 : 26 })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertFalse(stories[0].placeID.contains("School"), stories[0].placeID)
        XCTAssertTrue(stories[0].placeID.contains("United Kingdom") || stories[0].placeID.contains("London"),
                      stories[0].placeID)
        XCTAssertEqual(stories[0].stops.first?.place, "Home")
        XCTAssertEqual(stories[0].stops.last?.place, "Home")
        let inferred = JourneyTransportInference.applying(to: stories[0].stops)
        XCTAssertTrue(inferred.dropFirst().allSatisfy { $0.transportFromPrevious?.mode == .air },
                      inferred.compactMap { $0.transportFromPrevious?.mode.rawValue }.joined(separator: ","))
        XCTAssertTrue(PlaceNaming.looksLandmarkOrTransit("City of London School"))
    }

    func testBarcelonaChurchVisitFliesAndTitlesSpain() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_541_318_000) // 2018-11-04
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("home0", stamp(0)),
            moment("temple", stamp(0.3)),
            moment("temple2", stamp(4)),
            moment("home-end", stamp(4.35)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home0": .init(latitude: 52.08, longitude: 4.85),
            "temple": .init(latitude: 41.388, longitude: 2.156),
            "temple2": .init(latitude: 41.388, longitude: 2.156),
            "home-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let stories = JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] },
            placeID: { $0.id.hasPrefix("temple") ? "Temple of the Sacred Heart of Jesus" : nil },
            support: { $0.id.hasPrefix("home") ? 4 : 80 })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertFalse(stories[0].placeID.contains("Temple"), stories[0].placeID)
        XCTAssertFalse(stories[0].placeID.contains("Sacred Heart"), stories[0].placeID)
        XCTAssertTrue(stories[0].placeID.contains("Spain") || stories[0].placeID.contains("Barcelona"),
                      stories[0].placeID)
        XCTAssertEqual(stories[0].stops.first?.place, "Home")
        XCTAssertEqual(stories[0].stops.last?.place, "Home")
        let inferred = JourneyTransportInference.applying(to: stories[0].stops)
        XCTAssertTrue(inferred.dropFirst().allSatisfy { $0.transportFromPrevious?.mode == .air },
                      inferred.compactMap { $0.transportFromPrevious?.mode.rawValue }.joined(separator: ","))
        XCTAssertTrue(PlaceNaming.looksLandmarkOrTransit("Temple of the Sacred Heart of Jesus"))
    }

    func testUkraine2018BerlinAndPylypetsStayOneOverlandCircuit() {
        let nl = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                 radius: 50)
        let ua = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.80, longitude: 24.02,
                                 radius: 100)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_532_520_000) // 2018-07-25
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("nl0", stamp(0)),
            moment("berlin", stamp(0.4)),
            moment("berlin2", stamp(1.5)),
            moment("ua1", stamp(2)),
            moment("dslr1", stamp(10)),
            moment("dslr2", stamp(18)),
            moment("pylypets", stamp(23)),
            moment("pylypets2", stamp(30)),
            moment("nl-end", stamp(35)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "nl0": .init(latitude: 52.08, longitude: 4.85),
            "berlin": .init(latitude: 52.45, longitude: 13.48),
            "berlin2": .init(latitude: 52.45, longitude: 13.48),
            "ua1": .init(latitude: 49.80, longitude: 24.02),
            "pylypets": .init(latitude: 48.67, longitude: 23.35),
            "pylypets2": .init(latitude: 48.67, longitude: 23.35),
            "nl-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let places = ["berlin": "Berlin", "berlin2": "Berlin", "pylypets": "Pylypets'ka",
                      "pylypets2": "Pylypets'ka"]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: {
                if $0.id.hasPrefix("pylypets") { return 80 }
                if $0.id.hasPrefix("berlin") { return 14 }
                return 6
            })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertTrue(stories[0].placeID.contains("Germany") || stories[0].placeID.contains("Berlin"),
                      stories[0].placeID)
        XCTAssertTrue(stories[0].placeID.contains("Ukraine") || stories[0].placeID.contains("Pylypets"),
                      stories[0].placeID)
        XCTAssertEqual(stories[0].stops.first?.place, "Home")
        XCTAssertEqual(stories[0].stops.last?.place, "Home")
        XCTAssertTrue(stories[0].stops.contains { $0.place == "Berlin" })
        XCTAssertTrue(stories[0].stops.contains { $0.place == "Pylypets'ka" || $0.place == "Home in Ukraine" })
        let inferred = JourneyTransportInference.applying(to: stories[0].stops)
        XCTAssertTrue(inferred.dropFirst().allSatisfy { $0.transportFromPrevious?.mode != .air },
                      inferred.compactMap { $0.transportFromPrevious?.mode.rawValue }.joined(separator: ","))
    }

    func testUkraine2019CarpathiansAndBerlinStayOneOverlandCircuit() {
        let nl = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                 radius: 50)
        let ua = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.80, longitude: 24.02,
                                 radius: 100)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_563_667_200) // 2019-07-20
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("ua0", stamp(0)),
            moment("ua0b", stamp(4)),
            moment("ua0c", stamp(7)),
            moment("carpath1", stamp(9)),
            moment("synevyr", stamp(11)),
            moment("carpath2", stamp(14)),
            moment("approach1", stamp(14.3)),
            moment("ua1", stamp(14.5)),
            moment("carpath3", stamp(25)),
            moment("skole", stamp(27)),
            moment("carpath4", stamp(28)),
            moment("ua2", stamp(28.4)),
            moment("ua3", stamp(40)),
            moment("berlin", stamp(40.4)),
            moment("nl-end", stamp(42)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "ua0": .init(latitude: 49.80, longitude: 24.02),
            "ua0b": .init(latitude: 49.80, longitude: 24.02),
            "ua0c": .init(latitude: 49.80, longitude: 24.02),
            "carpath1": .init(latitude: 48.83, longitude: 23.46),
            "synevyr": .init(latitude: 48.58, longitude: 23.65),
            "carpath2": .init(latitude: 48.85, longitude: 23.46),
            "approach1": .init(latitude: 49.45, longitude: 23.85),
            "ua1": .init(latitude: 49.80, longitude: 24.02),
            "carpath3": .init(latitude: 48.83, longitude: 23.46),
            "skole": .init(latitude: 49.19, longitude: 23.41),
            "carpath4": .init(latitude: 48.85, longitude: 23.46),
            "ua2": .init(latitude: 49.80, longitude: 24.02),
            "ua3": .init(latitude: 49.80, longitude: 24.02),
            "berlin": .init(latitude: 52.47, longitude: 13.49),
            "nl-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let places = [
            "carpath1": "Олени Степанівни вулиця",
            "carpath2": "Олени Степанівни вулиця",
            "carpath3": "Олени Степанівни вулиця",
            "carpath4": "Олени Степанівни вулиця",
            "synevyr": "National Natural Park “Synevyr”",
            "skole": "Skolivs'ka",
            "berlin": "Berlin",
        ]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: {
                if $0.id.hasPrefix("ua") || $0.id.hasPrefix("nl") || $0.id.hasPrefix("approach") {
                    return 6
                }
                return $0.id == "berlin" ? 22 : 80
            })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertTrue(stories[0].placeID.contains("Ukraine"), stories[0].placeID)
        XCTAssertTrue(stories[0].placeID.contains("Germany") || stories[0].placeID.contains("Berlin"),
                      stories[0].placeID)
        XCTAssertFalse(stories[0].placeID.contains("вулиця"), stories[0].placeID)
        XCTAssertFalse(stories[0].placeID.contains("Synevyr"), stories[0].placeID)
        XCTAssertEqual(stories[0].stops.first?.place, "Home in Ukraine")
        XCTAssertEqual(stories[0].stops.last?.place, "Home")
        XCTAssertTrue(stories[0].stops.contains { $0.place == "Berlin" })
        let inferred = JourneyTransportInference.applying(to: stories[0].stops)
        XCTAssertTrue(inferred.dropFirst().allSatisfy { $0.transportFromPrevious?.mode != .air },
                      inferred.compactMap { $0.transportFromPrevious?.mode.rawValue }.joined(separator: ","))
    }

    func testSummer2021RoadTripStaysOpenAcrossUkraineHome() {
        let nl = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                 radius: 50)
        let ua = MeaningfulPlace(label: "Home in Ukraine", address: "UA", latitude: 49.80, longitude: 24.02,
                                 radius: 100)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_626_480_000) // 2021-07-17
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("nl0", stamp(0)),
            moment("dresden", stamp(1)),
            moment("prague", stamp(3)),
            moment("krakow", stamp(4)),
            moment("ua1", stamp(7)),
            moment("ua2", stamp(14)),
            moment("ua3", stamp(21)),
            moment("ua4", stamp(28)),
            moment("kosice", stamp(35)),
            moment("budapest", stamp(36)),
            moment("vienna", stamp(40)),
            moment("nl-end", stamp(44)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "nl0": .init(latitude: 52.08, longitude: 4.85),
            "dresden": .init(latitude: 51.05, longitude: 13.74),
            "prague": .init(latitude: 50.09, longitude: 14.41),
            "krakow": .init(latitude: 50.06, longitude: 19.93),
            "ua1": .init(latitude: 49.80, longitude: 24.02),
            "ua2": .init(latitude: 49.80, longitude: 24.02),
            "ua3": .init(latitude: 49.80, longitude: 24.02),
            "ua4": .init(latitude: 49.80, longitude: 24.02),
            "kosice": .init(latitude: 48.72, longitude: 21.26),
            "budapest": .init(latitude: 47.50, longitude: 19.06),
            "vienna": .init(latitude: 48.21, longitude: 16.38),
            "nl-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let places = [
            "dresden": "Dresden", "prague": "Prague", "krakow": "Kraków",
            "kosice": "Košice", "budapest": "Budapest", "vienna": "Vienna",
        ]
        let stories = JourneyStoryBuilder.stories(moments, homes: [nl, ua],
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: { $0.id.hasPrefix("ua") || $0.id.hasPrefix("nl") ? 6 : 40 })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        let route = stories[0].stops.compactMap(\.place).joined(separator: " → ")
        XCTAssertTrue(route.contains("Dresden"), route)
        XCTAssertTrue(route.contains("Košice") || route.contains("Budapest"), route)
        XCTAssertEqual(stories[0].stops.last?.place, "Home")
        let inferred = JourneyTransportInference.applying(to: stories[0].stops)
        XCTAssertTrue(inferred.dropFirst().allSatisfy { $0.transportFromPrevious?.mode != .air },
                      inferred.compactMap { $0.transportFromPrevious?.mode.rawValue }.joined(separator: ","))
    }

    func testCreteSummerClosesAtHomeAfterQuietDaysAndTitlesIsland() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let day: TimeInterval = 86_400
        let origin = Date(timeIntervalSince1970: 1_689_066_000) // 2023-07-11
        func stamp(_ days: TimeInterval) -> TimeInterval { origin.timeIntervalSince1970 + days * day }
        let moments = [
            moment("home0", stamp(-5)),
            moment("crete1", stamp(0)),
            moment("crete2", stamp(4)),
            moment("crete3", stamp(8)),
            moment("crete4", stamp(12)),
            moment("home-end", stamp(23)),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home0": .init(latitude: 52.08, longitude: 4.85),
            "crete1": .init(latitude: 35.556, longitude: 23.734),
            "crete2": .init(latitude: 35.52, longitude: 23.91),
            "crete3": .init(latitude: 35.54, longitude: 23.80),
            "crete4": .init(latitude: 35.51, longitude: 23.89),
            "home-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let stories = JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] },
            placeID: { $0.id.hasPrefix("crete") ? "Ravdoucha" : nil },
            support: { $0.id.hasPrefix("crete") ? 50 : 3 })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: ", "))
        XCTAssertEqual(stories[0].placeID, "Summer holidays in Crete")
        let stops = stories[0].stops
        XCTAssertEqual(stops.first?.place, "Home")
        XCTAssertEqual(stops.last?.place, "Home")
        XCTAssertGreaterThanOrEqual(stops.count, 3)
        let inferred = JourneyTransportInference.applying(to: stops)
        let route = inferred.map { "\($0.place ?? "?") \($0.transportFromPrevious?.mode.rawValue ?? "-")" }
            .joined(separator: " → ")
        XCTAssertTrue(inferred.contains { $0.place != "Home" && $0.transportFromPrevious?.mode == .air }, route)
        XCTAssertEqual(inferred.last?.transportFromPrevious?.mode, .air, route)
        XCTAssertEqual(JourneyRegionNames.country(latitude: 35.556, longitude: 23.734), "Crete")
    }

    func testAmericasKeepsDetroitAndAtlantaAirConnections() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let start = Date(timeIntervalSince1970: 1_764_700_000)
        let stops = [
            JourneyStopEvidence(start: start, end: start, latitude: 52.08, longitude: 4.85,
                momentCount: 1, photoCount: 3, place: "Home", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(11 * 3600),
                end: start.addingTimeInterval(11 * 3600),
                latitude: 42.21, longitude: -83.36, momentCount: 1, photoCount: 1,
                place: nil, confidence: 0.5),
            JourneyStopEvidence(start: start.addingTimeInterval(14 * 3600),
                end: start.addingTimeInterval(4 * 86_400),
                latitude: 42.96, longitude: -85.67, momentCount: 8, photoCount: 27,
                place: "Grand Rapids", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(6 * 86_400),
                end: start.addingTimeInterval(6 * 86_400),
                latitude: 33.64, longitude: -84.43, momentCount: 1, photoCount: 1,
                place: nil, confidence: 0.5),
            JourneyStopEvidence(start: start.addingTimeInterval(6 * 86_400 + 8 * 3600),
                end: start.addingTimeInterval(10 * 86_400),
                latitude: 9.51, longitude: -78.90, momentCount: 6, photoCount: 184,
                place: "San Blas", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(11 * 86_400),
                end: start.addingTimeInterval(11 * 86_400),
                latitude: 52.08, longitude: 4.85, momentCount: 1, photoCount: 8,
                place: "Home", confidence: 1),
        ]
        let cleaned = JourneyStopSanitizer.removingRouteNoise(stops, homes: [home])
        XCTAssertTrue(cleaned.contains { abs($0.latitude - 42.21) < 0.05 },
                      cleaned.compactMap(\.place).joined(separator: " → "))
        XCTAssertTrue(cleaned.contains { abs($0.latitude - 33.64) < 0.05 })
        XCTAssertTrue(cleaned.contains { $0.place == "Grand Rapids" })
        XCTAssertTrue(cleaned.contains { $0.place == "San Blas" })
    }

    func testIrelandDropsWarringtonAndFliesHome() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let start = Date(timeIntervalSince1970: 1_759_300_000)
        let stops = [
            JourneyStopEvidence(start: start, end: start, latitude: 52.08, longitude: 4.85,
                momentCount: 1, photoCount: 2, place: "Home", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(3 * 3600),
                end: start.addingTimeInterval(3 * 86_400),
                latitude: 53.35, longitude: -6.25, momentCount: 10, photoCount: 122,
                place: "Trinity College Dublin", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(3 * 86_400 + 7 * 3600),
                end: start.addingTimeInterval(3 * 86_400 + 7 * 3600),
                latitude: 53.37, longitude: -2.62, momentCount: 1, photoCount: 2,
                place: "Warrington", confidence: 0.5),
            JourneyStopEvidence(start: start.addingTimeInterval(5 * 86_400),
                end: start.addingTimeInterval(5 * 86_400),
                latitude: 52.08, longitude: 4.85, momentCount: 1, photoCount: 7,
                place: "Home", confidence: 1),
        ]
        let cleaned = JourneyStopSanitizer.removingRouteNoise(stops, homes: [home])
        XCTAssertFalse(cleaned.contains { $0.place == "Warrington" },
                       cleaned.compactMap(\.place).joined(separator: " → "))
        let inferred = JourneyTransportInference.applying(to: cleaned)
        XCTAssertEqual(inferred.last?.transportFromPrevious?.mode, .air)
    }

    func testPortugalGreeceCircuitFliesEachLegAndTitlesCountries() {
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let start = Date(timeIntervalSince1970: 1_751_050_000)
        let stops = [
            JourneyStopEvidence(start: start, end: start.addingTimeInterval(8 * 3600),
                latitude: 52.08, longitude: 4.85, momentCount: 2, photoCount: 10,
                place: "Home", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(2 * 86_400),
                end: start.addingTimeInterval(4 * 86_400),
                latitude: 38.673, longitude: -9.214, momentCount: 8, photoCount: 81,
                place: "Caparica", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(4 * 86_400 + 6 * 3600),
                end: start.addingTimeInterval(4 * 86_400 + 6 * 3600),
                latitude: 37.176, longitude: 23.145, momentCount: 1, photoCount: 6,
                place: "Greece", confidence: 0.6),
            JourneyStopEvidence(start: start.addingTimeInterval(4 * 86_400 + 14 * 3600),
                end: start.addingTimeInterval(6 * 86_400),
                latitude: 37.97, longitude: 23.75, momentCount: 3, photoCount: 17,
                place: "Athens", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(6 * 86_400 + 11 * 3600),
                end: start.addingTimeInterval(7 * 86_400),
                latitude: 52.08, longitude: 4.85, momentCount: 2, photoCount: 20,
                place: "Home", confidence: 1),
        ]
        let inferred = JourneyTransportInference.applying(to: stops)
        XCTAssertEqual(inferred[1].transportFromPrevious?.mode, .air, "Home → Portugal")
        XCTAssertEqual(inferred[2].transportFromPrevious?.mode, .air, "Portugal → Greece")
        XCTAssertEqual(inferred[4].transportFromPrevious?.mode, .air, "Athens → Home")
        XCTAssertEqual(JourneyRegionNames.country(latitude: 38.673, longitude: -9.214), "Portugal")
        XCTAssertEqual(JourneyStoryBuilder.title(homeLabel: "Home", stops: inferred),
                       "Journey to Portugal and Greece in 2025")
        let cleaned = JourneyStopSanitizer.removingRouteNoise(stops, homes: [home])
        XCTAssertTrue(cleaned.contains { $0.place == "Caparica" })
        XCTAssertTrue(cleaned.contains { $0.place == "Athens" })
    }

    func testAmericasMultiStopNotSplitByParallelHomePhotos() {
        // Owner pattern Dec 2025: Grand Rapids, thin NL Home geofence shots, then Panama
        // ~2 days later — one transatlantic circuit, not two round-trips.
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        func rich(_ id: String, _ time: TimeInterval, count: Int) -> PhotoMoment {
            let photos = (0..<count).map { photo("\(id)-\($0)", time + Double($0)) }
            return PhotoMoment(id: id, start: Date(timeIntervalSince1970: time),
                               end: Date(timeIntervalSince1970: time + Double(max(0, count - 1))),
                               photos: photos)
        }
        let day: TimeInterval = 86_400
        let moments = [
            rich("home0", 0, count: 4),
            rich("gr1", day, count: 6),
            rich("gr2", 2 * day, count: 5),
            rich("home-thin", 2 * day + 14 * 3600, count: 1), // Dec 7 afternoon geofence
            rich("gr3", 2 * day + 19 * 3600, count: 2),
            rich("home-thin2", 2 * day + 21 * 3600, count: 2),
            rich("home-day", 3 * day, count: 2),
            rich("gr4", 4 * day + 7 * 3600, count: 4), // still Michigan next morning
            rich("atl", 4 * day + 15 * 3600, count: 1),
            rich("panama1", 4 * day + 20 * 3600, count: 8),
            rich("panama2", 5 * day, count: 40),
            rich("home-back", 7 * day, count: 5)
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home0": .init(latitude: 52.08, longitude: 4.85),
            "gr1": .init(latitude: 42.96, longitude: -85.67),
            "gr2": .init(latitude: 42.96, longitude: -85.67),
            "home-thin": .init(latitude: 52.08, longitude: 4.85),
            "gr3": .init(latitude: 42.92, longitude: -85.59),
            "home-thin2": .init(latitude: 52.08, longitude: 4.85),
            "home-day": .init(latitude: 52.08, longitude: 4.85),
            "gr4": .init(latitude: 42.97, longitude: -85.67),
            "atl": .init(latitude: 33.64, longitude: -84.43),
            "panama1": .init(latitude: 9.07, longitude: -79.39),
            "panama2": .init(latitude: 9.51, longitude: -78.90),
            "home-back": .init(latitude: 52.08, longitude: 4.85),
        ]
        let places = ["gr1": "Grand Rapids", "gr2": "Grand Rapids", "gr3": "Grand Rapids",
                      "gr4": "Grand Rapids", "atl": "Atlanta", "panama1": "Panama City",
                      "panama2": "San Blas"]
        let stories = JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: { $0.photos.count })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: " | "))
        let ids = Set(stories[0].momentIDs)
        XCTAssertTrue(ids.contains("gr1"))
        XCTAssertTrue(ids.contains("panama2"))
        XCTAssertFalse(ids.contains("home-thin"))
        XCTAssertTrue(stories[0].placeID.contains("Americas")
                      || stories[0].placeID.contains("USA")
                      || stories[0].placeID.contains("Panama")
                      || stories[0].placeID.contains("Grand Rapids")
                      || stories[0].placeID.contains("San Blas"),
                      stories[0].placeID)
    }

    func testAmericasThickHomeOrbitLayoverDoesNotSplitCircuit() {
        // Live Dec 2025 pattern: dense NL Home Moments (other phone / geofence spill) between
        // Michigan and Panama — still one Journey titled around USA / Panama.
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        func rich(_ id: String, _ time: TimeInterval, count: Int) -> PhotoMoment {
            let photos = (0..<count).map { photo("\(id)-\($0)", time + Double($0)) }
            return PhotoMoment(id: id, start: Date(timeIntervalSince1970: time),
                               end: Date(timeIntervalSince1970: time + Double(max(0, count - 1))),
                               photos: photos)
        }
        let day: TimeInterval = 86_400
        let moments = [
            rich("home0", 0, count: 6),
            rich("gr1", day, count: 20),
            rich("gr2", 2 * day, count: 30),
            rich("home-thick", 2 * day + 20 * 3600, count: 16), // outside 50m geofence, in orbit
            rich("home-thick2", 3 * day + 12 * 3600, count: 13),
            rich("panama1", 3 * day + 20 * 3600, count: 40),
            rich("panama2", 5 * day, count: 80),
            rich("home-back", 8 * day, count: 8)
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home0": .init(latitude: 52.08, longitude: 4.85),
            "gr1": .init(latitude: 42.96, longitude: -85.67),
            "gr2": .init(latitude: 42.96, longitude: -85.67),
            // ~2 km from Home pin — outside 50m geofence, still near-pin layover.
            "home-thick": .init(latitude: 52.09, longitude: 4.87),
            "home-thick2": .init(latitude: 52.10, longitude: 4.86),
            "panama1": .init(latitude: 9.07, longitude: -79.39),
            "panama2": .init(latitude: 9.51, longitude: -78.90),
            "home-back": .init(latitude: 52.08, longitude: 4.85),
        ]
        let places = ["gr1": "Grand Rapids", "gr2": "Grand Rapids",
                      "panama1": "Panama City", "panama2": "San Blas"]
        let stories = JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: { $0.photos.count })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: " | "))
        XCTAssertTrue(Set(stories[0].momentIDs).isSuperset(of: ["gr1", "panama2"]))
        XCTAssertTrue(stories[0].placeID.contains("Americas"), stories[0].placeID)
        let routePlaces = stories[0].stops.compactMap(\.place)
        XCTAssertEqual(routePlaces.filter { $0 == "Home" }.count, 2,
                       "Home only as start/end: \(routePlaces)")
        XCTAssertFalse(routePlaces.dropFirst().dropLast().contains("Home"),
                       routePlaces.joined(separator: " → "))
    }

    func testSanBlasPanamaColombiaOverlapTitlesAmericas() {
        let start = Date(timeIntervalSince1970: 1_765_000_000)
        let stops = [
            JourneyStopEvidence(start: start, end: start, latitude: 52.08, longitude: 4.85,
                momentCount: 1, photoCount: 8, place: "Home", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(86_400),
                end: start.addingTimeInterval(2 * 86_400),
                latitude: 42.96, longitude: -85.67, momentCount: 4, photoCount: 40,
                place: "Grand Rapids", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(3 * 86_400),
                end: start.addingTimeInterval(4 * 86_400),
                latitude: 9.51, longitude: -78.90, momentCount: 6, photoCount: 184,
                place: "San Blas", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(5 * 86_400),
                end: start.addingTimeInterval(6 * 86_400),
                latitude: 9.00, longitude: -79.50, momentCount: 3, photoCount: 27,
                place: "Panama City", confidence: 1),
            JourneyStopEvidence(start: start.addingTimeInterval(7 * 86_400),
                end: start.addingTimeInterval(7 * 86_400),
                latitude: 52.08, longitude: 4.85, momentCount: 1, photoCount: 8,
                place: "Home", confidence: 1),
        ]
        let title = JourneyStoryBuilder.title(homeLabel: "Home", stops: stops)
        XCTAssertEqual(title, "Journey to Americas in 2025", title)
        XCTAssertEqual(JourneyRegionNames.country(latitude: 9.51, longitude: -78.90), "Panama")
    }

    func testReturnHomeAfterPanamaClosesCircuitWithThinHomePing() {
        // Traveler sense: last abroad stop in Panama, next located Moment is Home —
        // draw Panama → Home even when that first Home Moment is a single photo.
        let home = MeaningfulPlace(label: "Home", address: "NL", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        func rich(_ id: String, _ time: TimeInterval, count: Int) -> PhotoMoment {
            let photos = (0..<count).map { photo("\(id)-\($0)", time + Double($0)) }
            return PhotoMoment(id: id, start: Date(timeIntervalSince1970: time),
                               end: Date(timeIntervalSince1970: time + Double(max(0, count - 1))),
                               photos: photos)
        }
        let day: TimeInterval = 86_400
        let moments = [
            rich("home0", 0, count: 4),
            rich("gr1", day, count: 20),
            rich("panama", 3 * day, count: 40),
            rich("panama2", 5 * day, count: 30),
            rich("home-thin", 7 * day, count: 1), // first unlock at Home
            rich("home-later", 10 * day, count: 3),
        ]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home0": .init(latitude: 52.08, longitude: 4.85),
            "gr1": .init(latitude: 42.96, longitude: -85.67),
            "panama": .init(latitude: 9.07, longitude: -79.39),
            "panama2": .init(latitude: 9.51, longitude: -78.90),
            "home-thin": .init(latitude: 52.08, longitude: 4.85),
            "home-later": .init(latitude: 52.09, longitude: 4.86),
        ]
        let places = ["gr1": "Grand Rapids", "panama": "Panama City", "panama2": "San Blas"]
        let stories = JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] }, placeID: { places[$0.id] },
            support: { $0.photos.count })
        XCTAssertEqual(stories.count, 1, stories.map(\.placeID).joined(separator: " | "))
        let route = stories[0].stops.compactMap(\.place)
        XCTAssertEqual(route.first, "Home", route.joined(separator: " → "))
        XCTAssertEqual(route.last, "Home", route.joined(separator: " → "))
        XCTAssertFalse(route.dropFirst().dropLast().contains("Home"), route.joined(separator: " → "))
        // Outbound via Michigan, return direct to Home — never Home← via Grand Rapids.
        XCTAssertTrue(route.contains("Grand Rapids"))
        let lastAway = route.lastIndex { $0 != "Home" }
        XCTAssertNotNil(lastAway)
        XCTAssertEqual(route[route.index(after: lastAway!)], "Home")
    }

    func testMergedJourneysStripInteriorHomeAnchors() {
        let start = Date(timeIntervalSince1970: 1_765_000_000)
        let legA = CurationStory(id: "a", start: start, end: start.addingTimeInterval(2 * 86_400),
            momentIDs: ["m1", "m2"], placeID: "Journey to USA", kind: .journey, stops: [
                JourneyStopEvidence(start: start, end: start, latitude: 52.08, longitude: 4.85,
                    momentCount: 1, photoCount: 8, place: "Home", confidence: 1),
                JourneyStopEvidence(start: start.addingTimeInterval(86_400),
                    end: start.addingTimeInterval(2 * 86_400),
                    latitude: 42.96, longitude: -85.67, momentCount: 2, photoCount: 40,
                    place: "Grand Rapids", confidence: 1),
                JourneyStopEvidence(start: start.addingTimeInterval(2 * 86_400),
                    end: start.addingTimeInterval(2 * 86_400),
                    latitude: 52.08, longitude: 4.85, momentCount: 1, photoCount: 16,
                    place: "Home", confidence: 1),
            ])
        let legB = CurationStory(id: "b",
            start: start.addingTimeInterval(3 * 86_400),
            end: start.addingTimeInterval(6 * 86_400),
            momentIDs: ["m3", "m4"], placeID: "Journey to Panama", kind: .journey, stops: [
                JourneyStopEvidence(start: start.addingTimeInterval(3 * 86_400),
                    end: start.addingTimeInterval(3 * 86_400),
                    latitude: 52.08, longitude: 4.85, momentCount: 1, photoCount: 13,
                    place: "Home", confidence: 1),
                JourneyStopEvidence(start: start.addingTimeInterval(4 * 86_400),
                    end: start.addingTimeInterval(5 * 86_400),
                    latitude: 9.51, longitude: -78.90, momentCount: 3, photoCount: 100,
                    place: "San Blas", confidence: 1),
                JourneyStopEvidence(start: start.addingTimeInterval(6 * 86_400),
                    end: start.addingTimeInterval(6 * 86_400),
                    latitude: 52.08, longitude: 4.85, momentCount: 1, photoCount: 8,
                    place: "Home", confidence: 1),
            ])
        let merge = JourneyMergeRecord(id: "merged", momentIDs: ["m1", "m2", "m3", "m4"],
                                       title: "Journey to USA")
        let out = JourneyMergePlan.applying([legA, legB], merges: [merge])
        XCTAssertEqual(out.count, 1)
        let places = out[0].stops.compactMap(\.place)
        XCTAssertEqual(places.filter { $0 == "Home" }.count, 2, places.joined(separator: " → "))
        XCTAssertTrue(places.contains("Grand Rapids"))
        XCTAssertTrue(places.contains("San Blas"))
        XCTAssertFalse(places.dropFirst().dropLast().contains("Home"), places.joined(separator: " → "))
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
        let routePlaces = story?.stops.compactMap(\.place) ?? []
        XCTAssertTrue(routePlaces.contains("Fréjus") || routePlaces.contains(where: { $0.contains("Fréjus") }),
                      routePlaces.joined(separator: " → "))
        XCTAssertFalse(routePlaces.contains("Lviv"), routePlaces.joined(separator: " → "))
        // Thin Home return after the trip may close the circuit (1 photo is enough).
        XCTAssertEqual(routePlaces.last, "Home")
    }

    func testLocalOrbitOutingsDoNotBecomeJourneysOrGlueTrips() {
        let home = MeaningfulPlace(label: "Home", address: "Home", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        // Zundert / Breda / Reeuwijk style: busy regional days, never true travel.
        let regional = [
            moment("home", 0),
            moment("zundert", 86_400),
            moment("breda", 2 * 86_400),
            moment("reeuwijk", 3 * 86_400),
            moment("home-after", 4 * 86_400),
        ]
        let regionalCoords: [String: CLLocationCoordinate2D] = [
            "home": .init(latitude: 52.08, longitude: 4.85),
            "zundert": .init(latitude: 51.47, longitude: 4.66),
            "breda": .init(latitude: 51.59, longitude: 4.77),
            "reeuwijk": .init(latitude: 52.04, longitude: 4.73),
            "home-after": .init(latitude: 52.08, longitude: 4.85),
        ]
        XCTAssertTrue(JourneyStoryBuilder.stories(regional, home: home,
            coordinate: { regionalCoords[$0.id] },
            placeID: { ["zundert": "Zundert", "breda": "Breda", "reeuwijk": "Reeuwijk"][$0.id] },
            support: { $0.id == "zundert" ? 394 : 20 }).isEmpty)

        // Greece trip must not keep an IJsselstein evening show as a titled stop, and a later
        // Bucharest trip must not merge after returning to the Dutch Home orbit.
        let split = [
            moment("home-0", 0),
            moment("ijsselstein", 86_400),
            moment("greece-1", 3 * 86_400),
            moment("greece-2", 5 * 86_400),
            moment("badhoevedorp", 8 * 86_400),
            moment("bucharest-1", 10 * 86_400),
            moment("bucharest-2", 12 * 86_400),
            moment("home-end", 14 * 86_400),
        ]
        let splitCoords: [String: CLLocationCoordinate2D] = [
            "home-0": .init(latitude: 52.08, longitude: 4.85),
            "ijsselstein": .init(latitude: 52.02, longitude: 5.04),
            "greece-1": .init(latitude: 37.97, longitude: 23.73),
            "greece-2": .init(latitude: 37.98, longitude: 23.75),
            "badhoevedorp": .init(latitude: 52.33, longitude: 4.80),
            "bucharest-1": .init(latitude: 44.43, longitude: 26.10),
            "bucharest-2": .init(latitude: 44.45, longitude: 26.12),
            "home-end": .init(latitude: 52.08, longitude: 4.85),
        ]
        let places = [
            "ijsselstein": "IJsselstein", "greece-1": "Greece", "greece-2": "Agia Marina",
            "badhoevedorp": "Badhoevedorp", "bucharest-1": "Bucharest", "bucharest-2": "Bucharest",
        ]
        let support = [
            "ijsselstein": 50, "greece-1": 40, "greece-2": 20,
            "badhoevedorp": 4, "bucharest-1": 12, "bucharest-2": 10,
        ]
        let stories = JourneyStoryBuilder.stories(split, home: home,
            coordinate: { splitCoords[$0.id] }, placeID: { places[$0.id] },
            support: { support[$0.id] ?? 1 })
        XCTAssertEqual(stories.count, 2)
        XCTAssertEqual(Set(stories.map(\.placeID)),
                       Set(["Journey to Greece", "Journey to Bucharest"]))
        XCTAssertFalse(stories.contains { $0.placeID.contains("IJsselstein") })
        XCTAssertFalse(stories.contains { $0.placeID.contains("Badhoevedorp") })
        XCTAssertFalse(stories.contains { $0.placeID.contains("Agia Marina") })
    }

    func testThinAbroadPingPlusLocalOutingIsNotAJourney() {
        let home = MeaningfulPlace(label: "Home", address: "Home", latitude: 52.08, longitude: 4.85,
                                   radius: 50)
        let moments = [moment("home", 0), moment("rhenen", 86_400),
                       moment("lviv", 2 * 86_400), moment("home-after", 3 * 86_400)]
        let coordinates: [String: CLLocationCoordinate2D] = [
            "home": .init(latitude: 52.08, longitude: 4.85),
            "rhenen": .init(latitude: 51.96, longitude: 5.59),
            "lviv": .init(latitude: 49.84, longitude: 24.03),
            "home-after": .init(latitude: 52.08, longitude: 4.85),
        ]
        XCTAssertTrue(JourneyStoryBuilder.stories(moments, home: home,
            coordinate: { coordinates[$0.id] },
            placeID: { ["rhenen": "Rhenen", "lviv": "Lviv"][$0.id] },
            support: { $0.id == "rhenen" ? 90 : 1 }).isEmpty)
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
