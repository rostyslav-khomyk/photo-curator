import Foundation
import XCTest
@testable import PhotoRelay

final class CatalogV2Tests: XCTestCase {
    func testOptInCopiedRealCatalogMigration() async throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTO_CURATOR_PHASE1_CATALOG"] else {
            throw XCTSkip("Set PHOTO_CURATOR_PHASE1_CATALOG to rehearse the shadow migration")
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "local.icloudpd.photorelay"))
        let result = try await CatalogV2Migrator.migrateShadow(root: URL(fileURLWithPath: path), defaults: defaults)
        XCTAssertGreaterThan(result.assets, 100_000)
        XCTAssertGreaterThan(result.moments, 1_000)
        XCTAssertEqual(result.foreignKeyViolations, 0)
        let store = try CatalogV2Store(url: URL(fileURLWithPath: path).appendingPathComponent(CatalogV2Migrator.catalogName))
        try await store.prepareWorkspace(CatalogV2Migrator.loadInput(root: URL(fileURLWithPath: path), defaults: defaults))
        let summaryStart = Date()
        let summaries = try await store.summaries()
        let summaryDuration = Date().timeIntervalSince(summaryStart)
        print("Catalog v2 warm summary query: \(String(format: "%.3f", summaryDuration))s")
        XCTAssertLessThan(summaryDuration, 0.5)
        XCTAssertEqual(summaries.count, result.moments)
        let first = try XCTUnwrap(summaries.first)
        let detail = try await store.detail(momentID: first.id)
        XCTAssertEqual(detail?.photos.count, first.photoCount)
    }

    func testShadowMigrationIsCompleteQueryableAndIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent("index.sqlite3")
        let catalogURL = root.appendingPathComponent("catalog-v2.sqlite3")
        let first = photo("a", 100, favorite: true)
        let second = photo("b", 110)
        let third = photo("c", 200)
        let legacy = try CuratorStore(url: legacyURL)
        try legacy.save([first, second, third], generation: "complete")
        let narrative = MomentNarrative(version: MomentNarrative.version, headline: "A day together", deck: nil,
            story: "A short story", place: nil, date: "Today", confidence: 1, provenance: ["test"], state: .automatic)
        let moment = PhotoMoment(id: "moment-a", start: first.created!, end: second.created!, photos: [first, second],
            selection: MomentSelection(selected: ["a"], pending: [], similar: [], explanations: [:], alternatives: []),
            narrative: narrative, publishedAlbumID: "album-a", publishedDate: Date(timeIntervalSince1970: 300))
        let other = PhotoMoment(id: "moment-b", start: third.created!, end: third.created!, photos: [third])
        let place = MeaningfulPlace(label: "Home", address: "Example", latitude: 52, longitude: 4)
        let reviewed = GroupReviewArchive(revision: 1,
            groups: [SavedReviewGroup(id: "group-a", title: "Together", members: ["a", "missing"])])
        let input = CatalogV2MigrationInput(legacyIndex: legacyURL, moments: [moment, other],
            titles: ["moment-a": "Our title", "orphan-moment": "Keep me"],
            descriptions: ["moment-a": "Our description"], decisions: ["b": .exclude, "missing": .include],
            protectedMembership: ["moment-a": ["a", "b"]], places: [place], reviewedGroups: reviewed)
        let store = try CatalogV2Store(url: catalogURL)

        let firstResult = try await store.migrate(input)
        XCTAssertEqual(firstResult, CatalogV2Validation(assets: 3, moments: 2, memberships: 3,
            edits: 2, decisions: 2, places: 1, reviewedGroups: 1, publications: 1, foreignKeyViolations: 0))
        let repeatedResult = try await store.migrate(input)
        XCTAssertEqual(repeatedResult, firstResult)

        let summaries = try await store.summaries()
        XCTAssertEqual(summaries.map(\.id), ["moment-b", "moment-a"])
        XCTAssertEqual(summaries[1].headline, "Our title")
        XCTAssertEqual(summaries[1].photoCount, 2)
        XCTAssertEqual(summaries[1].highlightCount, 1)
        XCTAssertEqual(summaries[1].fallbackCoverAssetIDs, ["a", "b"])
        XCTAssertTrue(summaries[1].customized)
        XCTAssertTrue(summaries[1].inPhotos)
        let uploaded = try await store.summaries(googleUploadedAssetIDs: ["a"])
        XCTAssertTrue(try XCTUnwrap(uploaded.first(where: { $0.id == "moment-a" })).inGoogle)
        let loadedDetail = try await store.detail(momentID: "moment-a")
        let detail = try XCTUnwrap(loadedDetail)
        XCTAssertEqual(detail.photos.map(\.id), ["a", "b"])
        XCTAssertEqual(detail.selection?.selected, ["a"])
        XCTAssertEqual(detail.narrative?.headline, "A day together")
        XCTAssertEqual(detail.publishedAlbumID, "album-a")
        let identities = try await store.reconcileMomentIdentities(groups: [["a", "b", "c"]]) { "new" }
        XCTAssertEqual(identities.current.first?.id, "moment-a")
        XCTAssertEqual(identities.retiredIDs, ["moment-b"])

        var changed = moment
        changed.narrative = MomentNarrative(version: MomentNarrative.version, headline: "Updated", deck: nil,
            story: nil, place: nil, date: "Today", confidence: 1, provenance: ["test"], state: .automatic)
        try await store.synchronize(moments: [changed], activeMomentIDs: ["moment-a"])
        let refreshed = try await store.summaries()
        XCTAssertEqual(refreshed.map(\.id), ["moment-a"])
        XCTAssertEqual(refreshed.first?.headline, "Our title")
    }

    func testFailedMigrationRollsBackWithoutCompletionMarker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent("index.sqlite3")
        let item = photo("a", 100)
        let legacy = try CuratorStore(url: legacyURL)
        try legacy.save([item], generation: "complete")
        let invalid = PhotoMoment(id: "bad", start: item.created!, end: item.created!, photos: [item, item])
        let input = CatalogV2MigrationInput(legacyIndex: legacyURL, moments: [invalid], titles: [:],
            descriptions: [:], decisions: [:], protectedMembership: [:], places: [], reviewedGroups: GroupReviewArchive())
        let store = try CatalogV2Store(url: root.appendingPathComponent("catalog-v2.sqlite3"))
        do {
            _ = try await store.migrate(input)
            XCTFail("Expected migration failure")
        } catch {}
        let validation = try await store.validation()
        XCTAssertEqual(validation.assets, 0)
        XCTAssertEqual(validation.moments, 0)
    }

    private func photo(_ id: String, _ time: TimeInterval, favorite: Bool = false) -> IndexedPhoto {
        IndexedPhoto(id: id, created: Date(timeIntervalSince1970: time), modified: nil,
            latitude: 52, longitude: 4, favorite: favorite, width: 100, height: 100)
    }
}
