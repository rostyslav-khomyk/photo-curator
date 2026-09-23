import Foundation
import XCTest
@testable import PhotoRelay

private actor GooglePhotosServiceFake: GooglePhotosServicing {
    var mediaIDs: Set<String> = ["old"]
    var events: [String] = []
    var createError: Error?

    func failCreates(with error: Error) { createError = error }

    func accountIdentifier() -> String { "account" }
    func listAlbums() -> [GoogleAlbum] {
        [GoogleAlbum(id: "album", title: "Family", mediaItemsCount: String(mediaIDs.count))]
    }
    func albumMediaIDs(_ albumID: String) -> Set<String> {
        events.append("read")
        return mediaIDs
    }
    func existingMediaIDs(_ ids: Set<String>) -> Set<String> { ids.intersection(mediaIDs) }
    func createAlbum(title: String) -> String { "created" }
    func uploadBytes(at file: URL) -> String {
        events.append("upload")
        return "upload-token"
    }
    func createMedia(uploadToken: String, filename: String) throws -> String {
        events.append("create-media")
        if let createError { throw createError }
        return "new"
    }
    func changeAlbum(_ albumID: String, mediaIDs: Set<String>, removing: Bool) {
        events.append(removing ? "remove" : "add")
        if removing { self.mediaIDs.subtract(mediaIDs) }
        else { self.mediaIDs.formUnion(mediaIDs) }
    }
}

final class NativeGoogleSyncTests: XCTestCase {
    func testReplacementAddsAndVerifiesBeforeRemovingOldMembership() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("photo.jpg")
        try Data("photo bytes".utf8).write(to: photo)
        let service = GooglePhotosServiceFake()
        let sync = try NativeGoogleSync(client: service, ledgerURL: directory.appendingPathComponent("uploads.sqlite3"))
        let review = try await sync.prepare(
            items: [ExportedPhotosItem(path: photo.path, album: "Source")],
            choices: ["Source": .init(id: "album", title: nil)]
        )

        try await sync.start(token: review.token, replace: true, skipUnresolved: false)
        for _ in 0..<100 {
            if await !sync.snapshot().running { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let snapshot = await sync.snapshot()
        let events = await service.events
        let finalMediaIDs = await service.mediaIDs
        XCTAssertTrue(snapshot.succeeded, snapshot.error ?? "Sync did not succeed")
        XCTAssertEqual(finalMediaIDs, ["new"])
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "add")),
                          try XCTUnwrap(events.firstIndex(of: "remove")))
        XCTAssertGreaterThan(events.filter { $0 == "read" }.count, 2)
    }

    func testAmbiguousMediaCreateIsRecordedAndNotRetried() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("photo.jpg")
        try Data("photo bytes".utf8).write(to: photo)
        let service = GooglePhotosServiceFake()
        await service.failCreates(with: NativeGooglePhotosError.rejected(500, "uncertain"))
        let ledger = directory.appendingPathComponent("uploads.sqlite3")
        let sync = try NativeGoogleSync(client: service, ledgerURL: ledger)
        let item = ExportedPhotosItem(path: photo.path, album: "Source")
        let choices = ["Source": NativeGoogleSync.DestinationChoice(id: "album", title: nil)]
        let review = try await sync.prepare(items: [item], choices: choices)
        try await sync.start(token: review.token, replace: false, skipUnresolved: false)
        for _ in 0..<100 {
            if await !sync.snapshot().running { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let secondSync = try NativeGoogleSync(client: service, ledgerURL: ledger)
        let secondReview = try await secondSync.prepare(items: [item], choices: choices)
        let events = await service.events

        XCTAssertEqual(secondReview.unresolvedFiles, [photo.path])
        XCTAssertEqual(events.filter { $0 == "create-media" }.count, 1)
    }
}
