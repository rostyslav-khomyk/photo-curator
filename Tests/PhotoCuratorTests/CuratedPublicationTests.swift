import XCTest
@testable import PhotoCurator

private actor FakeAlbums: CuratedAlbumAdapter {
    enum Recovery { case automatic, absent, conflicting }
    var calls = 0
    var receipt: CuratedAlbumReceipt?
    var failAfterEffect = false
    var recovery: Recovery = .automatic
    var recoverWithoutOwnership = false

    func configure(failAfterEffect: Bool = false, recovery: Recovery = .automatic,
                   receipt: CuratedAlbumReceipt? = nil, recoverWithoutOwnership: Bool = false) {
        self.failAfterEffect = failAfterEffect
        self.recovery = recovery
        self.receipt = receipt
        self.recoverWithoutOwnership = recoverWithoutOwnership
    }

    var requests: [CuratedPublicationRequest] = []

    func publish(_ request: CuratedPublicationRequest) async throws -> CuratedAlbumReceipt {
        calls += 1
        requests.append(request)
        let value = receipt.map { CuratedAlbumReceipt(albumID: $0.albumID, assetIDs: request.assetIDs,
            rootFolderID: $0.rootFolderID, yearFolderID: $0.yearFolderID, storyFolderID: $0.storyFolderID,
            createdContainerIDs: $0.createdContainerIDs) }
            ?? CuratedAlbumReceipt(albumID: "managed", assetIDs: request.assetIDs)
        receipt = value
        if failAfterEffect { throw PublicationFailure.verificationPending }
        return value
    }

    func recover(_ request: CuratedPublicationRequest) async throws -> CuratedAlbumRecovery {
        switch recovery {
        case .automatic:
            guard let receipt else { return .absent }
            if recoverWithoutOwnership {
                return .confirmed(CuratedAlbumReceipt(albumID: receipt.albumID, assetIDs: receipt.assetIDs,
                    rootFolderID: receipt.rootFolderID, yearFolderID: receipt.yearFolderID))
            }
            return .confirmed(receipt)
        case .absent: return .absent
        case .conflicting: return .conflicting
        }
    }

    func callCount() -> Int { calls }
    func recordedRequests() -> [CuratedPublicationRequest] { requests }
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

    func testPublicationPersistsOnlyContainersCreatedByThisApp() async throws {
        let fixture = try await makeFixture()
        let albums = FakeAlbums()
        await albums.configure(receipt: CuratedAlbumReceipt(albumID: "album", assetIDs: ["a", "b"],
            rootFolderID: "root", yearFolderID: "year", storyFolderID: "story",
            createdContainerIDs: ["year", "story", "album"]),
            recoverWithoutOwnership: true)

        _ = try await coordinator(fixture.store, albums).publish(request())

        let containers = try await fixture.store.managedPhotoContainers()
        XCTAssertEqual(containers, [
            ManagedPhotoContainer(id: "album", kind: .album, parentID: "story"),
            ManagedPhotoContainer(id: "story", kind: .story, parentID: "year"),
            ManagedPhotoContainer(id: "year", kind: .year, parentID: "root")
        ])
    }

    func testPublicationFallsBackToYearParentWhenStoryFolderAbsent() async throws {
        let fixture = try await makeFixture()
        let albums = FakeAlbums()
        await albums.configure(receipt: CuratedAlbumReceipt(albumID: "album", assetIDs: ["a", "b"],
            rootFolderID: "root", yearFolderID: "year",
            createdContainerIDs: ["year", "album"]),
            recoverWithoutOwnership: true)

        _ = try await coordinator(fixture.store, albums).publish(request())

        let containers = try await fixture.store.managedPhotoContainers()
        XCTAssertEqual(containers, [
            ManagedPhotoContainer(id: "album", kind: .album, parentID: "year"),
            ManagedPhotoContainer(id: "year", kind: .year, parentID: "root")
        ])
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

    func testChangedMomentAfterSuccessUpdatesTheSavedAlbumInPlace() async throws {
        let fixture = try await makeFixture()
        let albums = FakeAlbums()
        await albums.configure(receipt: CuratedAlbumReceipt(albumID: "album", assetIDs: ["a", "b"],
            rootFolderID: "root", yearFolderID: "year", storyFolderID: "story",
            createdContainerIDs: ["root", "year", "story", "album"]))
        _ = try await coordinator(fixture.store, albums).publish(request())

        let changed = CuratedPublicationRequest(operationID: UUID(), momentID: "stable-test-moment",
            title: "Renamed trip", storyTitle: "Summer Journey", assetIDs: ["a"])
        await albums.configure(receipt: CuratedAlbumReceipt(albumID: "album", assetIDs: ["a"],
            rootFolderID: "root", yearFolderID: "year", storyFolderID: "story-2",
            createdContainerIDs: ["story-2"]))
        let receipt = try await coordinator(fixture.store, albums).publish(changed)

        let requests = await albums.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].targetAlbumID)
        XCTAssertEqual(requests[1].targetAlbumID, "album")
        XCTAssertEqual(receipt.albumID, "album")
        let saved = try await fixture.store.publishedRequest(momentID: "stable-test-moment")
        XCTAssertEqual(saved?.title, "Renamed trip")
        XCTAssertEqual(saved?.assetIDs, ["a"])
        let containers = try await fixture.store.managedPhotoContainers()
        XCTAssertTrue(containers.contains(ManagedPhotoContainer(id: "album", kind: .album, parentID: "story-2")))

        _ = try await coordinator(fixture.store, albums).publish(changed.updating(albumID: nil))
        let callsAfterNoOp = await albums.callCount()
        XCTAssertEqual(callsAfterNoOp, 2, "An unchanged Moment must not touch Photos again")
    }

    func testSameContentIgnoresOperationAndAssetOrder() {
        let first = CuratedPublicationRequest(operationID: UUID(), momentID: "m", title: "Trip", assetIDs: ["a", "b"])
        let reordered = CuratedPublicationRequest(operationID: UUID(), momentID: "m", title: "Trip",
            assetIDs: ["b", "a"], targetAlbumID: "album")
        let moved = CuratedPublicationRequest(operationID: UUID(), momentID: "m", title: "Trip",
            storyTitle: "Other Journey", assetIDs: ["a", "b"])
        XCTAssertTrue(first.hasSameContent(as: reordered))
        XCTAssertFalse(first.hasSameContent(as: moved))
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
