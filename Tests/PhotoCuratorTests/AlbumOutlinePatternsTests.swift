import XCTest
@testable import PhotoCurator

final class AlbumOutlinePatternsTests: XCTestCase {
    func testSeasonBucketsArePureSeasonsOnly() {
        XCTAssertTrue(AlbumOutlinePatterns.isSeasonBucket("Зима 2006"))
        XCTAssertTrue(AlbumOutlinePatterns.isSeasonBucket("Осень 2006"))
        XCTAssertTrue(AlbumOutlinePatterns.isSeasonBucket("Summer 2008"))
        XCTAssertTrue(AlbumOutlinePatterns.isSeasonBucket("Весна 2006"))
        XCTAssertFalse(AlbumOutlinePatterns.isSeasonBucket("Лето 2012 Мариуполь"))
        XCTAssertFalse(AlbumOutlinePatterns.isSeasonBucket("Spring & Frankivsk"))
    }

    func testBikeOutingsAndNestedPlaceFolders() {
        XCTAssertTrue(AlbumOutlinePatterns.isBikeOuting("Velosypedy-Synevir"))
        XCTAssertTrue(AlbumOutlinePatterns.isBikeOuting("Ровери: Поїздка в Воловець"))
        let nested = AlbumOutlinePatterns.signals(
            title: "In the city", folderNames: ["Mariupol 2006", "2006"])
        XCTAssertTrue(nested.contains(.nestedPlaceFolder))
        XCTAssertTrue(nested.contains(.yearFolder))
        XCTAssertTrue(nested.contains(.placeLikeTitle))
    }

    func testTechnicalAlbumsAreSkippedFromCandidates() {
        XCTAssertTrue(AlbumOutlinePatterns.isTechnicalSkip("From iPhone"))
        XCTAssertTrue(AlbumOutlinePatterns.isTechnicalSkip("Skoryny 26 photoframe"))
        XCTAssertTrue(AlbumOutlinePatterns.isTechnicalSkip("Скорини 26 кв. 6"))
        XCTAssertTrue(AlbumOutlinePatterns.isTechnicalSkip("PowerBook G4"))
        let albums: [[String: Any]] = [
            ["title": "From iPhone", "historicalPhotos": 200, "underPhotoCurator": false,
             "folderNames": ["2011"], "locationNames": [], "hasApproximateLocation": false],
            ["title": "Glasgow", "historicalPhotos": 120, "underPhotoCurator": false,
             "folderNames": ["2006"], "locationNames": ["Glasgow"], "hasApproximateLocation": true],
            ["title": "Зима 2006", "historicalPhotos": 90, "underPhotoCurator": false,
             "folderNames": ["2006"], "locationNames": [], "hasApproximateLocation": false]
        ]
        let candidates = UnlocatedAlbumStoryCandidates.propose(from: albums, minimumPhotos: 40)
        XCTAssertEqual(candidates.map(\.title), ["Glasgow"])
        XCTAssertFalse(candidates.contains { $0.title == "From iPhone" })
        XCTAssertFalse(candidates.contains { $0.title == "Зима 2006" })
    }
}
