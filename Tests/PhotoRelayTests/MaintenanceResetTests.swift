import XCTest
@testable import PhotoRelay

private actor ResetPhotosFake: CuratorResetPhotos {
    var containers = Set(["root", "year", "album"])
    var counts = PhotoLibraryAssetCounts(assets: 100, favorites: 10)
    var deleteCalls = 0
    var staleAbsenceReads = 0

    func assetCounts() -> PhotoLibraryAssetCounts { counts }
    func verifyOwnership(of requested: [ManagedPhotoContainer]) throws {
        guard requested.allSatisfy({ containers.contains($0.id) }) else {
            throw PublicationFailure.destinationConflict
        }
    }
    func deleteContainers(_ requested: [ManagedPhotoContainer]) {
        deleteCalls += 1
        containers.subtract(requested.map(\.id))
    }
    func containersAreAbsent(_ requested: [ManagedPhotoContainer]) -> Bool {
        if staleAbsenceReads > 0 {
            staleAbsenceReads -= 1
            return false
        }
        return requested.allSatisfy { !containers.contains($0.id) }
    }
    func calls() -> Int { deleteCalls }
    func deferAbsence(reads: Int) { staleAbsenceReads = reads }
}

private actor ResetLocalFake: CuratorResetLocalData {
    var erases = 0
    var recreates = 0
    func eraseCuratorData() { erases += 1 }
    func recreateCatalog() { recreates += 1 }
    func counts() -> (Int, Int) { (erases, recreates) }
}

@MainActor
final class MaintenanceResetTests: XCTestCase {
    func testManagedFolderRejectsAnyUnownedChild() {
        let managed = Set(["root", "year", "album"])
        XCTAssertTrue(containsOnlyManagedContainers(Set(["year", "album"]), managedIDs: managed))
        XCTAssertFalse(containsOnlyManagedContainers(Set(["album", "personal"]), managedIDs: managed))
    }

    func testResetIsDurableIdempotentAndPreservesPhotoCounts() async throws {
        let fixture = fixture()
        let operation = try await fixture.coordinator.begin(containers: containers(), reclaimableBytes: 42)
        XCTAssertEqual(operation.phase, .requested)

        let completed = try await fixture.coordinator.resume()
        XCTAssertEqual(completed.phase, .completed)
        _ = try await fixture.coordinator.resume()

        let deleteCalls = await fixture.photos.calls()
        XCTAssertEqual(deleteCalls, 1)
        let localCounts = await fixture.local.counts()
        XCTAssertEqual(localCounts.0, 1)
        XCTAssertEqual(localCounts.1, 1)
    }

    func testResumeContinuesAfterContainerDeletion() async throws {
        let fixture = fixture()
        var operation = try await fixture.coordinator.begin(containers: containers(), reclaimableBytes: 42)
        operation.phase = .deletingContainers
        try fixture.journal.save(operation)
        await fixture.photos.deleteContainers(containers())
        operation.phase = .verifyingPhotos
        try fixture.journal.save(operation)

        let completed = try await fixture.coordinator.resume()

        XCTAssertEqual(completed.phase, .completed)
        let localCounts = await fixture.local.counts()
        XCTAssertEqual(localCounts.0, 1)
        XCTAssertEqual(localCounts.1, 1)
    }

    func testChangedAssetOrFavoriteCountStopsBeforeLocalErasure() async throws {
        let fixture = fixture()
        _ = try await fixture.coordinator.begin(containers: containers(), reclaimableBytes: 42)
        await fixture.photos.setCounts(PhotoLibraryAssetCounts(assets: 99, favorites: 10))

        do { _ = try await fixture.coordinator.resume(); XCTFail("Expected count mismatch") }
        catch { XCTAssertEqual(error as? PublicationFailure, .destinationConflict) }
        let localCounts = await fixture.local.counts()
        XCTAssertEqual(localCounts.0, 0)
        XCTAssertEqual(localCounts.1, 0)
    }

    func testPhotosOnlyRunStopsAtSafeRestartBoundary() async throws {
        let fixture = fixture()
        _ = try await fixture.coordinator.begin(containers: containers(), reclaimableBytes: 42)

        let operation = try await fixture.coordinator.resumeThroughPhotos()

        XCTAssertEqual(operation.phase, .erasingLocalData)
        let localCounts = await fixture.local.counts()
        XCTAssertEqual(localCounts.0, 0)
        XCTAssertEqual(localCounts.1, 0)
    }

    func testPhotosVerificationRetriesStaleReadsBeforeAdvancing() async throws {
        let fixture = fixture()
        await fixture.photos.deferAbsence(reads: 2)
        _ = try await fixture.coordinator.begin(containers: containers(), reclaimableBytes: 42)

        let operation = try await fixture.coordinator.resumeThroughPhotos()

        XCTAssertEqual(operation.phase, .erasingLocalData)
    }

    func testLaunchBootstrapErasesGeneratedStateButPreservesPreferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let support = root.appendingPathComponent("support")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data([1]).write(to: support.appendingPathComponent("old"))
        try Data([2]).write(to: cache.appendingPathComponent("old"))
        defaults.set(["moment": "Mine"], forKey: "curator.momentTitles.v1")
        defaults.set(["Home"], forKey: "curator.meaningfulPlaces.v1")
        defaults.set(1.25, forKey: "curator.fontSizeScale")
        let journal = CuratorResetJournal(url: root.appendingPathComponent("journal/reset.json"))
        try journal.save(CuratorResetOperation(id: UUID(), phase: .erasingLocalData,
            containers: [], before: PhotoLibraryAssetCounts(assets: 1, favorites: 1),
            reclaimableBytes: 2, startedAt: Date(), updatedAt: Date()))
        let local = CuratorLocalDataReset(supportRoot: support, cacheRoot: cache, defaults: defaults)

        let completed = try CuratorResetBootstrap.finishLocalResetIfNeeded(
            journal: journal, localData: local)

        XCTAssertEqual(completed?.phase, .completed)
        XCTAssertNil(defaults.object(forKey: "curator.momentTitles.v1"))
        XCTAssertNotNil(defaults.object(forKey: "curator.meaningfulPlaces.v1"))
        XCTAssertEqual(defaults.double(forKey: "curator.fontSizeScale"), 1.25)
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("index.sqlite3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent(CatalogV2Migrator.catalogName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("old").path))
    }

    private func fixture() -> (coordinator: CuratorResetCoordinator, photos: ResetPhotosFake,
                               local: ResetLocalFake, journal: CuratorResetJournal) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let photos = ResetPhotosFake()
        let local = ResetLocalFake()
        let journal = CuratorResetJournal(url: root.appendingPathComponent("reset.json"))
        return (CuratorResetCoordinator(photos: photos, localData: local, journal: journal,
                    delay: { _ in }),
                photos, local, journal)
    }

    private func containers() -> [ManagedPhotoContainer] {
        [ManagedPhotoContainer(id: "root", kind: .root, parentID: nil),
         ManagedPhotoContainer(id: "year", kind: .year, parentID: "root"),
         ManagedPhotoContainer(id: "album", kind: .album, parentID: "year")]
    }
}

private extension ResetPhotosFake {
    func setCounts(_ value: PhotoLibraryAssetCounts) { counts = value }
}
