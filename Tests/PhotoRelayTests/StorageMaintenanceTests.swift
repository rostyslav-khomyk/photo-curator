import XCTest
@testable import PhotoRelay

final class StorageMaintenanceTests: XCTestCase {
    func testTrimRemovesExpiredThenOldestFilesToBoundSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = root.appendingPathComponent("old")
        let newer = root.appendingPathComponent("newer")
        let newest = root.appendingPathComponent("newest")
        try Data(repeating: 1, count: 10).write(to: old)
        try Data(repeating: 2, count: 10).write(to: newer)
        try Data(repeating: 3, count: 10).write(to: newest)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: newer.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 30)], ofItemAtPath: newest.path)

        StorageMaintenance.trim(root, maximumBytes: 10,
            deleteOlderThan: Date(timeIntervalSince1970: 10))

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newer.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
    }
}
