import XCTest
@testable import PhotoCurator

final class LocalStoryNarrativeTests: XCTestCase {
    private func stop(place: String?, lat: Double, lon: Double, photos: Int = 4,
                      mode: JourneyTransportMode? = nil,
                      confidence: Double = 0.8) -> JourneyStopEvidence {
        JourneyStopEvidence(
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_010_000),
            latitude: lat, longitude: lon, momentCount: 1, photoCount: photos,
            place: place, confidence: 0.9,
            transportFromPrevious: mode.map {
                JourneyLegEvidence(mode: $0, distanceMeters: 80_000, elapsedSeconds: 3600, confidence: confidence)
            })
    }

    func testCandidatesStayGroundedInStopPlaces() throws {
        let story = StorySummary(
            id: "s1", title: "Journey via Paris and Lyon",
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_200_000),
            momentIDs: ["m1", "m2"], photoCount: 40, highlightCount: 8, coverAssetID: nil,
            kind: .journey,
            stops: [
                stop(place: "Paris", lat: 48.8, lon: 2.3, mode: nil),
                stop(place: "Lyon", lat: 45.7, lon: 4.8, mode: .overland, confidence: 0.65),
            ],
            synopsis: nil, customized: false)
        let metadata = LocalStoryNarrative.metadata(for: story)
        let candidates = try LocalStoryNarrative.candidates(metadata)
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.title.contains("Paris") || $0.title == story.title })
        XCTAssertTrue(candidates.allSatisfy {
            $0.synopsis.localizedCaseInsensitiveContains("paris")
                || $0.synopsis.localizedCaseInsensitiveContains("lyon")
                || $0.synopsis.localizedCaseInsensitiveContains("overland")
        })
        XCTAssertFalse(candidates.contains { $0.synopsis.localizedCaseInsensitiveContains("rome") })
    }

    func testUncertaintyNotesExplainShellsAndWeakLegs() {
        let notes = StoryNarrativeUncertainty.notes(
            title: "Journey from Home",
            stops: [
                stop(place: nil, lat: 52, lon: 4),
                stop(place: "Berlin", lat: 52.5, lon: 13.4, mode: .unknown, confidence: 0.25),
            ])
        XCTAssertTrue(notes.contains { $0.localizedCaseInsensitiveContains("resolving") })
        XCTAssertTrue(notes.contains { $0.localizedCaseInsensitiveContains("lack") })
        XCTAssertTrue(notes.contains { $0.localizedCaseInsensitiveContains("unspecified") || $0.localizedCaseInsensitiveContains("low-confidence") })
    }

    func testStoryEditAPIAcceptsUpsertAndClear() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogV2Store(url: root.appendingPathComponent("catalog.sqlite3"))
        try await store.upsertStoryEdit(id: "story-keep", title: "Journey to Lisbon", synopsis: "Custom deck.")
        try await store.upsertStoryEdit(id: "story-keep", title: "Journey to Lisbon", synopsis: "Updated deck.")
        try await store.upsertStoryEdit(id: "story-gone", title: "Temp", synopsis: "Temp")
        try await store.upsertStoryEdit(id: "story-gone", title: nil, synopsis: nil)
        let reopened = try CatalogV2Store(url: root.appendingPathComponent("catalog.sqlite3"))
        try await reopened.upsertStoryEdit(id: "story-keep", title: "Journey to Lisbon", synopsis: "Updated deck.")
        try await reopened.rebuildStories()
    }
}
