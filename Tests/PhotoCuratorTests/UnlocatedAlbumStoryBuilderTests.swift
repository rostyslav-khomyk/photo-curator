import XCTest
@testable import PhotoCurator

final class OwnerAlbumStoryReviewTests: XCTestCase {
    func testSeptember2026PassClassifiesOnlyJourneyAndOutingAsShipping() {
        let review = OwnerAlbumStoryReview.september2026OwnerPass
        XCTAssertEqual(review.labels.values.filter { $0 == .journey }.count, 9)
        XCTAssertEqual(review.labels.values.filter { $0 == .outing }.count, 7)
        XCTAssertEqual(review.labels.values.filter { $0 == .people }.count, 5)
        XCTAssertEqual(review.storyTitles.count, 16)
        XCTAssertEqual(review.kind(forAlbumTitle: "new york"), .journey)
        XCTAssertEqual(review.kind(forAlbumTitle: "Twin Cities"), .outing)
        XCTAssertEqual(review.kind(forAlbumTitle: "Vanessa"), .people)
        XCTAssertEqual(review.kind(forAlbumTitle: "Personal"), .skip)
        XCTAssertFalse(review.kind(forAlbumTitle: "Vanessa")?.shipsAsStory == true)
    }

    func testStoreInstallsDefaultReviewAtomically() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("owner-album-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("owner-album-story-review.json")
        let loaded = try OwnerAlbumStoryReviewStore.load(url: url)
        XCTAssertEqual(loaded.version, OwnerAlbumStoryReview.currentVersion)
        XCTAssertEqual(loaded.storyTitles.count, 16)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0, 0o600)
    }
}

final class UnlocatedAlbumStoryBuilderTests: XCTestCase {
    func testBuildsJourneyAndOutingFromOwnerReviewAndSkipsPeople() {
        let review = OwnerAlbumStoryReview(
            version: 1, reviewedAt: "test", sourceAudit: "test",
            labels: [
                "New York": .journey,
                "Chicago": .outing,
                "Vanessa": .people
            ])
        let moments = [
            UnlocatedAlbumStoryBuilder.MomentMembership(
                id: "m1", start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200),
                assetIDs: Set((1...12).map { "ny-\($0)" })),
            UnlocatedAlbumStoryBuilder.MomentMembership(
                id: "m2", start: Date(timeIntervalSince1970: 300), end: Date(timeIntervalSince1970: 400),
                assetIDs: Set((13...24).map { "ny-\($0)" })),
            UnlocatedAlbumStoryBuilder.MomentMembership(
                id: "m3", start: Date(timeIntervalSince1970: 500), end: Date(timeIntervalSince1970: 600),
                assetIDs: Set((1...8).map { "chi-\($0)" })),
            UnlocatedAlbumStoryBuilder.MomentMembership(
                id: "m4", start: Date(timeIntervalSince1970: 700), end: Date(timeIntervalSince1970: 800),
                assetIDs: Set((1...6).map { "van-\($0)" }))
        ]
        let albums = [
            UnlocatedAlbumStoryBuilder.AlbumMembership(
                title: "New York", assetIDs: Set((1...24).map { "ny-\($0)" })),
            UnlocatedAlbumStoryBuilder.AlbumMembership(
                title: "Chicago", assetIDs: Set((1...8).map { "chi-\($0)" })),
            UnlocatedAlbumStoryBuilder.AlbumMembership(
                title: "Vanessa", assetIDs: Set((1...6).map { "van-\($0)" }))
        ]
        let stories = UnlocatedAlbumStoryBuilder.stories(moments: moments, albums: albums, review: review)
        XCTAssertEqual(stories.count, 2)
        XCTAssertEqual(stories.map(\.kind).sorted { $0.rawValue < $1.rawValue }, [.journey, .outing])
        XCTAssertEqual(Set(stories.map(\.placeID)), Set(["New York", "Chicago"]))
        XCTAssertFalse(stories.contains { $0.placeID == "Vanessa" })
        let newYork = stories.first { $0.placeID == "New York" }!
        XCTAssertEqual(newYork.momentIDs, ["m1", "m2"])
        XCTAssertTrue(newYork.stops.isEmpty)
    }

    func testSplitsMultiTripAlbumsAtSevenDayGaps() {
        let review = OwnerAlbumStoryReview(
            version: 1, reviewedAt: "test", sourceAudit: "test",
            labels: ["Glasgow": .journey])
        let day: TimeInterval = 86_400
        // 2003-01-01 and 2004-01-01 anchors so year disambiguation is visible.
        let y2003 = Date(timeIntervalSince1970: 1_041_379_200)
        let y2004 = Date(timeIntervalSince1970: 1_072_915_200)
        let moments = [
            UnlocatedAlbumStoryBuilder.MomentMembership(
                id: "g1", start: y2003, end: y2003.addingTimeInterval(day),
                assetIDs: Set((1...10).map { "g-\($0)" })),
            UnlocatedAlbumStoryBuilder.MomentMembership(
                id: "g2", start: y2003.addingTimeInterval(2 * day), end: y2003.addingTimeInterval(3 * day),
                assetIDs: Set((11...20).map { "g-\($0)" })),
            UnlocatedAlbumStoryBuilder.MomentMembership(
                id: "g3", start: y2004, end: y2004.addingTimeInterval(day),
                assetIDs: Set((21...30).map { "g-\($0)" })),
            UnlocatedAlbumStoryBuilder.MomentMembership(
                id: "g4", start: y2004.addingTimeInterval(2 * day), end: y2004.addingTimeInterval(3 * day),
                assetIDs: Set((31...40).map { "g-\($0)" }))
        ]
        let albums = [
            UnlocatedAlbumStoryBuilder.AlbumMembership(
                title: "Glasgow", assetIDs: Set((1...40).map { "g-\($0)" }))
        ]
        let stories = UnlocatedAlbumStoryBuilder.stories(moments: moments, albums: albums, review: review)
        XCTAssertEqual(stories.count, 2)
        XCTAssertEqual(Set(stories.map(\.placeID)), Set(["Glasgow · 2003", "Glasgow · 2004"]))
        XCTAssertEqual(Set(stories.map { UnlocatedAlbumStoryBuilder.albumMatchKey(fromDisplayTitle: $0.placeID) }),
                       ["glasgow"])
        let clusters = Set(stories.map { $0.momentIDs.joined(separator: ",") })
        XCTAssertEqual(clusters, Set(["g1,g2", "g3,g4"]))
        XCTAssertEqual(
            UnlocatedAlbumStoryBuilder.cluster(moments).map { $0.map(\.id) },
            [["g1", "g2"], ["g3", "g4"]])
    }

    func testDisplayTitleStripsImagesFromPrefixAndYears() {
        let start = Date(timeIntervalSince1970: 1_100_000_000) // 2004
        let end = Date(timeIntervalSince1970: 1_160_000_000) // 2006
        XCTAssertEqual(
            UnlocatedAlbumStoryBuilder.displayTitle(
                albumTitle: "Images from: Slavsko", start: start, end: end, disambiguateByYear: false),
            "Slavsko")
        XCTAssertEqual(
            UnlocatedAlbumStoryBuilder.displayTitle(
                albumTitle: "Images from: Slavsko", start: start, end: end, disambiguateByYear: true),
            "Slavsko · 2004–2006")
        XCTAssertEqual(
            UnlocatedAlbumStoryBuilder.albumMatchKey(fromDisplayTitle: "Slavsko · 2004–2006"),
            "slavsko")
    }

    func testMergingPrefersBaseGPSStories() {
        let base = [CurationStory(
            id: "gps", start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2),
            momentIDs: ["m1", "m2"], placeID: "Paris", kind: .journey, stops: [])]
        let album = [CurationStory(
            id: "album", start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 5),
            momentIDs: ["m2", "m3"], placeID: "Glasgow", kind: .journey, stops: [])]
        let merged = UnlocatedAlbumStoryBuilder.merging(base: base, albumStories: album)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first { $0.id == "gps" }?.momentIDs, ["m1", "m2"])
        XCTAssertEqual(merged.first { $0.placeID == "Glasgow" }?.momentIDs, ["m3"])
    }

    func testClaimedMomentsAreExcludedAndOverlapThresholdHolds() throws {
        let review = OwnerAlbumStoryReview(
            version: 1, reviewedAt: "test", sourceAudit: "test",
            labels: ["Madison": .outing])
        let moments = [
            UnlocatedAlbumStoryBuilder.MomentMembership(
                id: "claimed", start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2),
                assetIDs: Set(["a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8", "a9", "a10"])),
            UnlocatedAlbumStoryBuilder.MomentMembership(
                id: "weak", start: Date(timeIntervalSince1970: 3), end: Date(timeIntervalSince1970: 4),
                assetIDs: Set(["z1", "z2", "z3", "z4", "z5", "z6", "z7", "z8"])),
            UnlocatedAlbumStoryBuilder.MomentMembership(
                id: "strong", start: Date(timeIntervalSince1970: 5), end: Date(timeIntervalSince1970: 6),
                assetIDs: Set(["a11", "a12", "a13", "b1"]))
        ]
        let albums = [
            UnlocatedAlbumStoryBuilder.AlbumMembership(
                title: "Madison",
                assetIDs: Set((1...13).map { "a\($0)" }))
        ]
        let stories = UnlocatedAlbumStoryBuilder.stories(
            moments: moments, albums: albums, review: review, claimedMomentIDs: ["claimed"])
        XCTAssertEqual(stories.count, 1)
        XCTAssertEqual(stories[0].momentIDs, ["strong"])
        XCTAssertFalse(UnlocatedAlbumStoryBuilder.overlaps(
            Set(["z1", "z2", "z3", "z4", "z5", "z6", "z7", "z8"]),
            Set(["a1", "a2"])))
    }

    func testPreviewWriteMarksShippingFalse() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-story-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("preview.json")
        let review = OwnerAlbumStoryReview.september2026OwnerPass
        let story = CurationStory(
            id: "story-test", start: Date(timeIntervalSince1970: 10), end: Date(timeIntervalSince1970: 20),
            momentIDs: ["m1"], placeID: "Glasgow", kind: .journey, stops: [])
        let summary = UnlocatedAlbumStoryPreview.Summary(
            eligibleAlbums: 16, matchedAlbums: 1, proposedStories: 1,
            claimedMomentsExcluded: 0, unmatchedTitles: ["New York"])
        try UnlocatedAlbumStoryPreview.write(
            stories: [story], summary: summary, review: review,
            albums: [UnlocatedAlbumStoryBuilder.AlbumMembership(title: "Glasgow", assetIDs: ["x"])],
            to: destination)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
        XCTAssertEqual(json?["shipping"] as? Bool, false)
        XCTAssertEqual(json?["proposedStories"] as? Int, 1)
        XCTAssertEqual((json?["stories"] as? [[String: Any]])?.first?["title"] as? String, "Glasgow")
    }
}
