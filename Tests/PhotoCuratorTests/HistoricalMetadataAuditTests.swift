import XCTest
@testable import PhotoCurator

final class HistoricalMetadataAuditTests: XCTestCase {
    func testAuthorizationLabelsAreStable() {
        XCTAssertEqual(HistoricalMetadataAudit.authorizationLabel(.notDetermined), "notDetermined")
        XCTAssertEqual(HistoricalMetadataAudit.authorizationLabel(.denied), "denied")
        XCTAssertEqual(HistoricalMetadataAudit.authorizationLabel(.authorized), "authorized")
        XCTAssertEqual(HistoricalMetadataAudit.authorizationLabel(.restricted), "restricted")
        XCTAssertEqual(HistoricalMetadataAudit.authorizationLabel(.limited), "limited")
    }

    func testWriteOverwritesExistingFileAndCreatesPrivateReport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("photocurator-historical-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("report.json")
        try Data("{}".utf8).write(to: destination)
        let report = HistoricalMetadataAudit.Report(
            authorizationStatus: "authorized",
            photos: 3,
            located: 0,
            favorites: 1,
            adjustmentResources: 0,
            hasAdjustments: 0,
            withAdjustmentTimestamp: 0,
            withAddedDate: 2,
            addedDateDiffersFromCapture: 1,
            ratedPhotos: 0,
            ratingCounts: [:],
            mediaSubtypeCounts: ["none": 3],
            burstPhotos: 0,
            contentTypeCounts: ["public.jpeg": 3],
            sourceTypes: ["1": 3],
            fileExtensions: ["jpg": 3],
            albumCoveredPhotos: 2,
            outsideCuratorCoveredPhotos: 2,
            namedAlbums: 1,
            albumsWithLocationNames: 1,
            albumsWithApproximateLocation: 0,
            photosWithCaption: 1,
            photosWithKeywords: 0,
            photosWithOriginalFilename: 3,
            albumStoryCandidates: [["title": "New York", "score": 0.8]],
            albums: [["title": "Family 2004", "historicalPhotos": 2]],
            extendedMetadata: [["assetID": "x", "caption": "beach"]]
        )
        try HistoricalMetadataAudit.write(report, to: destination)

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let mode = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue ?? 0, 0o600)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
        XCTAssertEqual(json?["photos"] as? Int, 3)
        XCTAssertEqual(json?["withAddedDate"] as? Int, 2)
        XCTAssertEqual(json?["albumsWithLocationNames"] as? Int, 1)
        XCTAssertEqual((json?["albumStoryCandidates"] as? [[String: Any]])?.count, 1)
        XCTAssertTrue((json?["privacy"] as? String)?.contains("Do not share") == true)

        try HistoricalMetadataAudit.write(report, to: destination)
        XCTAssertEqual(
            (try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])?["photos"] as? Int,
            3
        )
    }

    func testUnauthorizedErrorMentionsSystemSettings() {
        let error = HistoricalMetadataAudit.AuditError.unauthorized(.denied)
        XCTAssertTrue(error.localizedDescription.contains("denied"))
        XCTAssertTrue(error.localizedDescription.contains("System Settings"))
    }

    func testAlbumStoryCandidatesPreferPlaceLikeOutsideCuratorAlbums() {
        let albums: [[String: Any]] = [
            ["title": "Photo Curator leftovers", "historicalPhotos": 200, "underPhotoCurator": true,
             "folderNames": ["Photo Curator"], "locationNames": [], "hasApproximateLocation": false],
            ["title": "Tiny", "historicalPhotos": 5, "underPhotoCurator": false,
             "folderNames": ["2004"], "locationNames": [], "hasApproximateLocation": false],
            ["title": "New York", "historicalPhotos": 120, "underPhotoCurator": false,
             "folderNames": ["USA", "2000-2005"], "locationNames": ["New York"], "hasApproximateLocation": true],
            ["title": "Andrey_Dulzon", "historicalPhotos": 90, "underPhotoCurator": false,
             "folderNames": ["Slavsko"], "locationNames": [], "hasApproximateLocation": false]
        ]
        let candidates = UnlocatedAlbumStoryCandidates.propose(from: albums, minimumPhotos: 40)
        XCTAssertEqual(candidates.first?.title, "New York")
        XCTAssertTrue(candidates.first?.hasAlbumLocation == true)
        XCTAssertFalse(candidates.contains { $0.title.contains("Photo Curator") })
        XCTAssertFalse(candidates.contains { $0.title == "Tiny" })
    }
}

final class VisualContentRevisionTests: XCTestCase {
    func testVisualContentRevisionIgnoresModificationDate() {
        let first = IndexedPhoto(id: "a", created: Date(timeIntervalSince1970: 10),
                                 modified: Date(timeIntervalSince1970: 20),
                                 latitude: nil, longitude: nil, favorite: false, width: 100, height: 200)
        let second = IndexedPhoto(id: "a", created: Date(timeIntervalSince1970: 10),
                                  modified: Date(timeIntervalSince1970: 99),
                                  latitude: nil, longitude: nil, favorite: false, width: 100, height: 200)
        XCTAssertEqual(first.visualContentRevision, second.visualContentRevision)
        XCTAssertNotEqual(first.analysisRevision, second.analysisRevision)
    }

    func testVisualContentRevisionChangesWithAdjustments() {
        let plain = IndexedPhoto(id: "a", created: nil, modified: nil, latitude: nil, longitude: nil,
                                 favorite: false, width: 10, height: 10)
        var edited = plain
        edited.hasAdjustments = true
        edited.adjustmentTimestamp = Date(timeIntervalSince1970: 50)
        edited.adjustmentFormatIdentifier = "com.apple.photo"
        XCTAssertNotEqual(plain.visualContentRevision, edited.visualContentRevision)
    }

    func testLegacyIndexedPhotoPayloadDecodesWithoutAdjustmentFields() throws {
        let legacy = """
        {"id":"a","created":1,"modified":2,"latitude":null,"longitude":null,"favorite":false,"width":8,"height":8}
        """.data(using: .utf8)!
        let photo = try JSONDecoder().decode(IndexedPhoto.self, from: legacy)
        XCTAssertEqual(photo.id, "a")
        XCTAssertEqual(photo.width, 8)
        XCTAssertFalse(photo.hasAdjustments)
        XCTAssertEqual(photo.rating, 0)
        XCTAssertNil(photo.addedDate)
        XCTAssertNil(photo.burstIdentifier)
    }

    func testAdoptAnalysisRevisionPreservesCompletedResult() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("index.sqlite3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try CuratorStore(url: url)
        let original = IndexedPhoto(id: "a", created: Date(timeIntervalSince1970: 1),
                                    modified: Date(timeIntervalSince1970: 1),
                                    latitude: nil, longitude: nil, favorite: false, width: 8, height: 8)
        try store.save([original], generation: "g1")
        try store.enqueueAnalysis(asset: "a", revision: original.analysisRevision, analyzer: "v1")
        let job = try store.claimAnalysis()!
        XCTAssertTrue(try store.finishAnalysis(job, result: Data("vision".utf8)))

        let updated = IndexedPhoto(id: "a", created: Date(timeIntervalSince1970: 1),
                                   modified: Date(timeIntervalSince1970: 2),
                                   latitude: nil, longitude: nil, favorite: false, width: 8, height: 8)
        XCTAssertEqual(original.visualContentRevision, updated.visualContentRevision)
        XCTAssertTrue(try store.adoptAnalysisRevision(asset: "a", from: original.analysisRevision,
                                                      to: updated.analysisRevision, analyzer: "v1"))
        XCTAssertEqual(try store.analysisResult(asset: "a", revision: updated.analysisRevision, analyzer: "v1"),
                       Data("vision".utf8))
        XCTAssertNil(try store.analysisResult(asset: "a", revision: original.analysisRevision, analyzer: "v1"))
    }
}
