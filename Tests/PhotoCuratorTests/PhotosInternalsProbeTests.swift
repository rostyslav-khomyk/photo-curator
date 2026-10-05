import XCTest
import SQLite3
@testable import PhotoCurator

final class PhotosInternalsProbeTests: XCTestCase {
    func testSafeValuesReadsRespondingKeysOnly() {
        let object = InternalsProbeAsset(
            title: "Kiev 2005",
            filename: "DSC_0012.JPG",
            timezoneName: "Europe/Kiev",
            timezoneOffset: 7200
        )
        let values = PhotosInternalsProbe.safeValues(on: object)
        XCTAssertEqual(values["title"], "Kiev 2005")
        XCTAssertEqual(values["filename"], "DSC_0012.JPG")
        XCTAssertEqual(values["timezoneName"], "Europe/Kiev")
        XCTAssertEqual(values["timezoneOffset"], "7200")
        XCTAssertNil(values["comment"])
    }

    func testPhotosSQLiteCountsUnlocatedPre2010TitlesAndIgnoresGPSReverse() throws {
        let url = try makePhotosFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let coverage = try PhotosInternalsProbe.photosSQLite(url: url)
        XCTAssertEqual(coverage.photos, 5)
        XCTAssertEqual(coverage.unlocated, 4)
        XCTAssertEqual(coverage.pre2010, 4)
        XCTAssertEqual(coverage.pre2010Unlocated, 3)
        XCTAssertEqual(coverage.withTitle, 2)
        XCTAssertEqual(coverage.placeLikeTitles, 2)
        XCTAssertEqual(coverage.withTimezoneName, 1)
        XCTAssertEqual(coverage.withImportSession, 1)
        XCTAssertEqual(coverage.withReverseLocation, 1)
        XCTAssertEqual(coverage.reverseLocationOnUnlocatedPre2010, 0)
        XCTAssertTrue(coverage.discoveredKeys.contains("ZTITLE"))
        XCTAssertEqual(coverage.signals?.withAnyFace, 0)
    }

    func testFilenameRunsGroupConsecutiveMemoryCardShots() {
        XCTAssertEqual(UnlocatedHistorySignals.filenameFamily("DSC_0142.JPG"), "DSC")
        XCTAssertEqual(UnlocatedHistorySignals.filenameFamily("IMG_0099.HEIC"), "IMG")
        XCTAssertEqual(UnlocatedHistorySignals.filenameNumber("DSC_0142.JPG"), 142)
        let runs = UnlocatedHistorySignals.filenameRuns([
            ("DSC", 10, 1), ("DSC", 11, 1), ("DSC", 12, 2),
            ("IMG", 1, 3), ("DSC", 50, 10)
        ])
        XCTAssertEqual(runs.sorted(), [1, 1, 3])
    }

    func testUnlocatedSignalsSeparateBusyJourneyDaysFromPeopleAlbums() throws {
        let url = try makeSignalsFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let coverage = try PhotosInternalsProbe.photosSQLite(url: url)
        let signals = try XCTUnwrap(coverage.signals)
        XCTAssertEqual(signals.withNamedFace, 10)
        XCTAssertEqual(signals.distinctNamedPeople, 2)
        XCTAssertEqual(signals.namedPeopleCounts["Anna"], 10)
        XCTAssertEqual(signals.namedPeopleCounts["Vanessa"], 8)
        XCTAssertEqual(signals.withUnnamedCluster, 2)
        XCTAssertGreaterThanOrEqual(signals.busyDays8Plus, 1)
        XCTAssertEqual(signals.filenameFamilies["DSC"], 10)
        XCTAssertGreaterThanOrEqual(signals.longestFilenameRun, 8)
        XCTAssertEqual(signals.albumKindPhotos["journey"], 10)
        XCTAssertEqual(signals.albumKindPhotos["people"], 2)
        XCTAssertGreaterThan(signals.busyDayShareByKind["journey"] ?? 0, signals.busyDayShareByKind["people"] ?? 0)
        XCTAssertEqual(signals.importDumpDays, 1)
    }

    func testSearchIndexCountsPlaceAndDetectedTextForOldAssets() throws {
        let url = try makeSearchFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let coverage = try PhotosInternalsProbe.searchIndex(url: url)
        XCTAssertEqual(coverage.photos, 3)
        XCTAssertEqual(coverage.pre2010, 2)
        XCTAssertEqual(coverage.searchPlaceOnUnlocatedPre2010, 1)
        XCTAssertEqual(coverage.searchDetectedTextOnUnlocatedPre2010, 1)
        XCTAssertEqual(coverage.searchCameraOnUnlocatedPre2010, 0)
        XCTAssertEqual(coverage.searchCategoryCounts["city"], 1)
        XCTAssertEqual(coverage.searchCategoryCounts["detectedText"], 1)
        XCTAssertEqual(coverage.searchCategoryCounts["label"], 1)
    }

    func testLiveProbeRecordsUnauthorizedSourcesWithoutThrowing() {
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).photoslibrary")
        let report = PhotosInternalsProbe.live(library: library)
        XCTAssertTrue(["missing", "unauthorized"].contains(report.photosSQLite.status))
        XCTAssertTrue(["missing", "unauthorized"].contains(report.searchIndex.status))
        XCTAssertTrue(["unauthorized", "ok"].contains(report.privatePhotoKit.status))
        XCTAssertFalse(PhotosInternalsProbe.summary(report).isEmpty)
    }

    func testCommandLineFlagIsRecognizedAndIgnoredOtherwise() {
        XCTAssertFalse(PhotosInternalsProbe.runCommandLineIfRequested(arguments: ["PhotoCurator"]))
    }

    func testWriteCreatesPrivateReport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("internals-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("report.json")
        let report = PhotosInternalsProbe.Report(
            generatedAt: 1,
            libraryPath: "/tmp/library",
            privatePhotoKit: .init(status: "unauthorized", detail: "denied", coverage: nil),
            photosSQLite: .init(status: "ok", detail: "fixture", coverage: .empty),
            searchIndex: .init(status: "missing", detail: "no leo.sqlite", coverage: nil)
        )
        try PhotosInternalsProbe.write(report, to: destination)
        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue ?? 0, 0o600)
        let decoded = try JSONDecoder().decode(PhotosInternalsProbe.Report.self, from: Data(contentsOf: destination))
        XCTAssertEqual(decoded.photosSQLite.status, "ok")
    }

    func testLiveInternalsProbeOnOwnerLibrary() throws {
        guard ProcessInfo.processInfo.environment["PHOTOCURATOR_LIVE_INTERNALS"] == "1" else {
            throw XCTSkip("Set PHOTOCURATOR_LIVE_INTERNALS=1 to query the owner Photos library")
        }
        let report = PhotosInternalsProbe.live(requestAccess: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-curator-internals-live.json")
        try PhotosInternalsProbe.write(report, to: destination)
        print(PhotosInternalsProbe.summary(report))
        print("LIVE_REPORT \(destination.path)")
        XCTAssertFalse(report.privatePhotoKit.status.isEmpty)
        XCTAssertFalse(report.photosSQLite.status.isEmpty)
        XCTAssertFalse(report.searchIndex.status.isEmpty)
    }

    private func makePhotosFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photos-fixture-\(UUID().uuidString).sqlite")
        let db = try FixtureDB(url: url)
        try db.execute("""
            CREATE TABLE ZASSET (
                Z_PK INTEGER PRIMARY KEY,
                ZUUID TEXT,
                ZDATECREATED REAL,
                ZLATITUDE REAL,
                ZLONGITUDE REAL
            );
            CREATE TABLE ZADDITIONALASSETATTRIBUTES (
                Z_PK INTEGER PRIMARY KEY,
                ZASSET INTEGER,
                ZTITLE TEXT,
                ZTIMEZONENAME TEXT,
                ZTIMEZONEOFFSET INTEGER,
                ZINFERREDTIMEZONEOFFSET INTEGER,
                ZREVERSELOCATIONDATAISVALID INTEGER,
                ZREVERSELOCATIONDATA BLOB,
                ZIMPORTSESSIONID TEXT,
                ZEXIFTIMESTAMPSTRING TEXT,
                ZORIGINALFILENAME TEXT
            );
            """)
        let year2005 = Date(timeIntervalSince1970: 1_117_584_000).timeIntervalSince1970
            - PhotosInternalsProbe.coreDataEpoch
        let year2015 = Date(timeIntervalSince1970: 1_430_438_400).timeIntervalSince1970
            - PhotosInternalsProbe.coreDataEpoch
        try db.execute("""
            INSERT INTO ZASSET VALUES (1, 'old-titled', \(year2005), NULL, NULL);
            INSERT INTO ZASSET VALUES (2, 'old-blank', \(year2005), NULL, NULL);
            INSERT INTO ZASSET VALUES (3, 'old-gps', \(year2005), 49.84, 24.03);
            INSERT INTO ZASSET VALUES (4, 'new-blank', \(year2015), NULL, NULL);
            INSERT INTO ZASSET VALUES (5, 'old-zero-gps', \(year2005), 0, 0);
            INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES
                (1, 1, 'Kiev 2005', 'Europe/Kiev', 7200, NULL, 0, NULL, 'import-a', '2005:06:01 12:00:00', 'DSC_1.JPG');
            INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES
                (2, 2, NULL, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL);
            INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES
                (3, 3, 'Lviv', 'Europe/Kiev', 7200, NULL, 1, X'00', 'import-b', NULL, 'IMG_2.JPG');
            INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES
                (4, 4, 'Should ignore', NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL);
            INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES
                (5, 5, 'Glasgow', NULL, NULL, NULL, 0, NULL, NULL, NULL, 'DSC_9.JPG');
            """)
        db.close()
        return url
    }

    private func makeSignalsFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("signals-fixture-\(UUID().uuidString).sqlite")
        let db = try FixtureDB(url: url)
        let day1 = Date(timeIntervalSince1970: 1_117_584_000).timeIntervalSince1970
            - PhotosInternalsProbe.coreDataEpoch
        let day2 = day1 + 86_400 * 4
        let added = day1 + 86_400 * 6
        try db.execute("""
            CREATE TABLE ZASSET (
                Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZDATECREATED REAL,
                ZADDEDDATE REAL, ZLATITUDE REAL, ZLONGITUDE REAL, ZFILENAME TEXT
            );
            CREATE TABLE ZADDITIONALASSETATTRIBUTES (
                Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZTITLE TEXT,
                ZTIMEZONENAME TEXT, ZORIGINALFILENAME TEXT, ZCAMERAMAKE TEXT
            );
            CREATE TABLE ZPERSON (Z_PK INTEGER PRIMARY KEY, ZFULLNAME TEXT);
            CREATE TABLE ZDETECTEDFACE (
                Z_PK INTEGER PRIMARY KEY, ZASSETFORFACE INTEGER, ZPERSONFORFACE INTEGER, ZFACEGROUP INTEGER
            );
            CREATE TABLE ZGENERICALBUM (Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT);
            CREATE TABLE Z_34ASSETS (Z_34ALBUMS INTEGER, Z_34ASSETS INTEGER);
            INSERT INTO ZPERSON VALUES (1, 'Anna'), (2, 'Vanessa'), (3, NULL);
            INSERT INTO ZGENERICALBUM VALUES (1, 'Kiev 2005'), (2, 'Home');
            """)
        var inserts = ""
        for index in 1...10 {
            let name = String(format: "DSC_%04d.JPG", index)
            inserts += """
                INSERT INTO ZASSET VALUES (\(index), 'j\(index)', \(day1), \(added), NULL, NULL, '\(name)');
                INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES (\(index), \(index), 'Kiev 2005', 'Europe/Kiev', '\(name)', 'Canon');
                INSERT INTO ZDETECTEDFACE VALUES (\(index), \(index), 1, NULL);
                INSERT INTO Z_34ASSETS VALUES (1, \(index));
                """
            if index <= 8 {
                inserts += "INSERT INTO ZDETECTEDFACE VALUES (\(index + 20), \(index), 2, NULL);"
            }
        }
        inserts += """
            INSERT INTO ZASSET VALUES (11, 'p1', \(day2), \(added), NULL, NULL, 'IMG_0001.JPG');
            INSERT INTO ZASSET VALUES (12, 'p2', \(day2), \(added), NULL, NULL, 'IMG_0002.JPG');
            INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES (11, 11, NULL, 'Europe/Kiev', 'IMG_0001.JPG', 'Nokia');
            INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES (12, 12, NULL, 'Europe/Kiev', 'IMG_0002.JPG', 'Nokia');
            INSERT INTO ZDETECTEDFACE VALUES (40, 11, NULL, 99);
            INSERT INTO ZDETECTEDFACE VALUES (41, 12, NULL, 99);
            INSERT INTO Z_34ASSETS VALUES (2, 11);
            INSERT INTO Z_34ASSETS VALUES (2, 12);
            """
        try db.execute(inserts)
        db.close()
        return url
    }

    private func makeSearchFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-fixture-\(UUID().uuidString).sqlite")
        let db = try FixtureDB(url: url)
        let old = Int(Date(timeIntervalSince1970: 1_117_584_000).timeIntervalSince1970)
        let recent = Int(Date(timeIntervalSince1970: 1_430_438_400).timeIntervalSince1970)
        try db.execute("""
            CREATE TABLE assets (uuid_0 INT, uuid_1 INT, creationDate INT);
            CREATE TABLE groups (
                groupid INTEGER PRIMARY KEY,
                category INT,
                content_string TEXT
            );
            CREATE TABLE ga (groupid INT, assetid INT, PRIMARY KEY(groupid, assetid));
            INSERT INTO assets VALUES (1, 1, \(old));
            INSERT INTO assets VALUES (2, 2, \(old));
            INSERT INTO assets VALUES (3, 3, \(recent));
            INSERT INTO groups VALUES (10, 5, 'Kyiv');
            INSERT INTO groups VALUES (11, 1203, 'Вокзал');
            INSERT INTO groups VALUES (12, 1500, 'indoor');
            INSERT INTO ga VALUES (10, 1);
            INSERT INTO ga VALUES (11, 2);
            INSERT INTO ga VALUES (12, 3);
            """)
        db.close()
        return url
    }
}

@objc final class InternalsProbeAsset: NSObject {
    @objc let title: String
    @objc let filename: String
    @objc let timezoneName: String
    @objc let timezoneOffset: NSNumber

    init(title: String, filename: String, timezoneName: String, timezoneOffset: Int) {
        self.title = title
        self.filename = filename
        self.timezoneName = timezoneName
        self.timezoneOffset = NSNumber(value: timezoneOffset)
    }
}

private final class FixtureDB {
    private var db: OpaquePointer?

    init(url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw NSError(domain: "PhotosInternalsProbeTests", code: 1)
        }
        db = handle
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "PhotosInternalsProbeTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    func close() {
        sqlite3_close(db)
        db = nil
    }
}
