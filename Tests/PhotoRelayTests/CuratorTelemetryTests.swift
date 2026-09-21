import XCTest
@testable import PhotoRelay

final class CuratorTelemetryTests: XCTestCase {
    func testRotationAndPrivateFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = CuratorTelemetry(directory: root, maximumBytes: 1)
        for _ in 0..<8 { log.record(.analysis, counts: ["saved": 3]) }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 4)
        for file in files {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
            let entry = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            XCTAssertEqual(entry?["event"] as? String, "analysis")
        }
    }
    func testPilotCannotEscapeConfiguredMonth() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let start = Date(timeIntervalSince1970: 100), end = Date(timeIntervalSince1970: 200)
        defaults.set(start, forKey: "curatorPilotStart"); defaults.set(end, forKey: "curatorPilotEnd")
        XCTAssertEqual(CuratorPilot.scope(nil, defaults: defaults), DateInterval(start: start, end: end))
        XCTAssertEqual(CuratorPilot.scope(DateInterval(start: .distantPast, end: .distantFuture), defaults: defaults)?.duration, 100)
        XCTAssertEqual(CuratorPilot.scope(DateInterval(start: end.addingTimeInterval(1), duration: 10), defaults: defaults)?.duration, 0)
    }
}
