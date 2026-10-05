import XCTest
@testable import PhotoCurator

final class ExperimentalUnlocatedJourneyTests: XCTestCase {
    private let calendar = ExperimentalUnlocatedJourneyBuilder.utcCalendar
    private let review = OwnerAlbumStoryReview(
        version: 1, reviewedAt: "test", sourceAudit: "test",
        labels: [
            "Kiev 2005": .journey,
            "Vanessa": .people,
            "Home": .people,
            "Madison": .outing
        ])

    func testShouldOfferOnlyWhenLeftoversRemain() {
        XCTAssertFalse(ExperimentalUnlocatedJourneyBuilder.shouldOffer(eligibleCount: 11))
        XCTAssertTrue(ExperimentalUnlocatedJourneyBuilder.shouldOffer(eligibleCount: 12))
    }

    func testSkipsPhotosAlreadyInGPSOrAlbumStories() {
        let leftover = summerStretch(year: 2009, prefix: "left")
        let claimedGPS = summerStretch(year: 2008, prefix: "gps").map {
            var photo = $0
            photo.claimedByGPSJourney = true
            return photo
        }
        let claimedAlbum = summerStretch(year: 2007, prefix: "alb").map {
            var photo = $0
            photo.claimedByAlbumStory = true
            return photo
        }
        let located = [photo("gps-pin", day(2009, 7, 1), unlocated: false)]
        let proposals = ExperimentalUnlocatedJourneyBuilder.propose(
            photos: leftover + claimedGPS + claimedAlbum + located, review: review, calendar: calendar)
        XCTAssertEqual(proposals.count, 1)
        XCTAssertTrue(proposals[0].photoIDs.allSatisfy { $0.hasPrefix("left-") })
        XCTAssertTrue(proposals[0].lastResort)
        XCTAssertTrue(proposals[0].experimental)
        XCTAssertNil(proposals[0].latitude)
        XCTAssertNil(proposals[0].longitude)
    }

    func testDoesNotInventCoordinates() {
        let proposals = ExperimentalUnlocatedJourneyBuilder.propose(
            photos: summerStretch(year: 2009, prefix: "s"), review: review, calendar: calendar)
        XCTAssertEqual(proposals.count, 1)
        XCTAssertNil(proposals[0].latitude)
        XCTAssertNil(proposals[0].longitude)
        XCTAssertTrue(proposals[0].stabilityWarning.contains("macOS"))
    }

    func testDoesNotGlueYearsBecauseSameChildAppears() {
        let y2005 = summerStretch(year: 2005, prefix: "a", people: ["Hanna Khomyk"])
        let y2007 = summerStretch(year: 2007, prefix: "b", people: ["Hanna Khomyk"])
        let proposals = ExperimentalUnlocatedJourneyBuilder.propose(
            photos: y2005 + y2007, review: review, calendar: calendar)
        XCTAssertEqual(proposals.count, 2)
        let years = Set(proposals.map { calendar.component(.year, from: $0.start) })
        XCTAssertEqual(years, [2005, 2007])
        XCTAssertTrue(proposals.allSatisfy { calendar.component(.year, from: $0.start) == calendar.component(.year, from: $0.end) })
    }

    func testRejectsZeroFaceImportDump() {
        let dump = (0..<90).map { index in
            photo("dump-\(index)", day(2005, 2, 23, hour: 16, minute: index / 30),
                  faces: 0, people: [], family: "Scan", number: index)
        }
        XCTAssertTrue(ExperimentalUnlocatedJourneyBuilder.isDump(dump))
        let proposals = ExperimentalUnlocatedJourneyBuilder.propose(
            photos: dump, review: review, calendar: calendar)
        XCTAssertTrue(proposals.isEmpty)
    }

    func testBuildsSummerStretchFromTimeAndCast() {
        let photos = summerStretch(year: 2009, prefix: "trip",
                                   people: ["Hanna Khomyk", "Olena Kostenko", "Ulyana Dulzon"])
        let proposals = ExperimentalUnlocatedJourneyBuilder.propose(
            photos: photos, review: review, calendar: calendar)
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals[0].title, "Summer 2009 · Hanna Khomyk, Olena Kostenko, Ulyana Dulzon")
        XCTAssertGreaterThanOrEqual(proposals[0].photoIDs.count, 20)
        XCTAssertTrue(proposals[0].reasons.contains { $0.contains("filename run") })
        XCTAssertTrue(proposals[0].reasons.contains {
            $0.contains("cast Hanna Khomyk, Olena Kostenko, Ulyana Dulzon")
        })
        XCTAssertGreaterThanOrEqual(proposals[0].namedPeople["Ulyana Dulzon"] ?? 0, 5)
    }

    func testCastKeepsHouseholdAndQuieterGuests() {
        var photos = summerStretch(year: 2007, prefix: "cast",
                                   people: ["Hanna Khomyk", "Olena Kostenko"])
        for index in 0..<12 {
            var photo = photos[index]
            var names = photo.namedPeople
            if index < 10 { names.append("Luba Kostenko") }
            if index < 8 { names.append("Vanessa") }
            if index < 6 { names.append("Ulyana Dulzon") }
            photo.namedPeople = names
            photo.faceCount = names.count
            photos[index] = photo
        }
        let proposals = ExperimentalUnlocatedJourneyBuilder.propose(
            photos: photos, review: review, calendar: calendar)
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals[0].title,
                       "Summer 2007 · Hanna Khomyk, Olena Kostenko, Luba Kostenko, Vanessa, Ulyana Dulzon")
        let household = ExperimentalUnlocatedJourneyBuilder.householdNames(photos)
        let cast = ExperimentalUnlocatedJourneyBuilder.castNames(
            proposals[0].namedPeople, photos: photos, household: household)
        XCTAssertEqual(cast, ["Hanna Khomyk", "Olena Kostenko", "Luba Kostenko", "Vanessa", "Ulyana Dulzon"])
    }

    func testCastKeepsTwoPeopleWhoShareAFirstName() {
        let photos = summerStretch(year: 2008, prefix: "olenas",
                                   people: ["Hanna Khomyk", "Olena Kostenko", "Olena Dulzon"])
        let proposals = ExperimentalUnlocatedJourneyBuilder.propose(
            photos: photos, review: review, calendar: calendar)
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals[0].title, "Summer 2008 · Hanna Khomyk, Olena Dulzon, Olena Kostenko")
    }

    func testFormatCastCollapsesWhitespaceAndDuplicates() {
        XCTAssertEqual(ExperimentalUnlocatedJourneyBuilder.formatCast(
            ["Hanna  Khomyk", "Hanna Khomyk", " Vanessa "]), "Hanna Khomyk, Vanessa")
        XCTAssertNil(ExperimentalUnlocatedJourneyBuilder.formatCast([]))
    }

    func testPeopleAlbumAloneIsNotAJourney() {
        var photos: [ExperimentalUnlocatedJourneyBuilder.Photo] = []
        for dayIndex in 0..<20 {
            for shot in 0..<3 {
                photos.append(photo(
                    "home-\(dayIndex)-\(shot)",
                    day(2006, 3, 1 + dayIndex, hour: 10 + shot),
                    faces: 1, people: ["Vanessa"], albums: ["Vanessa", "Home"]))
            }
        }
        let proposals = ExperimentalUnlocatedJourneyBuilder.propose(
            photos: photos, review: review, calendar: calendar)
        XCTAssertTrue(proposals.isEmpty)
    }

    func testJourneyAlbumNamesTheInterval() {
        var photos = summerStretch(year: 2005, prefix: "kiev", people: ["Hanna Khomyk"])
        photos = photos.map {
            var photo = $0
            photo.albumTitles = ["Kiev 2005"]
            return photo
        }
        let proposals = ExperimentalUnlocatedJourneyBuilder.propose(
            photos: photos, review: review, calendar: calendar)
        XCTAssertEqual(proposals.map(\.title), ["Kiev 2005 · Hanna Khomyk"])
        XCTAssertTrue(proposals[0].reasons.contains { $0.contains("Kiev 2005") })
    }

    func testLondonTimezoneSurfacesInTitle() {
        var photos = summerStretch(year: 2008, prefix: "uk", people: ["Hanna Khomyk"])
        photos = photos.map {
            var photo = $0
            photo.timezoneName = "Europe/London"
            return photo
        }
        let proposals = ExperimentalUnlocatedJourneyBuilder.propose(
            photos: photos, review: review, calendar: calendar)
        XCTAssertEqual(proposals.map(\.title), ["Summer 2008 · London · Hanna Khomyk"])
        XCTAssertNil(ExperimentalUnlocatedJourneyBuilder.placeName(forTimeZone: "Europe/Kiev"))
    }

    func testShortOutingAlbumIsNotPromotedToJourney() {
        let photos = (0..<12).map { index in
            photo("out-\(index)", day(2008, 5, 3, hour: 11, minute: index),
                  faces: 1, people: ["Hanna Khomyk"], family: "IMG", number: index,
                  albums: ["Madison"])
        }
        let proposals = ExperimentalUnlocatedJourneyBuilder.propose(
            photos: photos, review: review, calendar: calendar)
        XCTAssertTrue(proposals.isEmpty)
    }

    func testSameSeasonRestDaysStayOneJourney() {
        let early = summerStretch(year: 2009, prefix: "early",
                                  people: ["Hanna Khomyk", "Olena Kostenko", "Ulyana Dulzon"])
        let later = (0..<16).map { index in
            photo("later-\(index)", day(2009, 7, 20 + index / 8, hour: 9 + (index % 8)),
                  faces: 2, people: ["Hanna Khomyk", "Olena Kostenko", "Ulyana Dulzon"],
                  family: "DSC", number: 200 + index)
        }
        let proposals = ExperimentalUnlocatedJourneyBuilder.propose(
            photos: early + later, review: review, calendar: calendar)
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(calendar.component(.month, from: proposals[0].start), 7)
        XCTAssertEqual(calendar.component(.day, from: proposals[0].end), 21)
        XCTAssertTrue(proposals[0].title.contains("Ulyana"))
    }

    func testSparseHouseholdMonthIsNotAJourney() {
        var photos: [ExperimentalUnlocatedJourneyBuilder.Photo] = []
        var number = 1
        for dayIndex in 0..<16 {
            for shot in 0..<3 {
                photos.append(photo(
                    "home-\(dayIndex)-\(shot)",
                    day(2006, 6, 1 + dayIndex, hour: 10 + shot),
                    faces: 1, people: ["Hanna Khomyk", "Olena Kostenko"],
                    family: "DSC", number: number))
                number += 1
            }
        }
        let proposals = ExperimentalUnlocatedJourneyBuilder.propose(
            photos: photos, review: review, calendar: calendar)
        XCTAssertTrue(proposals.isEmpty)
    }

    func testFilenameRunCanHoldAShortTripTogether() {
        let photos = (0..<16).map { index in
            let dayOffset = index / 8
            return photo("run-\(index)", day(2004, 6, 10 + dayOffset, hour: 9 + (index % 8)),
                         faces: 1, people: ["Hanna Khomyk"], family: "DSC", number: 100 + index)
        }
        let proposals = ExperimentalUnlocatedJourneyBuilder.propose(
            photos: photos, review: review, calendar: calendar)
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals[0].title, "Summer 2004 · Hanna Khomyk")
    }

    func testQuietHomeWeeksWithoutBusyDaysAreNotJourneys() {
        var photos: [ExperimentalUnlocatedJourneyBuilder.Photo] = []
        for dayIndex in 0..<15 {
            for shot in 0..<3 {
                photos.append(photo(
                    "quiet-\(dayIndex)-\(shot)",
                    day(2006, 4, 1 + dayIndex, hour: 10 + shot),
                    faces: 1, people: ["Hanna Khomyk"], family: nil, number: nil))
            }
        }
        let proposals = ExperimentalUnlocatedJourneyBuilder.propose(
            photos: photos, review: review, calendar: calendar)
        XCTAssertTrue(proposals.isEmpty)
    }

    func testStoriesSkipClaimedMomentsAndKeepEmptyStops() {
        let photos = summerStretch(year: 2009, prefix: "m1")
        let leftover = UnlocatedAlbumStoryBuilder.MomentMembership(
            id: "summer", start: photos.first!.created, end: photos.last!.created,
            assetIDs: Set(photos.map(\.id)))
        let claimed = UnlocatedAlbumStoryBuilder.MomentMembership(
            id: "gps", start: day(2024, 6, 1), end: day(2024, 6, 8),
            assetIDs: Set(photos.prefix(4).map(\.id)))
        let stories = ExperimentalUnlocatedJourneyBuilder.stories(
            moments: [leftover, claimed],
            photos: photos,
            claimedMomentIDs: ["gps"],
            review: review,
            calendar: calendar)
        XCTAssertEqual(stories.count, 1)
        XCTAssertEqual(stories[0].momentIDs, ["summer"])
        XCTAssertTrue(stories[0].stops.isEmpty)
        XCTAssertEqual(stories[0].kind, .journey)
        XCTAssertFalse(stories[0].placeID.hasPrefix("Journey from "))
    }

    func testHouseholdNamesIgnoreGuests() {
        var photos: [ExperimentalUnlocatedJourneyBuilder.Photo] = []
        for index in 0..<20 {
            let people = index < 4
                ? ["Hanna Khomyk", "Olena Kostenko", "Ulyana Dulzon"]
                : ["Hanna Khomyk", "Olena Kostenko"]
            photos.append(photo("h-\(index)", day(2009, 7, 1 + index / 4), faces: 2, people: people))
        }
        let household = ExperimentalUnlocatedJourneyBuilder.householdNames(photos)
        XCTAssertTrue(household.contains("Hanna Khomyk"))
        XCTAssertTrue(household.contains("Olena Kostenko"))
        XCTAssertFalse(household.contains("Ulyana Dulzon"))
    }

    private func summerStretch(year: Int, prefix: String,
                               people: [String] = ["Hanna Khomyk", "Olena Kostenko"]) -> [ExperimentalUnlocatedJourneyBuilder.Photo] {
        var photos: [ExperimentalUnlocatedJourneyBuilder.Photo] = []
        var number = 10
        for dayIndex in 0..<4 {
            for shot in 0..<8 {
                var names = people
                if names.contains("Ulyana Dulzon"), !(dayIndex < 2 && shot < 3) {
                    names = people.filter { $0 != "Ulyana Dulzon" }
                }
                photos.append(photo(
                    "\(prefix)-\(dayIndex)-\(shot)",
                    day(year, 7, 10 + dayIndex, hour: 9 + shot),
                    faces: names.count, people: names, family: "DSC", number: number))
                number += 1
            }
        }
        return photos
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    private func photo(_ id: String, _ created: Date, unlocated: Bool = true,
                       faces: Int = 1, people: [String] = ["Hanna Khomyk"],
                       family: String? = "DSC", number: Int? = 1,
                       albums: [String] = []) -> ExperimentalUnlocatedJourneyBuilder.Photo {
        ExperimentalUnlocatedJourneyBuilder.Photo(
            id: id, created: created, unlocated: unlocated,
            namedPeople: people, faceCount: faces,
            filenameFamily: family, filenameNumber: number, albumTitles: albums)
    }
}
