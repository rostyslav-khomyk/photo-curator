import XCTest
@testable import PhotoCurator

final class PhotosAlbumNamingTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func testAlbumTitleEndsWithDayAndMonthOnly() {
        XCTAssertEqual(PhotosAlbumNaming.albumTitle("Lake Garda evening", date: date(2022, 7, 16)),
                       "Lake Garda evening · 16 Jul")
        XCTAssertEqual(PhotosAlbumNaming.albumTitle("Lake Garda evening · 16 Jul", date: date(2022, 7, 16)),
                       "Lake Garda evening · 16 Jul")
        XCTAssertEqual(PhotosAlbumNaming.albumTitle("  Undated  ", date: nil), "Undated")
    }

    func testStoryFolderHasNoDatePrefix() {
        XCTAssertEqual(PhotosAlbumNaming.storyFolderTitle("Journey through Italy"), "Journey through Italy")
        XCTAssertEqual(PhotosAlbumNaming.storyFolderTitle(nil), "Moments")
        XCTAssertEqual(PhotosAlbumNaming.storyFolderTitle("   "), "Moments")
        XCTAssertEqual(PhotosAlbumNaming.disambiguatedStoryTitle("Journey to Bucharest", start: date(2024, 3, 2)),
                       "Journey to Bucharest · Mar")
    }

    func testLegacyNamesParseAndConvert() {
        let album = PhotosAlbumNaming.legacyAlbum("2022-07-16 Lake Garda evening")
        XCTAssertEqual(album?.title, "Lake Garda evening")
        XCTAssertEqual(album.map { PhotosAlbumNaming.albumTitle($0.title, date: $0.date) },
                       "Lake Garda evening · 16 Jul")
        XCTAssertEqual(PhotosAlbumNaming.legacyStoryFolder("2022-07 Journey through Italy")?.title,
                       "Journey through Italy")
        XCTAssertEqual(PhotosAlbumNaming.legacyStoryFolder("2022-11 Moments")?.title, "Moments")
        XCTAssertNil(PhotosAlbumNaming.legacyAlbum("Lake Garda evening · 16 Jul"))
        XCTAssertNil(PhotosAlbumNaming.legacyStoryFolder("Journey through Italy"))
        XCTAssertNil(PhotosAlbumNaming.legacyStoryFolder("2022-07"))
    }

    func testYearFoldersSortByTitle() {
        XCTAssertEqual(PhotosAlbumNaming.yearStart("2009"),
                       Calendar.current.date(from: DateComponents(year: 2009, month: 1, day: 1)))
        XCTAssertNil(PhotosAlbumNaming.yearStart("Moments"))
    }

    func testInsertionIndexIsChronologicalWithUndatedLast() {
        let siblings: [Date?] = [date(2022, 7, 1), date(2022, 7, 20), nil]
        XCTAssertEqual(PhotosAlbumNaming.chronologicalIndex(for: date(2022, 6, 1), among: siblings), 0)
        XCTAssertEqual(PhotosAlbumNaming.chronologicalIndex(for: date(2022, 7, 10), among: siblings), 1)
        XCTAssertEqual(PhotosAlbumNaming.chronologicalIndex(for: date(2022, 8, 1), among: siblings), 2)
        XCTAssertEqual(PhotosAlbumNaming.chronologicalIndex(for: nil, among: siblings), 3)
    }

    func testMovesSortSiblingsChronologically() {
        let dates: [Date?] = [date(2022, 8, 1), nil, date(2022, 6, 1), date(2022, 7, 1)]
        var order = Array(dates.indices)
        for move in PhotosAlbumNaming.chronologicalMoves(dates) {
            XCTAssertLessThanOrEqual(move.to, move.from)
            let item = order.remove(at: move.from)
            order.insert(item, at: move.to)
        }
        XCTAssertEqual(order, [2, 3, 0, 1])
        XCTAssertTrue(PhotosAlbumNaming.chronologicalMoves([date(2022, 1, 1), date(2022, 2, 1)]).isEmpty)
    }
}
