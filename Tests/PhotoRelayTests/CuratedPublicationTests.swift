import XCTest
@testable import PhotoRelay

@MainActor
private final class FakeAlbums: CuratedAlbumAdapter {
    var calls = 0
    var receipt: CuratedAlbumReceipt?
    var failAfterEffect = false
    func publish(_ request: CuratedPublicationRequest) async throws -> CuratedAlbumReceipt {
        calls += 1
        let value = CuratedAlbumReceipt(albumID: "managed", assetIDs: request.assetIDs)
        receipt = value
        if failAfterEffect { throw PublicationFailure.uncertainPublication }
        return value
    }
    func recover(_ request: CuratedPublicationRequest) async throws -> CuratedAlbumReceipt? { receipt }
}

@MainActor
private final class FakeUpload: CuratedUploadAdapter {
    var calls = 0
    var receipt: String?
    var failAfterEffect = false
    func upload(_ album: CuratedAlbumReceipt, operationID: UUID) async throws -> String {
        calls += 1
        receipt = "google-receipt"
        if failAfterEffect { throw PublicationFailure.uncertainUpload }
        return receipt!
    }
    func recover(operationID: UUID) async throws -> String? { receipt }
}

@MainActor
final class CuratedPublicationTests: XCTestCase {
    func testSidecarLockRejectsSecondOwnerAndReleases() throws {
        let path = url(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var first: PublicationJournalLock? = try PublicationJournalLock(journal: path)
        try withExtendedLifetime(first) {
            XCTAssertThrowsError(try PublicationJournalLock(journal: path))
        }
        first = nil
        XCTAssertNoThrow(try PublicationJournalLock(journal: path))
    }

    func testStaleInstanceReloadsConfirmedReceipt() async throws {
        let path = url(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let first = try CuratedPublication(journal: path), stale = try CuratedPublication(journal: path)
        let albums = FakeAlbums(), request = request()
        _ = try await first.publish(request, adapter: albums)
        _ = try await stale.publish(request, adapter: albums)
        XCTAssertEqual(albums.calls, 1)
    }

    func testCancellationBeforeExternalEffect() async throws {
        let path = url(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let workflow = try CuratedPublication(journal: path), albums = FakeAlbums(), request = request()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await workflow.publish(request, adapter: albums)
        }
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(albums.calls, 0)
    }
    func testCorruptJournalFailsClosed() throws {
        let path = url(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: path)
        XCTAssertThrowsError(try CuratedPublication(journal: path))
    }

    func testUnknownUploadIsNotRetried() async throws {
        let path = url(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let workflow = try CuratedPublication(journal: path), albums = FakeAlbums(), upload = FakeUpload()
        _ = try await workflow.publish(request(), adapter: albums)
        upload.failAfterEffect = true
        do { _ = try await workflow.sync(adapter: upload) } catch {}
        upload.receipt = nil
        do { _ = try await workflow.sync(adapter: upload); XCTFail() }
        catch { XCTAssertEqual(error as? PublicationFailure, .uncertainUpload) }
        XCTAssertEqual(upload.calls, 1)
    }
    private func url() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("journal.json") }
    private func request() -> CuratedPublicationRequest {
        CuratedPublicationRequest(operationID: UUID(), momentID: "stable-test-moment", title: "Trip", assetIDs: ["a", "b"])
    }

    func testSuccessAndRestartNeverRepeatEffects() async throws {
        let url = url(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let workflow = try CuratedPublication(journal: url), albums = FakeAlbums(), upload = FakeUpload()
        let request = request()
        _ = try await workflow.publish(request, adapter: albums)
        _ = try await workflow.sync(adapter: upload)
        let restored = try CuratedPublication(journal: url)
        _ = try await restored.publish(request, adapter: albums)
        _ = try await restored.sync(adapter: upload)
        XCTAssertEqual(albums.calls, 1); XCTAssertEqual(upload.calls, 1)
    }

    func testPublicationLostResponseRecoversWithoutCreatingAgain() async throws {
        let url = url(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let workflow = try CuratedPublication(journal: url), albums = FakeAlbums()
        albums.failAfterEffect = true
        let request = request()
        do { _ = try await workflow.publish(request, adapter: albums); XCTFail() } catch {}
        let restored = try CuratedPublication(journal: url)
        _ = try await restored.publish(request, adapter: albums)
        XCTAssertEqual(albums.calls, 1)
    }

    func testUncertainRecoveryDoesNotRecreate() async throws {
        let url = url(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let workflow = try CuratedPublication(journal: url), albums = FakeAlbums()
        albums.failAfterEffect = true
        let request = request()
        do { _ = try await workflow.publish(request, adapter: albums) } catch {}
        albums.receipt = nil
        do { _ = try await workflow.publish(request, adapter: albums); XCTFail() }
        catch { XCTAssertEqual(error as? PublicationFailure, .uncertainPublication) }
        XCTAssertEqual(albums.calls, 1)
    }

    func testConfirmedAbsentRecoveryRetriesOnce() async throws {
        let url = url(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let workflow = try CuratedPublication(journal: url), albums = FakeAlbums()
        albums.failAfterEffect = true
        let request = request()
        do { _ = try await workflow.publish(request, adapter: albums) } catch {}
        albums.receipt = nil
        albums.failAfterEffect = false

        let receipt = try await CuratedPublication(journal: url).publish(request, adapter: albums,
            retryAfterConfirmedAbsence: true)

        XCTAssertEqual(receipt.albumID, "managed")
        XCTAssertEqual(albums.calls, 2)
    }

    func testUploadFailureKeepsAlbumAndRecoversReceipt() async throws {
        let url = url(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let workflow = try CuratedPublication(journal: url), albums = FakeAlbums(), upload = FakeUpload()
        _ = try await workflow.publish(request(), adapter: albums)
        upload.failAfterEffect = true
        do { _ = try await workflow.sync(adapter: upload); XCTFail() } catch {}
        let state = await workflow.snapshot()
        XCTAssertEqual(state?.album?.albumID, "managed")
        _ = try await CuratedPublication(journal: url).sync(adapter: upload)
        XCTAssertEqual(upload.calls, 1)
        XCTAssertEqual(albums.calls, 1)
    }

    func testInvalidOrConflictingRequestIsRejected() async throws {
        let url = url(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let workflow = try CuratedPublication(journal: url), albums = FakeAlbums()
        let invalid = CuratedPublicationRequest(operationID: UUID(), momentID: "m", title: "", assetIDs: [])
        do { _ = try await workflow.publish(invalid, adapter: albums); XCTFail() } catch {}
        XCTAssertEqual(albums.calls, 0)
        _ = try await workflow.publish(request(), adapter: albums)
        do { _ = try await workflow.publish(request(), adapter: albums); XCTFail() }
        catch { XCTAssertEqual(error as? PublicationFailure, .conflictingOperation) }
        XCTAssertEqual(albums.calls, 1)
    }

    func testRequestWithDescriptionAndKeyAssetID() throws {
        let valid = CuratedPublicationRequest(
            operationID: UUID(),
            momentID: "moment-1",
            title: "LEGO Trip",
            description: "2 photos featuring scenes of LEGO",
            keyAssetID: "asset-1",
            date: Date(),
            assetIDs: ["asset-1", "asset-2"]
        )
        XCTAssertNoThrow(try valid.validate())
        XCTAssertEqual(valid.description, "2 photos featuring scenes of LEGO")
        XCTAssertEqual(valid.keyAssetID, "asset-1")
    }

    func testKeyAssetIDMustBeMemberOfAssetIDs() {
        let invalid = CuratedPublicationRequest(
            operationID: UUID(),
            momentID: "moment-1",
            title: "Trip",
            description: "Some story",
            keyAssetID: "external-asset",
            date: Date(),
            assetIDs: ["asset-1", "asset-2"]
        )
        XCTAssertThrowsError(try invalid.validate()) { error in
            XCTAssertEqual(error as? PublicationFailure, .invalidRequest)
        }
    }

    func testAutoPublishEligibilityAndPreservation() throws {
        let photo = IndexedPhoto(id: "photo-1", created: Date(), modified: Date(), latitude: 52.0, longitude: 4.0, favorite: false, width: 100, height: 100)
        let readyMoment = PhotoMoment(id: "m-ready", start: Date(), end: Date(), photos: [photo], groupingState: .ready)
        let reviewedMoment = PhotoMoment(id: "m-reviewed", start: Date(), end: Date(), photos: [photo], groupingState: .reviewed)
        let preparingMoment = PhotoMoment(id: "m-prep", start: Date(), end: Date(), photos: [photo], groupingState: .preparing)
        let publishedMoment = PhotoMoment(id: "m-pub", start: Date(), end: Date(), photos: [photo], groupingState: .ready, publishedAlbumID: "album-123", publishedDate: Date())

        XCTAssertFalse(MomentDisplayEligibility.isAutoPublishEligible(readyMoment, decisions: [:], userAuthored: false))
        XCTAssertTrue(MomentDisplayEligibility.isAutoPublishEligible(reviewedMoment, decisions: [:], userAuthored: false))
        XCTAssertFalse(MomentDisplayEligibility.isAutoPublishEligible(preparingMoment, decisions: [:], userAuthored: false))
        XCTAssertFalse(MomentDisplayEligibility.isAutoPublishEligible(publishedMoment, decisions: [:], userAuthored: false))

        let secondPhoto = IndexedPhoto(id: "photo-2", created: Date(), modified: Date(), latitude: 52.0, longitude: 4.0, favorite: false, width: 100, height: 100)
        let readyPair = PhotoMoment(id: "m-pair", start: Date(), end: Date(), photos: [photo, secondPhoto],
            selection: MomentSelection(selected: [photo.id, secondPhoto.id], pending: [], similar: []), groupingState: .ready)
        XCTAssertTrue(MomentDisplayEligibility.isAutoPublishEligible(readyPair, decisions: [:], userAuthored: false))

        // Ensure serialization preserves published state
        let catalog = MomentsCatalog(updated: Date(), moments: [publishedMoment])
        let encoded = try JSONEncoder().encode(catalog)
        let decoded = try JSONDecoder().decode(MomentsCatalog.self, from: encoded)
        XCTAssertEqual(decoded.moments.first?.publishedAlbumID, "album-123")
        XCTAssertNotNil(decoded.moments.first?.publishedDate)
    }
}
