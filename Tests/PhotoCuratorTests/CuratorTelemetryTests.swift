import XCTest
@testable import PhotoCurator

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
}
