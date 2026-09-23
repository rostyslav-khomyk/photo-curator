import XCTest
@testable import PhotoRelay

final class CuratorPerformanceTests: XCTestCase {
    func testFullLibraryGroupingBaseline() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHOTO_CURATOR_PERFORMANCE"] == "1")
        let photoCount = ProcessInfo.processInfo.environment["PHOTO_CURATOR_PERFORMANCE_COUNT"]
            .flatMap(Int.init) ?? 100_000
        XCTAssertGreaterThan(photoCount, 0)
        let day: TimeInterval = 86_400
        var photos: [IndexedPhoto] = []
        photos.reserveCapacity(photoCount)
        for index in 0..<photoCount {
            let captureTime = 978_307_200 + Double(index / 35) * day + Double(index % 35) * 45
            let hasLocation = index % 7 != 0
            let latitude = hasLocation ? 52.0 + Double(index % 31) / 10_000 : nil
            let longitude = hasLocation ? 4.0 + Double(index % 29) / 10_000 : nil
            photos.append(IndexedPhoto(id: "synthetic-\(index)", created: Date(timeIntervalSince1970: captureTime),
                modified: nil, latitude: latitude, longitude: longitude, favorite: index % 19 == 0,
                width: 4_032, height: 3_024))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let moments = MomentGrouping.group(photos, calendar: calendar)
            XCTAssertGreaterThan(moments.count, photoCount / 50)
            XCTAssertEqual(moments.reduce(0) { $0 + $1.photos.count }, photos.count)
        }
    }
}
