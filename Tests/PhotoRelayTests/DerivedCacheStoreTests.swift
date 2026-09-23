import XCTest
@testable import PhotoRelay

final class DerivedCacheStoreTests: XCTestCase {
    func testReopenAndNamespacesShareOneDatabaseFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("analysis-cache.sqlite3")
        let first = try DerivedCacheStore(url: url)
        try first.set(Data("labels".utf8), namespace: .visualLabels, key: "same")
        try first.set(Data("caption".utf8), namespace: .momentCaptions, key: "same")

        let reopened = try DerivedCacheStore(url: url)
        XCTAssertEqual(reopened.data(namespace: .visualLabels, key: "same", maximumBytes: 100), Data("labels".utf8))
        XCTAssertEqual(reopened.data(namespace: .momentCaptions, key: "same", maximumBytes: 100), Data("caption".utf8))
        XCTAssertEqual(try reopened.stats().records, 2)
    }

    func testLegacyFallbackImportsThenRemovesSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("legacy.json")
        let expected = Data("derived evidence".utf8)
        try expected.write(to: legacy)
        let cache = try DerivedCacheStore(url: root.appendingPathComponent("analysis-cache.sqlite3"))

        XCTAssertEqual(cache.data(namespace: .textEvidence, key: "legacy", maximumBytes: 100,
                                  legacyURL: legacy), expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(cache.data(namespace: .textEvidence, key: "legacy", maximumBytes: 100), expected)
    }

    func testBoundedBatchSkipsOversizedFilesWithoutDeletingThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let valid = root.appendingPathComponent("valid.json")
        let oversized = root.appendingPathComponent("oversized.json")
        try Data("ok".utf8).write(to: valid)
        try Data().write(to: URL(fileURLWithPath: valid.path + ".lock"))
        try Data(repeating: 1, count: 20).write(to: oversized)
        let cache = try DerivedCacheStore(url: root.appendingPathComponent("analysis-cache.sqlite3"))

        let count = try cache.importLegacy([
            (.automaticMoments, "valid", valid, 10),
            (.automaticMoments, "oversized", oversized, 10)
        ])
        XCTAssertEqual(count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: valid.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: valid.path + ".lock"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oversized.path))
    }

    func testLegacyImportNeverOverwritesNewerCacheEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try DerivedCacheStore(url: root.appendingPathComponent("analysis-cache.sqlite3"))
        try cache.set(Data("new".utf8), namespace: .momentCaptions, key: "caption")
        let legacy = root.appendingPathComponent("caption.json")
        try Data("old".utf8).write(to: legacy)

        XCTAssertEqual(try cache.importLegacy([(.momentCaptions, "caption", legacy, 100)]), 1)
        XCTAssertEqual(cache.data(namespace: .momentCaptions, key: "caption", maximumBytes: 100), Data("new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }
}
