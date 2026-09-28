import XCTest
import SQLite3
@testable import PhotoCurator

final class PhotoCuratorStorageMigrationTests: XCTestCase {
    func testLegacyDirectoryAndSavedPathMoveTogether() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaultsName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let legacyName = ["Photo", "Relay"].joined(separator: " ")
        let legacy = root.appendingPathComponent(legacyName)
        let file = legacy.appendingPathComponent("album_mapping.json")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: file)
        defaults.set(file.path, forKey: "albumMapping")

        PhotoCuratorStorageMigration.run(defaults: defaults, roots: [root])

        let migrated = root.appendingPathComponent("Photo Curator/album_mapping.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrated.path))
        XCTAssertEqual(defaults.string(forKey: "albumMapping"), migrated.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testExistingDestinationKeepsBothLogFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent(["Photo", "Relay"].joined(separator: " "))
        let current = root.appendingPathComponent("Photo Curator")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: legacy.appendingPathComponent("curator.jsonl"))
        try Data("new".utf8).write(to: current.appendingPathComponent("curator.jsonl"))

        PhotoCuratorStorageMigration.run(roots: [root])

        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("curator.jsonl")), "new")
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("curator.jsonl.legacy")), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testLegacyGoogleLedgerMergesIntoCurrentLedger() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Photo Curator")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent(["photo", "relay", "uploads"].joined(separator: "_") + ".sqlite3")
        let current = directory.appendingPathComponent("photo_curator_uploads.sqlite3")
        try makeLedger(legacy, upload: ("old", "digest-old", "media-old"))
        try makeLedger(current, upload: ("new", "digest-new", "media-new"))

        PhotoCuratorStorageMigration.run(roots: [root])

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try rowCount(current, table: "uploads"), 2)
    }

    private func makeLedger(_ url: URL, upload: (String, String, String)) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE uploads (account TEXT, digest TEXT, media_id TEXT, PRIMARY KEY (account, digest)); CREATE TABLE album_creations (account TEXT, title TEXT, album_id TEXT, PRIMARY KEY (account, title)); INSERT INTO uploads VALUES ('\(upload.0)', '\(upload.1)', '\(upload.2)')", nil, nil, nil), SQLITE_OK)
    }

    private func rowCount(_ url: URL, table: String) throws -> Int {
        var db: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadCorruptFile) }
        return Int(sqlite3_column_int(statement, 0))
    }
}
