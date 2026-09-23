import XCTest
@testable import PhotoRelay

private actor FakeAlbums: CuratedAlbumAdapter {
    enum Recovery { case automatic, absent, conflicting }
    var calls = 0
    var receipt: CuratedAlbumReceipt?
    var failAfterEffect = false
    var recovery: Recovery = .automatic

    func configure(failAfterEffect: Bool = false, recovery: Recovery = .automatic,
                   receipt: CuratedAlbumReceipt? = nil) {
        self.failAfterEffect = failAfterEffect
        self.recovery = recovery
        self.receipt = receipt
    }

    func publish(_ request: CuratedPublicationRequest) async throws -> CuratedAlbumReceipt {
        calls += 1
        let value = CuratedAlbumReceipt(albumID: "managed", assetIDs: request.assetIDs)
        receipt = value
        if failAfterEffect { throw PublicationFailure.verificationPending }
        return value
    }

    func recover(_ request: CuratedPublicationRequest) async throws -> CuratedAlbumRecovery {
        switch recovery {
        case .automatic:
            return receipt.map(CuratedAlbumRecovery.confirmed) ?? .absent
        case .absent: return .absent
        case .conflicting: return .conflicting
        }
    }

    func callCount() -> Int { calls }
}

@MainActor
final class CuratedPublicationTests: XCTestCase {
    func testSuccessAndRestartNeverRepeatExternalEffect() async throws {
        let fixture = try await makeFixture()
        let albums = FakeAlbums()
        let durableRequest = request()
        _ = try await coordinator(fixture.store, albums).publish(durableRequest)
        _ = try await coordinator(fixture.store, albums).publish(request(operationID: UUID()))

        let calls = await albums.callCount()
        let pending = try await fixture.store.pendingPublications()
        let summaries = try await fixture.store.summaries()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(summaries.first?.inPhotos == true)
    }

    func testLostPhotoKitResponseIsRecoveredWithoutDuplicateAlbum() async throws {
        let fixture = try await makeFixture()
        let albums = FakeAlbums()
        await albums.configure(failAfterEffect: true)

        let receipt = try await coordinator(fixture.store, albums).publish(request())

        XCTAssertEqual(receipt.albumID, "managed")
        let calls = await albums.callCount()
        let summaries = try await fixture.store.summaries()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(summaries.first?.inPhotos == true)
    }

    func testForcedTerminationAfterApplyingRecoversConfirmedEffect() async throws {
        let fixture = try await makeFixture()
        let albums = FakeAlbums()
        let durableRequest = request()
        _ = try await fixture.store.preparePublication(durableRequest)
        try await fixture.store.markPublicationApplying(operationID: durableRequest.operationID)
        await albums.configure(receipt: CuratedAlbumReceipt(albumID: "managed", assetIDs: durableRequest.assetIDs))

        _ = try await coordinator(fixture.store, albums).publish(request(operationID: UUID()))

        let calls = await albums.callCount()
        let summaries = try await fixture.store.summaries()
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(summaries.first?.inPhotos == true)
    }

    func testConfirmedAbsenceAfterCrashRetriesThroughIdempotentAdapter() async throws {
        let fixture = try await makeFixture()
        let albums = FakeAlbums()
        let durableRequest = request()
        _ = try await fixture.store.preparePublication(durableRequest)
        try await fixture.store.markPublicationApplying(operationID: durableRequest.operationID)

        _ = try await coordinator(fixture.store, albums).publish(request(operationID: UUID()))

        let calls = await albums.callCount()
        let summaries = try await fixture.store.summaries()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(summaries.first?.inPhotos == true)
    }

    func testConflictingDestinationFailsWithoutApplyingAgain() async throws {
        let fixture = try await makeFixture()
        let albums = FakeAlbums()
        let durableRequest = request()
        _ = try await fixture.store.preparePublication(durableRequest)
        try await fixture.store.markPublicationApplying(operationID: durableRequest.operationID)
        await albums.configure(recovery: .conflicting)

        do {
            _ = try await coordinator(fixture.store, albums).publish(request(operationID: UUID()))
            XCTFail("Expected destination conflict")
        } catch {
            XCTAssertEqual(error as? PublicationFailure, .destinationConflict)
        }
        let calls = await albums.callCount()
        let summaries = try await fixture.store.summaries()
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(summaries.first?.inPhotos == true)
    }

    func testMomentRefreshPreservesSagaAndPublishedMarker() async throws {
        let fixture = try await makeFixture()
        let albums = FakeAlbums()
        _ = try await coordinator(fixture.store, albums).publish(request())

        try await fixture.store.synchronize(moments: [fixture.moment])
        _ = try await coordinator(fixture.store, albums).publish(request(operationID: UUID()))

        let calls = await albums.callCount()
        let summaries = try await fixture.store.summaries()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(summaries.first?.inPhotos == true)
    }

    func testCancellationBeforeExternalEffectLeavesRecoverableOperation() async throws {
        let fixture = try await makeFixture()
        let albums = FakeAlbums()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await coordinator(fixture.store, albums).publish(request())
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await albums.callCount()
        let pending = try await fixture.store.pendingPublications()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(pending.count, 1)
    }

    func testChangedRequestCannotReplaceDurableIntent() async throws {
        let fixture = try await makeFixture()
        let albums = FakeAlbums()
        let first = request()
        _ = try await fixture.store.preparePublication(first)
        let changed = CuratedPublicationRequest(operationID: UUID(), momentID: first.momentID,
            title: "Different", assetIDs: first.assetIDs)

        do { _ = try await coordinator(fixture.store, albums).publish(changed); XCTFail("Expected conflict") }
        catch { XCTAssertEqual(error as? PublicationFailure, .conflictingOperation) }
        let calls = await albums.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testRequestValidationAndAutoPublishEligibility() throws {
        let invalid = CuratedPublicationRequest(operationID: UUID(), momentID: "moment-1", title: "Trip",
            keyAssetID: "external", assetIDs: ["asset-1"])
        XCTAssertThrowsError(try invalid.validate())

        let photo = IndexedPhoto(id: "photo-1", created: Date(), modified: Date(), latitude: 52,
            longitude: 4, favorite: false, width: 100, height: 100)
        let ready = PhotoMoment(id: "ready", start: Date(), end: Date(), photos: [photo], groupingState: .ready)
        let reviewed = PhotoMoment(id: "reviewed", start: Date(), end: Date(), photos: [photo], groupingState: .reviewed)
        XCTAssertFalse(MomentDisplayEligibility.isAutoPublishEligible(ready, decisions: [:], userAuthored: false))
        XCTAssertTrue(MomentDisplayEligibility.isAutoPublishEligible(reviewed, decisions: [:], userAuthored: false))
    }

    private func coordinator(_ store: CatalogV2Store, _ albums: FakeAlbums) -> PublicationCoordinator {
        PublicationCoordinator(store: store, adapter: albums, delay: { _ in })
    }

    private func request(operationID: UUID = UUID()) -> CuratedPublicationRequest {
        CuratedPublicationRequest(operationID: operationID, momentID: "stable-test-moment",
            title: "Trip", assetIDs: ["a", "b"])
    }

    private func makeFixture() async throws -> (store: CatalogV2Store, moment: PhotoMoment) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogV2Store(url: root.appendingPathComponent("catalog.sqlite3"))
        let photos = ["a", "b"].map { id in
            IndexedPhoto(id: id, created: Date(), modified: Date(), latitude: nil, longitude: nil,
                favorite: false, width: 100, height: 100)
        }
        let moment = PhotoMoment(id: "stable-test-moment", start: Date(), end: Date(), photos: photos,
            selection: MomentSelection(selected: photos.map(\.id), pending: [], similar: []), groupingState: .reviewed)
        try await store.synchronize(moments: [moment])
        return (store, moment)
    }
}
