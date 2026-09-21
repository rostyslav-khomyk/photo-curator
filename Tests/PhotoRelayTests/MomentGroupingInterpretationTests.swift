import XCTest
@testable import PhotoRelay

final class MomentGroupingInterpretationTests: XCTestCase {
    private func makePhoto(id: String, secondsOffset: Double, lat: Double? = nil, lon: Double? = nil, favorite: Bool = false) -> IndexedPhoto {
        IndexedPhoto(
            id: id,
            created: Date(timeIntervalSince1970: 1724932800 + secondsOffset),
            modified: nil,
            latitude: lat,
            longitude: lon,
            favorite: favorite,
            width: 4000,
            height: 3000
        )
    }

    func testDirectGPSAllPhotos() {
        let photos = (0..<10).map { i in
            makePhoto(id: "p\(i)", secondsOffset: Double(i * 120), lat: 43.433, lon: 6.737, favorite: i < 2)
        }
        let moment = PhotoMoment(
            id: "m1",
            start: photos.first!.created!,
            end: photos.last!.created!,
            photos: photos
        )
        let place = ResolvedPlace(locality: "Fréjus", isExtrapolated: false)
        let text = MomentGroupingInterpretation.describe(moment: moment, place: place)

        XCTAssertTrue(text.contains("10 photos (including 2 favorites)"))
        XCTAssertTrue(text.contains("captured over 18 minutes"))
        XCTAssertTrue(text.contains("Recorded GPS coordinates confirm location in Fréjus for all photos."))
        XCTAssertTrue(text.contains("Continuous camera session with consistent lighting."))
    }

    func testExtrapolatedLocation() {
        let photos = (0..<5).map { i in
            makePhoto(id: "p\(i)", secondsOffset: Double(i * 60))
        }
        let moment = PhotoMoment(
            id: "m2",
            start: photos.first!.created!,
            end: photos.last!.created!,
            photos: photos
        )
        let place = ResolvedPlace(locality: "Fréjus", isExtrapolated: true, extrapolationDetails: "Extrapolated from nearby photos on the same day")
        let text = MomentGroupingInterpretation.describe(moment: moment, place: place)

        XCTAssertTrue(text.contains("Location estimated as Fréjus based on photos taken nearby on the same day."))
    }

    func testPartialGPS() {
        let photos = (0..<6).map { i in
            makePhoto(id: "p\(i)", secondsOffset: Double(i * 30), lat: i < 3 ? 43.710 : nil, lon: i < 3 ? 7.262 : nil)
        }
        let moment = PhotoMoment(
            id: "m3",
            start: photos.first!.created!,
            end: photos.last!.created!,
            photos: photos
        )
        let place = ResolvedPlace(locality: "Nice", isExtrapolated: false)
        let text = MomentGroupingInterpretation.describe(moment: moment, place: place)

        XCTAssertTrue(text.contains("Recorded GPS confirms location in Nice for 3 photos"))
    }

    func testNoGPSFallback() {
        let photos = (0..<4).map { i in
            makePhoto(id: "p\(i)", secondsOffset: Double(i * 10))
        }
        let moment = PhotoMoment(
            id: "m4",
            start: photos.first!.created!,
            end: photos.last!.created!,
            photos: photos
        )
        let text = MomentGroupingInterpretation.describe(moment: moment, place: nil)

        XCTAssertTrue(text.contains("Grouped by capture timing and consistent scene setting."))
    }

    func testVisualActivityClue() {
        let photos = (0..<4).map { i in
            makePhoto(id: "p\(i)", secondsOffset: Double(i * 10))
        }
        var moment = PhotoMoment(
            id: "m5",
            start: photos.first!.created!,
            end: photos.last!.created!,
            photos: photos
        )
        moment.narrative = .init(version: MomentNarrative.version, headline: "Time outdoors", deck: nil,
            story: "Outdoors in the sun", place: nil, date: "Today", confidence: 0.8, provenance: ["test"], state: .automatic)

        let text = MomentGroupingInterpretation.describe(moment: moment, place: nil)
        XCTAssertTrue(text.contains("Visual clues highlight time outdoors."))
    }
}
