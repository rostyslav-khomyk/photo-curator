import Foundation
import CoreLocation
import SQLite3
import CryptoKit

struct MomentSummary: Equatable, Sendable, Identifiable {
    let id: String
    let revision: Int
    let start: Date
    let end: Date
    let headline: String?
    let photoCount: Int
    let highlightCount: Int
    let coverAssetID: String?
    let fallbackCoverAssetIDs: [String]
    let customized: Bool
    let inPhotos: Bool
    let inGoogle: Bool
    let narrativeReady: Bool
    let groupingReady: Bool
}

struct StorySummary: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let momentIDs: [String]
    let photoCount: Int
    let highlightCount: Int
    let coverAssetID: String?
    let kind: StoryKind
    let stops: [JourneyStopEvidence]
    let synopsis: String?
    let customized: Bool

    /// Sidebar-ready Journey: any grounded title, not the unresolved `Journey from …` shell.
    /// Seasonal names (`Summer holidays in France`) and saved renames count; the shell does not.
    var isFinalizedJourney: Bool {
        kind == .journey
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Journey from ")
    }
}

struct CatalogV2MigrationInput: Sendable {
    let legacyIndex: URL
    let moments: [PhotoMoment]
    let titles: [String: String]
    let descriptions: [String: String]
    let decisions: [String: ReviewDecision]
    let protectedMembership: [String: Set<String>]
    let places: [MeaningfulPlace]
    let reviewedGroups: GroupReviewArchive
}

struct CatalogV2Validation: Equatable, Sendable {
    let assets: Int
    let moments: Int
    let memberships: Int
    let edits: Int
    let decisions: Int
    let places: Int
    let reviewedGroups: Int
    let publications: Int
    let foreignKeyViolations: Int
}

enum CurationGenerationState: String, Codable, Sendable {
    case building, candidate, active, retired, failed
}

struct CurationGenerationMetrics: Codable, Equatable, Sendable {
    let photoCount: Int
    let momentCount: Int
    let highlightCount: Int
    let singletonCount: Int
    let smallMomentCount: Int
    let largeMomentCount: Int
    let giantMomentCount: Int
    let fragmentedDayCount: Int
    let crossDayMomentCount: Int
    let genericTitleCount: Int
    let falseJoinCount: Int?
    let falseSplitCount: Int?
}

struct CurationGenerationRecord: Equatable, Sendable, Identifiable {
    let id: String
    let algorithmVersion: String
    let evidenceVersion: String
    let state: CurationGenerationState
    let createdAt: Date
    let completedAt: Date?
    let sourceGenerationID: String?
    let catalogRevision: String
    let sourceCatalogRevision: String?
    let metrics: CurationGenerationMetrics?
    let failure: String?
}

enum CatalogV2Migrator {
    static let catalogName = "catalog-v2.sqlite3"

    static func loadInput(root: URL, defaults: UserDefaults = .standard) throws -> CatalogV2MigrationInput {
        let legacyIndex = root.appendingPathComponent("index.sqlite3")
        guard FileManager.default.fileExists(atPath: legacyIndex.path) else {
            throw NSError(domain: "PhotoCurator.CatalogV2", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The current catalog index is missing"])
        }
        let moments = try MomentsCatalog.load(from: root.appendingPathComponent("moments-catalog.json"))?.moments ?? []
        let titles = defaults.dictionary(forKey: "curator.momentTitles.v1") as? [String: String] ?? [:]
        let descriptions = defaults.dictionary(forKey: "curator.momentDescriptions.v1") as? [String: String] ?? [:]
        let decisions = (defaults.dictionary(forKey: "curator.manualReview.v1") as? [String: String] ?? [:])
            .compactMapValues(ReviewDecision.init(rawValue:))
        return CatalogV2MigrationInput(legacyIndex: legacyIndex, moments: moments, titles: titles,
            descriptions: descriptions, decisions: decisions,
            protectedMembership: MomentGroupingProtection.load(defaults).members,
            places: MeaningfulPlacesStore.snapshot(defaults: defaults),
            reviewedGroups: try GroupReviewStore(url: root.appendingPathComponent("group-review.json")).load())
    }

    static func migrateShadow(root: URL, defaults: UserDefaults = .standard) async throws -> CatalogV2Validation {
        let destination = root.appendingPathComponent(catalogName)
        if !FileManager.default.fileExists(atPath: destination.path) {
            let sourceBytes = ["index.sqlite3", "moments-catalog.json"].reduce(Int64(128 * 1024 * 1024)) {
                $0 + Int64((try? root.appendingPathComponent($1).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage ?? 0
            guard available >= sourceBytes else {
                throw NSError(domain: "PhotoCurator.CatalogV2", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Not enough free space to prepare the shadow catalog"])
            }
        }
        let input = try loadInput(root: root, defaults: defaults)
        return try await CatalogV2Store(url: destination).migrate(input)
    }
}

/// Shadow Phase 1 catalog. It is not read by the shipping workspace until cutover is validated.
private final class CatalogV2Connection {
    let db: OpaquePointer

    init(url: URL, schema: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var opened: OpaquePointer?
        guard sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Catalog database unavailable"
            sqlite3_close(opened)
            throw NSError(domain: "PhotoCurator.CatalogV2", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
        do {
            var versionStatement: OpaquePointer?
            guard sqlite3_prepare_v2(opened, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK,
                  sqlite3_step(versionStatement) == SQLITE_ROW else { throw NSError(domain: "PhotoCurator.CatalogV2", code: 1) }
            let previousVersion = Int(sqlite3_column_int(versionStatement, 0))
            sqlite3_finalize(versionStatement)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            guard sqlite3_exec(opened, "PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;", nil, nil, nil) == SQLITE_OK,
                  sqlite3_exec(opened, schema, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "PhotoCurator.CatalogV2", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(opened))])
            }
            for column in ["selection BLOB", "context_source TEXT", "reviewed_group_title TEXT",
                           "grouping_source TEXT", "grouping_reason TEXT", "grouping_state TEXT",
                           "grouping_kind TEXT", "display_evidence BLOB", "continuity_reason TEXT",
                           "fallback_covers BLOB", "fallback_cover_2 TEXT", "fallback_cover_3 TEXT"] {
                if sqlite3_exec(opened, "ALTER TABLE moments ADD COLUMN \(column);", nil, nil, nil) != SQLITE_OK {
                    let message = String(cString: sqlite3_errmsg(opened))
                    guard message.contains("duplicate column name") else {
                        throw NSError(domain: "PhotoCurator.CatalogV2", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: message])
                    }
                }
            }
            var addedStoryKind = false
            if sqlite3_exec(opened, "ALTER TABLE stories ADD COLUMN kind TEXT NOT NULL DEFAULT 'outing';", nil, nil, nil) == SQLITE_OK {
                addedStoryKind = true
            } else {
                let message = String(cString: sqlite3_errmsg(opened))
                guard message.contains("duplicate column name") else {
                    throw NSError(domain: "PhotoCurator.CatalogV2", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: message])
                }
            }
            if sqlite3_exec(opened, "ALTER TABLE stories ADD COLUMN evidence BLOB;", nil, nil, nil) != SQLITE_OK {
                let message = String(cString: sqlite3_errmsg(opened))
                guard message.contains("duplicate column name") else {
                    throw NSError(domain: "PhotoCurator.CatalogV2", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: message])
                }
            }
            if previousVersion < 10 || addedStoryKind {
                guard sqlite3_exec(opened, "DELETE FROM stories;", nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "PhotoCurator.CatalogV2", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(opened))])
                }
            }
            if previousVersion < 11 {
                // Allow Story folders under Year in the managed Photos hierarchy.
                guard sqlite3_exec(opened, """
                    CREATE TABLE IF NOT EXISTS managed_photo_containers_v11(
                      id TEXT PRIMARY KEY,kind TEXT NOT NULL CHECK(kind IN ('root','year','story','album')),parent_id TEXT);
                    INSERT OR IGNORE INTO managed_photo_containers_v11 SELECT id,kind,parent_id FROM managed_photo_containers;
                    DROP TABLE IF EXISTS managed_photo_containers;
                    ALTER TABLE managed_photo_containers_v11 RENAME TO managed_photo_containers;
                    """, nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "PhotoCurator.CatalogV2", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(opened))])
                }
            }
            if previousVersion < 12 {
                guard sqlite3_exec(opened, """
                    CREATE TABLE IF NOT EXISTS story_edits(
                      story_id TEXT PRIMARY KEY,title TEXT,synopsis TEXT);
                    """, nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "PhotoCurator.CatalogV2", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(opened))])
                }
            }
            if previousVersion < 13 {
                guard sqlite3_exec(opened, """
                    CREATE TABLE IF NOT EXISTS story_merges(
                      id TEXT PRIMARY KEY, moment_ids TEXT NOT NULL, title TEXT);
                    """, nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "PhotoCurator.CatalogV2", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(opened))])
                }
            }
            guard sqlite3_exec(opened, "PRAGMA user_version=13;", nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "PhotoCurator.CatalogV2", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(opened))])
            }
        } catch {
            sqlite3_close(opened)
            throw error
        }
        db = opened
    }

    deinit { sqlite3_close(db) }
}

actor CatalogV2Store {
    static let schemaVersion = 13
    private let connection: CatalogV2Connection
    private var db: OpaquePointer? { connection.db }
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var cachedGoogleAssets = Set<String>()
    private var cachedReviewDecisions: [String: ReviewDecision] = [:]
    private var cachedGoogleMoments = Set<String>()
    private var journeyAttemptedStopKeys = Set<String>()
    /// All unresolved Journey stops were attempted this process; skip per-step story scans.
    private var journeyStopLookupsExhausted = false
    private var journeyTransportCursor = 0
    private var journeyTransportRetryAfter = Date.distantPast

    init(url: URL) throws {
        connection = try CatalogV2Connection(url: url, schema: Self.schemaSQL)
    }

    func migrate(_ input: CatalogV2MigrationInput) throws -> CatalogV2Validation {
        if try scalar("SELECT COUNT(*) FROM schema_migrations WHERE name='legacy-v1' AND completed=1") == 1 {
            return try validation()
        }
        let attach = try prepare("ATTACH DATABASE ? AS legacy")
        sqlite3_bind_text(attach, 1, input.legacyIndex.path, -1, transient)
        guard sqlite3_step(attach) == SQLITE_DONE else { sqlite3_finalize(attach); throw failure() }
        sqlite3_finalize(attach)
        defer { try? execute("DETACH DATABASE legacy") }
        try execute("BEGIN IMMEDIATE")
        do {
            let expectedAssets = try scalar("SELECT COUNT(*) FROM legacy.photos")
            try importAssets()
            try importMoments(input.moments)
            try importUserState(input)
            let result = try validation()
            let expectedEdits = Set(input.titles.keys).union(input.descriptions.keys).count
            guard result == CatalogV2Validation(assets: expectedAssets, moments: input.moments.count,
                memberships: input.moments.reduce(0) { $0 + $1.photos.count }, edits: expectedEdits,
                decisions: input.decisions.count, places: input.places.count,
                reviewedGroups: input.reviewedGroups.groups.count,
                publications: input.moments.filter { $0.publishedAlbumID != nil }.count,
                foreignKeyViolations: 0) else {
                throw failure("Shadow catalog validation did not match its source snapshot")
            }
            try validateDurableValues(input)
            try execute("INSERT OR REPLACE INTO schema_migrations(name,completed_at,completed) VALUES('legacy-v1',strftime('%s','now'),1)")
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func prepareWorkspace(_ input: CatalogV2MigrationInput) throws {
        guard try scalar("SELECT COUNT(*) FROM schema_migrations WHERE name='workspace-v4' AND completed=1") == 0 else {
            return
        }
        try synchronize(moments: input.moments, activeMomentIDs: Set(input.moments.map(\.id)))
        try execute("INSERT INTO schema_migrations(name,completed_at,completed) VALUES('workspace-v4',strftime('%s','now'),1)")
    }

    func summaries(googleUploadedAssetIDs: Set<String> = [],
                   reviewDecisions: [String: ReviewDecision] = [:]) throws -> [MomentSummary] {
        let statement = try prepare("""
            SELECT m.id,m.revision,m.start,m.end,COALESCE(e.title,m.headline),m.photo_count,m.highlight_count,
                   m.cover_asset_id,m.fallback_cover_2,m.fallback_cover_3,
                   e.moment_id IS NOT NULL,p.moment_id IS NOT NULL,
                   m.narrative IS NOT NULL,COALESCE(m.grouping_state,'') NOT IN ('','preparing')
            FROM moments m LEFT JOIN moment_edits e ON e.moment_id=m.id
            LEFT JOIN publications p ON p.moment_id=m.id ORDER BY m.start DESC,m.id
            """)
        defer { sqlite3_finalize(statement) }
        var result: [MomentSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = text(statement, 0)
            result.append(MomentSummary(id: id, revision: Int(sqlite3_column_int64(statement, 1)),
                start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                headline: optionalText(statement, 4), photoCount: Int(sqlite3_column_int64(statement, 5)),
                highlightCount: Int(sqlite3_column_int64(statement, 6)), coverAssetID: optionalText(statement, 7),
                fallbackCoverAssetIDs: [optionalText(statement, 7), optionalText(statement, 8),
                    optionalText(statement, 9)].compactMap { $0 },
                customized: sqlite3_column_int(statement, 10) != 0, inPhotos: sqlite3_column_int(statement, 11) != 0,
                inGoogle: false, narrativeReady: sqlite3_column_int(statement, 12) != 0,
                groupingReady: sqlite3_column_int(statement, 13) != 0))
        }
        guard !googleUploadedAssetIDs.isEmpty else { return result }
        let uploadedMomentIDs: Set<String>
        if googleUploadedAssetIDs == cachedGoogleAssets, reviewDecisions == cachedReviewDecisions {
            uploadedMomentIDs = cachedGoogleMoments
        } else {
            uploadedMomentIDs = try googleUploadedMoments(assetIDs: googleUploadedAssetIDs,
                                                          decisions: reviewDecisions)
            cachedGoogleAssets = googleUploadedAssetIDs
            cachedReviewDecisions = reviewDecisions
            cachedGoogleMoments = uploadedMomentIDs
        }
        return result.map { value in
            MomentSummary(id: value.id, revision: value.revision, start: value.start, end: value.end,
                headline: value.headline, photoCount: value.photoCount, highlightCount: value.highlightCount,
                coverAssetID: value.coverAssetID, fallbackCoverAssetIDs: value.fallbackCoverAssetIDs,
                customized: value.customized, inPhotos: value.inPhotos,
                inGoogle: uploadedMomentIDs.contains(value.id), narrativeReady: value.narrativeReady,
                groupingReady: value.groupingReady)
        }
    }

    /// Bump when Journey/outing projection rules change so existing Stories recompute.
    static let storyProjectionEpoch = "story-projection-v55-unlocated-full-names"

    /// True when Moments exist but Story membership was wiped, or Journey rules advanced.
    func needsStoryProjection() throws -> Bool {
        let moments = try scalar("SELECT COUNT(*) FROM moments")
        guard moments > 0 else { return false }
        if try scalar("SELECT COUNT(*) FROM story_moments") == 0 { return true }
        return try scalar("""
            SELECT COUNT(*) FROM schema_migrations
            WHERE name='\(Self.storyProjectionEpoch)' AND completed=1
            """) == 0
    }

    func rebuildStories(calendar: Calendar = .current) throws {
        // New or retitled stops may need geocode again after hierarchy changes.
        journeyStopLookupsExhausted = false
        let statement = try prepare("""
            SELECT m.id,m.start,m.end,m.narrative,m.photo_count,m.highlight_count,m.cover_asset_id,
                   AVG(a.latitude),AVG(a.longitude)
            FROM moments m LEFT JOIN moment_assets ma ON ma.moment_id=m.id
            LEFT JOIN assets a ON a.id=ma.asset_id
              AND a.latitude BETWEEN -90 AND 90 AND a.longitude BETWEEN -180 AND 180
              AND (ABS(a.latitude) > 0.000001 OR ABS(a.longitude) > 0.000001)
            GROUP BY m.id ORDER BY m.start,m.id
            """)
        defer { sqlite3_finalize(statement) }
        var moments: [PhotoMoment] = []
        var facts: [String: (photos: Int, highlights: Int, cover: String?)] = [:]
        var coordinates: [String: CLLocationCoordinate2D] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = text(statement, 0)
            let narrative: MomentNarrative? = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil : try? JSONDecoder().decode(MomentNarrative.self, from: blob(statement, 3))
            moments.append(PhotoMoment(id: id,
                start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                photos: [], narrative: narrative))
            facts[id] = (Int(sqlite3_column_int64(statement, 4)),
                         Int(sqlite3_column_int64(statement, 5)), optionalText(statement, 6))
            if sqlite3_column_type(statement, 7) != SQLITE_NULL,
               sqlite3_column_type(statement, 8) != SQLITE_NULL {
                coordinates[id] = CLLocationCoordinate2D(latitude: sqlite3_column_double(statement, 7),
                                                          longitude: sqlite3_column_double(statement, 8))
            }
        }
        let homes = try homeMeaningfulPlaces()
        let homeLabel = homes.first(where: {
            $0.label.compare("Home", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        })?.label ?? homes.first?.label ?? "Home"
        // Geocoded city labels are expensive to rediscover; rebuild must not wipe them to
        // "Journey from Home" and empty the finalized sidebar until OCR/geocode catches up.
        let preservedPlaces = try preservedJourneyStopPlaces()
        let leftoverMoments = try momentMemberships()
        let leftoverPhotos = try experimentalUnlocatedPhotos()
        let stories = StoryHierarchyBuilder.stories(moments, homes: homes, calendar: calendar,
            coordinate: { coordinates[$0.id] }, placeID: { $0.narrative?.place },
            support: { facts[$0.id]?.photos ?? 0 },
            leftoverMoments: leftoverMoments,
            leftoverPhotos: leftoverPhotos)
        let titled = adoptingPreservedJourneyPlaces(stories, preserved: preservedPlaces,
                                                    homeLabel: homeLabel)
        let merged = try applyingJourneyMerges(titled)
        let candidates = try hierarchicalHighlightCandidatesByMoment()
        let highlightPlan = Dictionary(uniqueKeysWithValues: merged.map { story -> (String, HierarchicalHighlightAllocation) in
            let storyCandidates = story.momentIDs.flatMap { candidates[$0] ?? [] }
            let allocation = HierarchicalHighlightAllocator.allocate(storyCandidates) { lhs, rhs in
                lhs == rhs ? 1 : 0
            }
            return (story.id, allocation)
        })
        try persistStories(merged, facts: facts, highlights: highlightPlan)
        try execute("""
            INSERT OR REPLACE INTO schema_migrations(name,completed_at,completed)
            VALUES('\(Self.storyProjectionEpoch)',strftime('%s','now'),1)
            """)
    }

    /// Moment highlight assets already chosen for display, keyed for Story-level allocation.
    /// Does not rewrite Moment selections — Moments stay independently editable.
    private func hierarchicalHighlightCandidatesByMoment() throws
        -> [String: [HierarchicalHighlightCandidate]] {
        let statement = try prepare("""
            SELECT ma.moment_id, ma.asset_id, ma.sequence, COALESCE(a.favorite, 0)
            FROM moment_assets ma
            JOIN assets a ON a.id = ma.asset_id
            WHERE ma.display_role = 'highlight'
            ORDER BY ma.moment_id, ma.sequence
            """)
        defer { sqlite3_finalize(statement) }
        var result: [String: [HierarchicalHighlightCandidate]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let momentID = text(statement, 0)
            let assetID = text(statement, 1)
            let sequence = Int(sqlite3_column_int64(statement, 2))
            let favorite = sqlite3_column_int64(statement, 3) != 0
            var roles: Set<String> = ["highlight", "moment:\(momentID)"]
            if favorite { roles.insert("favorite") }
            let quality = favorite ? 1.0 : max(0.2, 1.0 - Double(sequence) * 0.05)
            result[momentID, default: []].append(
                HierarchicalHighlightCandidate(id: assetID, momentID: momentID,
                    quality: quality, protected: favorite, roles: roles))
        }
        return result
    }

    /// City/region labels from the previous Journey evidence keyed by rounded stop coordinates.
    private func preservedJourneyStopPlaces() throws -> [String: String] {
        let statement = try prepare("SELECT evidence FROM stories WHERE kind='journey' AND evidence IS NOT NULL")
        defer { sqlite3_finalize(statement) }
        let decoder = JSONDecoder()
        var places: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let stops = try? decoder.decode([JourneyStopEvidence].self, from: blob(statement, 0)) else {
                continue
            }
            for stop in stops {
                guard let place = stop.place?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !place.isEmpty,
                      !PlaceNaming.shouldReplaceJourneyStopLabel(place),
                      !PlaceNaming.labelConflictsWithCoordinates(place, latitude: stop.latitude,
                                                                 longitude: stop.longitude) else { continue }
                places[journeyStopCoordinateKey(stop)] = place
            }
        }
        return places
    }

    private func journeyStopCoordinateKey(_ stop: JourneyStopEvidence) -> String {
        String(format: "%.3f,%.3f", stop.latitude, stop.longitude)
    }

    /// Re-applies preserved city labels onto rebuilt stops and retitles Journeys.
    private func adoptingPreservedJourneyPlaces(
        _ stories: [CurationStory],
        preserved: [String: String],
        homeLabel: String
    ) -> [CurationStory] {
        let homes = (try? homeMeaningfulPlaces()) ?? []
        return stories.map { story in
            guard story.kind == .journey, !story.stops.isEmpty else { return story }
            var stops = story.stops.map { stop -> JourneyStopEvidence in
                let current = stop.place?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let current, !current.isEmpty, !PlaceNaming.shouldReplaceJourneyStopLabel(current),
                   !PlaceNaming.labelConflictsWithCoordinates(current, latitude: stop.latitude,
                                                              longitude: stop.longitude) {
                    return stop
                }
                guard let place = preserved[journeyStopCoordinateKey(stop)],
                      !PlaceNaming.shouldReplaceJourneyStopLabel(place),
                      !PlaceNaming.labelConflictsWithCoordinates(place, latitude: stop.latitude,
                                                                 longitude: stop.longitude) else { return stop }
                // Never stamp a preserved “Home” onto mid-ocean / abroad messenger pins.
                if JourneyStoryBuilder.isSecondaryHomeLabel(place, primaryHome: homeLabel) {
                    return stop
                }
                return JourneyStopEvidence(start: stop.start, end: stop.end,
                    latitude: stop.latitude, longitude: stop.longitude,
                    momentCount: stop.momentCount, photoCount: stop.photoCount,
                    place: place, confidence: max(stop.confidence, 0.8),
                    transportFromPrevious: stop.transportFromPrevious)
            }
            stops = JourneyStopSanitizer.removingRouteNoise(stops, homes: homes, homeLabel: homeLabel)
            stops = JourneyTransportInference.applying(to: stops)
            let title = JourneyStoryBuilder.title(homeLabel: homeLabel, stops: stops)
            return CurationStory(id: story.id, start: story.start, end: story.end,
                momentIDs: story.momentIDs, placeID: title, kind: story.kind, stops: stops)
        }
    }

    /// User Journey merges survive `rebuildStories`. A merge applies only when the saved
    /// Moment set is exactly the union of two or more current Journeys.
    private func applyingJourneyMerges(_ stories: [CurationStory]) throws -> [CurationStory] {
        JourneyMergePlan.applying(stories, merges: try journeyMergeRecords())
    }

    func journeyMergeRecords() throws -> [JourneyMergeRecord] {
        let statement = try prepare("SELECT id, moment_ids, title FROM story_merges ORDER BY id")
        defer { sqlite3_finalize(statement) }
        var records: [JourneyMergeRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let payload = Data(text(statement, 1).utf8)
            guard let ids = try? JSONDecoder().decode([String].self, from: payload), ids.count >= 2 else {
                continue
            }
            records.append(JourneyMergeRecord(id: text(statement, 0), momentIDs: ids,
                                              title: optionalText(statement, 2) ?? ""))
        }
        return records
    }

    /// Removes a saved Journey merge (and its title edit) so Stories rebuild from Moments again.
    func deleteJourneyMerge(id: String) throws {
        let clearEdit = try prepare("DELETE FROM story_edits WHERE story_id=?")
        defer { sqlite3_finalize(clearEdit) }
        sqlite3_bind_text(clearEdit, 1, id, -1, transient)
        guard sqlite3_step(clearEdit) == SQLITE_DONE else { throw failure() }
        let clearMerge = try prepare("DELETE FROM story_merges WHERE id=?")
        defer { sqlite3_finalize(clearMerge) }
        sqlite3_bind_text(clearMerge, 1, id, -1, transient)
        guard sqlite3_step(clearMerge) == SQLITE_DONE else { throw failure() }
    }

    func deleteJourneyMerges(titled title: String) throws {
        let statement = try prepare("SELECT id FROM story_merges WHERE title=? COLLATE NOCASE")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, title, -1, transient)
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { ids.append(text(statement, 0)) }
        for id in ids { try deleteJourneyMerge(id: id) }
    }

    /// Remembers a Journey merge and a title edit. The next story rebuild collapses matching Journeys.
    func saveJourneyMerge(momentIDs: [String], title: String) throws {
        let ids = Array(Set(momentIDs)).sorted()
        guard ids.count >= 2 else { throw failure("Choose at least two Journeys to merge") }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else {
            throw failure("Enter a Journey name up to 200 characters")
        }
        let id = JourneyMergePlan.id(momentIDs: ids)
        let payload = String(data: try JSONEncoder().encode(ids), encoding: .utf8) ?? "[]"
        let statement = try prepare("""
            INSERT INTO story_merges(id, moment_ids, title) VALUES(?,?,?)
            ON CONFLICT(id) DO UPDATE SET moment_ids=excluded.moment_ids, title=excluded.title
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, transient)
        sqlite3_bind_text(statement, 2, payload, -1, transient)
        sqlite3_bind_text(statement, 3, trimmed, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        try upsertStoryEdit(id: id, title: trimmed, synopsis: nil)
    }

    private func persistStories(_ stories: [CurationStory],
                                facts: [String: (photos: Int, highlights: Int, cover: String?)],
                                highlights: [String: HierarchicalHighlightAllocation] = [:]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM story_moments; DELETE FROM stories")
            let insertStory = try prepare("""
                INSERT INTO stories(id,title,start,end,photo_count,highlight_count,cover_asset_id,
                                    moment_count,kind,evidence) VALUES(?,?,?,?,?,?,?,?,?,?)
                """)
            let insertMember = try prepare("INSERT INTO story_moments VALUES(?,?,?)")
            defer { sqlite3_finalize(insertStory); sqlite3_finalize(insertMember) }
            var claimedMoments = Set<String>()
            for story in stories {
                let values = story.momentIDs.compactMap { facts[$0] }
                let allocation = highlights[story.id]
                let storyHighlightIDs = allocation?.storyHighlights ?? []
                // Prefer curated Story-level set; fall back to summed Moment counts when Moments
                // still lack highlight membership (early indexing).
                let highlightCount = storyHighlightIDs.isEmpty
                    ? values.reduce(0) { $0 + $1.highlights }
                    : storyHighlightIDs.count
                let cover = storyHighlightIDs.first ?? story.momentIDs.compactMap { id -> (String, Int)? in
                    guard let value = facts[id], let cover = value.cover else { return nil }
                    return (cover, value.highlights)
                }.max { $0.1 < $1.1 }?.0
                sqlite3_reset(insertStory); sqlite3_clear_bindings(insertStory)
                sqlite3_bind_text(insertStory, 1, story.id, -1, transient)
                sqlite3_bind_text(insertStory, 2, story.placeID, -1, transient)
                sqlite3_bind_double(insertStory, 3, story.start.timeIntervalSince1970)
                sqlite3_bind_double(insertStory, 4, story.end.timeIntervalSince1970)
                sqlite3_bind_int64(insertStory, 5, Int64(values.reduce(0) { $0 + $1.photos }))
                sqlite3_bind_int64(insertStory, 6, Int64(highlightCount))
                bind(cover, to: insertStory, at: 7)
                sqlite3_bind_int64(insertStory, 8, Int64(story.momentIDs.count))
                sqlite3_bind_text(insertStory, 9, story.kind.rawValue, -1, transient)
                if story.stops.isEmpty { sqlite3_bind_null(insertStory, 10) }
                else { bind(try JSONEncoder().encode(story.stops), to: insertStory, at: 10) }
                guard sqlite3_step(insertStory) == SQLITE_DONE else { throw failure() }
                var sequence = 0
                for momentID in story.momentIDs {
                    guard claimedMoments.insert(momentID).inserted else { continue }
                    sqlite3_reset(insertMember); sqlite3_clear_bindings(insertMember)
                    sqlite3_bind_text(insertMember, 1, story.id, -1, transient)
                    sqlite3_bind_text(insertMember, 2, momentID, -1, transient)
                    sqlite3_bind_int64(insertMember, 3, Int64(sequence))
                    guard sqlite3_step(insertMember) == SQLITE_DONE else { throw failure() }
                    sequence += 1
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func meaningfulPlace(named name: String) throws -> MeaningfulPlace? {
        let statement = try prepare("SELECT id,label,address,latitude,longitude,radius FROM meaningful_places WHERE label=? COLLATE NOCASE LIMIT 1")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let id = UUID(uuidString: text(statement, 0)) else { return nil }
        return MeaningfulPlace(id: id, label: text(statement, 1), address: text(statement, 2),
            latitude: sqlite3_column_double(statement, 3), longitude: sqlite3_column_double(statement, 4),
            radius: sqlite3_column_double(statement, 5))
    }

    /// Primary Home plus secondary residences (`Home in Ukraine`). Used to start/end Journeys.
    /// Merges catalog rows with the Settings store so a newly mapped Home is not missed.
    private func homeMeaningfulPlaces() throws -> [MeaningfulPlace] {
        let statement = try prepare("""
            SELECT id,label,address,latitude,longitude,radius FROM meaningful_places
            WHERE label LIKE 'Home%' COLLATE NOCASE
            ORDER BY CASE WHEN label = 'Home' COLLATE NOCASE THEN 0 ELSE 1 END, label
            """)
        defer { sqlite3_finalize(statement) }
        var places: [MeaningfulPlace] = []
        var seen = Set<UUID>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, 0)) else { continue }
            seen.insert(id)
            places.append(MeaningfulPlace(id: id, label: text(statement, 1), address: text(statement, 2),
                latitude: sqlite3_column_double(statement, 3), longitude: sqlite3_column_double(statement, 4),
                radius: sqlite3_column_double(statement, 5)))
        }
        for place in MeaningfulPlacesStore.snapshot() where place.label.lowercased().hasPrefix("home") {
            if seen.insert(place.id).inserted { places.append(place) }
        }
        if places.isEmpty, let home = try meaningfulPlace(named: "Home") {
            return [home]
        }
        return places.sorted {
            let left = $0.label.compare("Home", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            let right = $1.label.compare("Home", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            if left != right { return left && !right }
            return $0.label < $1.label
        }
    }

    /// Retitles every Journey from current stop coordinates, clears stuck landmark labels, and
    /// rebuilds so home start/end anchors and country/season names refresh.
    func reprocessJourneyPresentation() throws {
        journeyAttemptedStopKeys.removeAll()
        journeyStopLookupsExhausted = false
        let stories = try storySummaries().filter { $0.kind == .journey }
        let homeLabel = try homeMeaningfulPlaces().first?.label ?? "Home"
        let encoder = JSONEncoder()
        try execute("BEGIN IMMEDIATE")
        do {
            let update = try prepare("UPDATE stories SET title=?,evidence=? WHERE id=?")
            defer { sqlite3_finalize(update) }
            for story in stories {
                let stops = story.stops.map { stop -> JourneyStopEvidence in
                    guard PlaceNaming.shouldReplaceJourneyStopLabel(stop.place)
                        || PlaceNaming.labelConflictsWithCoordinates(stop.place, latitude: stop.latitude,
                                                                     longitude: stop.longitude) else { return stop }
                    return JourneyStopEvidence(start: stop.start, end: stop.end,
                        latitude: stop.latitude, longitude: stop.longitude,
                        momentCount: stop.momentCount, photoCount: stop.photoCount,
                        place: nil, confidence: stop.confidence,
                        transportFromPrevious: stop.transportFromPrevious)
                }
                // Country/season titles use coordinates even when place labels are cleared.
                let title = JourneyStoryBuilder.title(homeLabel: homeLabel, stops: stops)
                sqlite3_reset(update); sqlite3_clear_bindings(update)
                sqlite3_bind_text(update, 1, title, -1, transient)
                bind(try encoder.encode(stops), to: update, at: 2)
                sqlite3_bind_text(update, 3, story.id, -1, transient)
                guard sqlite3_step(update) == SQLITE_DONE else { throw failure() }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        try rebuildStories()
    }

    /// Parent Story for Photos publication folders. Nil when the Moment is ungrouped.
    /// Effective (owner-renamed) title. `sharesTitleInYear` is true when another Story
    /// starting in the same local year has the same title, so its Photos folder needs the month.
    func storyContaining(momentID: String) throws -> (title: String, start: Date, sharesTitleInYear: Bool)? {
        let statement = try prepare("""
            WITH effective AS (
                SELECT s.id, COALESCE(e.title,s.title) AS title, s.start,
                       strftime('%Y', s.start, 'unixepoch', 'localtime') AS year
                FROM stories s LEFT JOIN story_edits e ON e.story_id=s.id
            )
            SELECT x.title, x.start,
                   EXISTS(SELECT 1 FROM effective o WHERE o.id != x.id AND o.year = x.year
                          AND LOWER(TRIM(o.title)) = LOWER(TRIM(x.title)))
            FROM effective x JOIN story_moments sm ON sm.story_id=x.id
            WHERE sm.moment_id=? LIMIT 1
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, momentID, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return (text(statement, 0), Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                sqlite3_column_int(statement, 2) != 0)
    }

    /// Moment → asset membership for gated album Story previews. Does not mutate Stories.
    func momentMemberships() throws -> [UnlocatedAlbumStoryBuilder.MomentMembership] {
        let statement = try prepare("""
            SELECT m.id,m.start,m.end,ma.asset_id
            FROM moments m LEFT JOIN moment_assets ma ON ma.moment_id=m.id
            ORDER BY m.start,m.id,ma.sequence
            """)
        defer { sqlite3_finalize(statement) }
        var order: [String] = []
        var starts: [String: Date] = [:]
        var ends: [String: Date] = [:]
        var assets: [String: Set<String>] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = text(statement, 0)
            if starts[id] == nil {
                order.append(id)
                starts[id] = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                ends[id] = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                assets[id] = []
            }
            if sqlite3_column_type(statement, 3) != SQLITE_NULL {
                assets[id, default: []].insert(text(statement, 3))
            }
        }
        return order.compactMap { id in
            guard let start = starts[id], let end = ends[id] else { return nil }
            return UnlocatedAlbumStoryBuilder.MomentMembership(
                id: id, start: start, end: end, assetIDs: assets[id] ?? [])
        }
    }

    /// Unlocated pre-2010 assets, with Photos.sqlite names/filenames/timezones when readable.
    func experimentalUnlocatedPhotos(
        extendedAccess: Bool = ExperimentalUnlocatedJourneyBuilder.extendedAccessEnabled
    ) throws -> [ExperimentalUnlocatedJourneyBuilder.Photo] {
        guard extendedAccess else { return [] }
        let cutoff = ExperimentalUnlocatedJourneyBuilder.defaultCutoff.timeIntervalSince1970
        let statement = try prepare("""
            SELECT a.id, a.created, a.latitude, a.longitude
            FROM assets a
            JOIN moment_assets ma ON ma.asset_id = a.id
            WHERE a.created IS NOT NULL AND a.created < ?
            GROUP BY a.id
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)
        var photos: [ExperimentalUnlocatedJourneyBuilder.Photo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let lat = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 2)
            let lon = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 3)
            let unlocated = lat == nil || lon == nil
                || (abs(lat!) < 0.0001 && abs(lon!) < 0.0001)
                || abs(lat!) > 90 || abs(lon!) > 180
            guard unlocated else { continue }
            photos.append(ExperimentalUnlocatedJourneyBuilder.Photo(
                id: text(statement, 0),
                created: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                unlocated: true))
        }
        guard !photos.isEmpty else { return [] }
        let overlay = ExperimentalUnlocatedSignalLoader.load()
        return photos.map { overlay.applied(to: $0) }
    }

    func storySummaries() throws -> [StorySummary] {
        let storyStatement = try prepare("""
            SELECT s.id,COALESCE(e.title,s.title),s.start,s.end,s.photo_count,s.highlight_count,
                   s.cover_asset_id,s.kind,s.evidence,e.synopsis,e.story_id IS NOT NULL
            FROM stories s LEFT JOIN story_edits e ON e.story_id=s.id
            ORDER BY s.start DESC,s.id
            """)
        defer { sqlite3_finalize(storyStatement) }
        let memberStatement = try prepare("SELECT moment_id FROM story_moments WHERE story_id=? ORDER BY sequence")
        defer { sqlite3_finalize(memberStatement) }
        var result: [StorySummary] = []
        while sqlite3_step(storyStatement) == SQLITE_ROW {
            let id = text(storyStatement, 0)
            sqlite3_reset(memberStatement); sqlite3_clear_bindings(memberStatement)
            sqlite3_bind_text(memberStatement, 1, id, -1, transient)
            var momentIDs: [String] = []
            while sqlite3_step(memberStatement) == SQLITE_ROW { momentIDs.append(text(memberStatement, 0)) }
            let kind = StoryKind(rawValue: text(storyStatement, 7)) ?? .outing
            let stops = sqlite3_column_type(storyStatement, 8) == SQLITE_NULL ? []
                : (try? JSONDecoder().decode([JourneyStopEvidence].self, from: blob(storyStatement, 8))) ?? []
            let title = text(storyStatement, 1)
            let customized = sqlite3_column_int(storyStatement, 10) != 0
            let storedSynopsis = optionalText(storyStatement, 9)
            let synopsis: String?
            if let storedSynopsis, !storedSynopsis.isEmpty {
                synopsis = storedSynopsis
            } else if let candidate = try? LocalStoryNarrative.candidates(
                LocalStoryNarrative.metadata(for: StorySummary(
                    id: id, title: title, start: Date(timeIntervalSince1970: sqlite3_column_double(storyStatement, 2)),
                    end: Date(timeIntervalSince1970: sqlite3_column_double(storyStatement, 3)),
                    momentIDs: momentIDs, photoCount: Int(sqlite3_column_int64(storyStatement, 4)),
                    highlightCount: Int(sqlite3_column_int64(storyStatement, 5)),
                    coverAssetID: optionalText(storyStatement, 6), kind: kind, stops: stops,
                    synopsis: nil, customized: customized))).first {
                synopsis = candidate.synopsis
            } else {
                synopsis = nil
            }
            result.append(StorySummary(id: id, title: title,
                start: Date(timeIntervalSince1970: sqlite3_column_double(storyStatement, 2)),
                end: Date(timeIntervalSince1970: sqlite3_column_double(storyStatement, 3)),
                momentIDs: momentIDs, photoCount: Int(sqlite3_column_int64(storyStatement, 4)),
                highlightCount: Int(sqlite3_column_int64(storyStatement, 5)),
                coverAssetID: optionalText(storyStatement, 6), kind: kind, stops: stops,
                synopsis: synopsis, customized: customized))
        }
        return result
    }

    /// Persists user Story title/synopsis overrides. Rebuilds keep these rows.
    func upsertStoryEdit(id: String, title: String?, synopsis: String?) throws {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSynopsis = synopsis?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleValue = (trimmedTitle?.isEmpty == false) ? String(trimmedTitle!.prefix(200)) : nil
        let synopsisValue = (trimmedSynopsis?.isEmpty == false) ? String(trimmedSynopsis!.prefix(600)) : nil
        if titleValue == nil && synopsisValue == nil {
            let clear = try prepare("DELETE FROM story_edits WHERE story_id=?")
            defer { sqlite3_finalize(clear) }
            sqlite3_bind_text(clear, 1, id, -1, transient)
            guard sqlite3_step(clear) == SQLITE_DONE else { throw failure() }
            return
        }
        let statement = try prepare("""
            INSERT INTO story_edits(story_id,title,synopsis) VALUES(?,?,?)
            ON CONFLICT(story_id) DO UPDATE SET title=excluded.title,synopsis=excluded.synopsis
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, transient)
        bind(titleValue, to: statement, at: 2)
        bind(synopsisValue, to: statement, at: 3)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    /// One leg and at most 24 cached photos per pass. No SQL transaction spans the await.
    func enrichJourneyTransport(
        evidence: @Sendable ([IndexedPhoto]) async throws -> JourneyLocalTransportSupport
    ) async throws -> (attempted: Bool, updated: Bool, hasMore: Bool) {
        guard Date() >= journeyTransportRetryAfter else { return (false, false, false) }
        let stories = try storySummaries().filter { $0.kind == .journey }
        let legs = stories.flatMap { story in
            story.stops.indices.dropFirst().map { (story, $0) }
        }
        guard !legs.isEmpty else { return (false, false, false) }
        let index = journeyTransportCursor % legs.count
        journeyTransportCursor = index + 1
        if index + 1 == legs.count { journeyTransportRetryAfter = Date().addingTimeInterval(3600) }
        let (story, stopIndex) = legs[index]
        let stop = story.stops[stopIndex], previous = story.stops[stopIndex - 1]
        guard let leg = stop.transportFromPrevious else { return (true, false, index + 1 < legs.count) }
        let snapshot = try prepare("SELECT evidence FROM stories WHERE id=?")
        sqlite3_bind_text(snapshot, 1, story.id, -1, transient)
        let original = sqlite3_step(snapshot) == SQLITE_ROW ? blob(snapshot, 0) : nil
        sqlite3_finalize(snapshot)
        guard let original else { return (true, false, index + 1 < legs.count) }
        let query = try prepare("""
            SELECT DISTINCT a.id,a.payload FROM assets a
            JOIN moment_assets ma ON ma.asset_id=a.id
            JOIN story_moments sm ON sm.moment_id=ma.moment_id
            WHERE sm.story_id=? AND a.created>=? AND a.created<=?
            ORDER BY a.created,a.id LIMIT 24
            """)
        sqlite3_bind_text(query, 1, story.id, -1, transient)
        sqlite3_bind_double(query, 2, previous.end.addingTimeInterval(-1800).timeIntervalSince1970)
        sqlite3_bind_double(query, 3, stop.start.addingTimeInterval(1800).timeIntervalSince1970)
        var photos: [IndexedPhoto] = []
        while sqlite3_step(query) == SQLITE_ROW {
            if let photo = try? JSONDecoder().decode(IndexedPhoto.self, from: blob(query, 1)) { photos.append(photo) }
        }
        sqlite3_finalize(query)
        let support = try await evidence(photos)
        try Task.checkCancellation()
        let enriched = support.applying(to: leg)
        guard enriched != leg else { return (true, false, index + 1 < legs.count) }
        var stops = story.stops
        stops[stopIndex] = JourneyStopEvidence(start: stop.start, end: stop.end,
            latitude: stop.latitude, longitude: stop.longitude, momentCount: stop.momentCount,
            photoCount: stop.photoCount, place: stop.place, confidence: stop.confidence,
            transportFromPrevious: enriched)
        let update = try prepare("UPDATE stories SET evidence=? WHERE id=? AND evidence=?")
        defer { sqlite3_finalize(update) }
        bind(try JSONEncoder().encode(stops), to: update, at: 1)
        sqlite3_bind_text(update, 2, story.id, -1, transient)
        bind(original, to: update, at: 3)
        guard sqlite3_step(update) == SQLITE_DONE else { throw failure() }
        return (true, sqlite3_changes(db) > 0, index + 1 < legs.count)
    }

    /// Resolves a small stop batch before opening the write transaction. Story evidence is
    /// rebuildable, and the compare-and-swap prevents stale enrichment from replacing a rebuild.
    func enrichJourneyStops(maximumLookups: Int = 4,
                            geocoder: CuratorGeocodingService = .journeys) async throws
        -> (attempted: Int, updated: Int, hasMore: Bool) {
        guard maximumLookups > 0 else { return (0, 0, false) }
        if journeyStopLookupsExhausted { return (0, 0, false) }
        let stories = try storySummaries().filter { $0.kind == .journey }
        let evidenceStatement = try prepare("SELECT id,evidence FROM stories WHERE kind='journey' AND evidence IS NOT NULL")
        var originalEvidence: [String: Data] = [:]
        while sqlite3_step(evidenceStatement) == SQLITE_ROW {
            originalEvidence[text(evidenceStatement, 0)] = blob(evidenceStatement, 1)
        }
        sqlite3_finalize(evidenceStatement)
        func key(_ stop: JourneyStopEvidence) -> String {
            String(format: "%.3f,%.3f", stop.latitude, stop.longitude)
        }
        var seen = Set<String>()
        // Street-level place IDs block city naming; treat them as unresolved for geocode.
        let unresolved = stories.flatMap(\.stops).filter { stop in
            (PlaceNaming.shouldReplaceJourneyStopLabel(stop.place)
                || PlaceNaming.labelConflictsWithCoordinates(stop.place, latitude: stop.latitude,
                                                             longitude: stop.longitude))
                && seen.insert(key(stop)).inserted
        }
        let candidates = unresolved.filter { !journeyAttemptedStopKeys.contains(key($0)) }
        // Stops that reverse-geocode to nothing useful must not be retried this process:
        // resetting the attempted set restarted two lookups every analysis step forever.
        guard !candidates.isEmpty else {
            journeyStopLookupsExhausted = true
            return (0, 0, false)
        }
        let selected = Array(candidates.prefix(maximumLookups))
        journeyAttemptedStopKeys.formUnion(selected.map(key))
        let hasMore = candidates.count > selected.count
        let homes = try homeMeaningfulPlaces()
        let primaryHome = homes.first(where: {
            $0.label.compare("Home", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) ?? homes.first
        let homeLocality: String?
        if let home = primaryHome, let place = await geocoder.place(for: home.latitude, longitude: home.longitude) {
            homeLocality = place.locality
        } else {
            homeLocality = nil
        }
        var resolved: [String: String] = [:]
        for stop in selected {
            try Task.checkCancellation()
            // Prefer any Home geofence over city-name equality so Woerden streets stay Home.
            if let home = homes.first(where: { $0.contains(latitude: stop.latitude, longitude: stop.longitude) }) {
                resolved[key(stop)] = home.label
                continue
            }
            guard let place = await geocoder.place(for: stop.latitude, longitude: stop.longitude) else { continue }
            let label = place.journeyStopName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !PlaceNaming.looksStreetLevel(label),
                  !PlaceNaming.looksLandmarkOrTransit(label),
                  !PlaceNaming.labelConflictsWithCoordinates(label, latitude: stop.latitude,
                                                             longitude: stop.longitude) else { continue }
            if let homeLocality,
               homeLocality.compare(label, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                resolved[key(stop)] = primaryHome?.label ?? "Home"
            } else {
                resolved[key(stop)] = label
            }
        }
        guard !resolved.isEmpty else { return (selected.count, 0, hasMore) }

        let homeLabel = primaryHome?.label ?? "Home"
        let encoder = JSONEncoder()
        try execute("BEGIN IMMEDIATE")
        do {
            let update = try prepare("UPDATE stories SET title=?,evidence=? WHERE id=? AND evidence=?")
            defer { sqlite3_finalize(update) }
            var updated = 0
            for story in stories {
                let stops = story.stops.map { stop -> JourneyStopEvidence in
                    guard let place = resolved[key(stop)] else { return stop }
                    guard PlaceNaming.shouldReplaceJourneyStopLabel(stop.place)
                        || PlaceNaming.labelConflictsWithCoordinates(stop.place, latitude: stop.latitude,
                                                                     longitude: stop.longitude) else { return stop }
                    return JourneyStopEvidence(start: stop.start, end: stop.end,
                        latitude: stop.latitude, longitude: stop.longitude,
                        momentCount: stop.momentCount, photoCount: stop.photoCount,
                        place: place, confidence: stop.confidence,
                        transportFromPrevious: stop.transportFromPrevious)
                }
                guard stops != story.stops, let previous = originalEvidence[story.id] else { continue }
                sqlite3_reset(update); sqlite3_clear_bindings(update)
                sqlite3_bind_text(update, 1, JourneyStoryBuilder.title(homeLabel: homeLabel, stops: stops), -1, transient)
                bind(try encoder.encode(stops), to: update, at: 2)
                sqlite3_bind_text(update, 3, story.id, -1, transient)
                bind(previous, to: update, at: 4)
                guard sqlite3_step(update) == SQLITE_DONE else { throw failure() }
                updated += Int(sqlite3_changes(db))
            }
            try execute("COMMIT")
            return (selected.count, updated, hasMore)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func detail(momentID: String) throws -> PhotoMoment? {
        let moment = try prepare("""
            SELECT m.start,m.end,m.narrative,p.album_id,p.published_at,m.selection,m.context_source,
                   m.reviewed_group_title,m.grouping_source,m.grouping_reason,m.grouping_state,m.grouping_kind,
                   m.display_evidence,m.continuity_reason FROM moments m
            LEFT JOIN publications p ON p.moment_id=m.id WHERE m.id=?
            """)
        defer { sqlite3_finalize(moment) }
        sqlite3_bind_text(moment, 1, momentID, -1, transient)
        guard sqlite3_step(moment) == SQLITE_ROW else { return nil }
        let photosStatement = try prepare("""
            SELECT a.payload FROM moment_assets ma JOIN assets a ON a.id=ma.asset_id
            WHERE ma.moment_id=? ORDER BY ma.sequence
            """)
        defer { sqlite3_finalize(photosStatement) }
        sqlite3_bind_text(photosStatement, 1, momentID, -1, transient)
        let decoder = JSONDecoder()
        var photos: [IndexedPhoto] = []
        while sqlite3_step(photosStatement) == SQLITE_ROW {
            // Skip undecodable asset payloads so older Moments still open for review.
            if let photo = try? decoder.decode(IndexedPhoto.self, from: blob(photosStatement, 0)) {
                photos.append(photo)
            }
        }
        let narrative: MomentNarrative? = sqlite3_column_type(moment, 2) == SQLITE_NULL
            ? nil : (try? decoder.decode(MomentNarrative.self, from: blob(moment, 2)))
        let selection: MomentSelection? = sqlite3_column_type(moment, 5) == SQLITE_NULL
            ? nil : (try? decoder.decode(MomentSelection.self, from: blob(moment, 5)))
        let evidence: [String: PhotoDisplayEvidence]? = sqlite3_column_type(moment, 12) == SQLITE_NULL
            ? nil : (try? decoder.decode([String: PhotoDisplayEvidence].self, from: blob(moment, 12)))
        return PhotoMoment(id: momentID,
            start: Date(timeIntervalSince1970: sqlite3_column_double(moment, 0)),
            end: Date(timeIntervalSince1970: sqlite3_column_double(moment, 1)), photos: photos,
            selection: selection, narrative: narrative, contextSource: optionalText(moment, 6),
            reviewedGroupTitle: optionalText(moment, 7), groupingSource: optionalText(moment, 8),
            groupingReason: optionalText(moment, 9),
            groupingState: optionalText(moment, 10).flatMap(MomentGroupingState.init(rawValue:)),
            groupingKind: optionalText(moment, 11).flatMap(AutomaticMomentSegmentKind.init(rawValue:)),
            displayEvidence: evidence, continuityReason: optionalText(moment, 13),
            publishedAlbumID: optionalText(moment, 3),
            publishedDate: sqlite3_column_type(moment, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(moment, 4)))
    }

    /// Mirrors a committed legacy projection while Catalog v2 is the workspace read model.
    /// The legacy writer is removed in Phase 3; until then this transaction is the cutover boundary.
    func synchronize(moments: [PhotoMoment], activeMomentIDs: Set<String>? = nil) throws {
        let previousRevision = try currentCatalogRevision()
        var removedStale = false
        try execute("BEGIN IMMEDIATE")
        do {
            try upsertMoments(moments)
            if let activeMomentIDs {
                let statement = try prepare("SELECT id FROM moments")
                var stale: [String] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    let id = text(statement, 0)
                    if !activeMomentIDs.contains(id) { stale.append(id) }
                }
                sqlite3_finalize(statement)
                if !stale.isEmpty {
                    let remove = try prepare("DELETE FROM moments WHERE id=?")
                    defer { sqlite3_finalize(remove) }
                    for id in stale {
                        sqlite3_reset(remove); sqlite3_clear_bindings(remove)
                        sqlite3_bind_text(remove, 1, id, -1, transient)
                        guard sqlite3_step(remove) == SQLITE_DONE else { throw failure() }
                    }
                    removedStale = true
                }
            }
            try execute("COMMIT")
            // Rebuild after commit. Upserts no longer delete Moment rows, so Story membership
            // stays intact across routine syncs; stale removals still cascade and need rebuild.
            let revisionChanged = try currentCatalogRevision() != previousRevision
            let membershipMissing = try needsStoryProjection()
            if removedStale || revisionChanged || membershipMissing {
                try rebuildStories(calendar: .current)
            }
            cachedGoogleAssets.removeAll()
            cachedReviewDecisions.removeAll()
            cachedGoogleMoments.removeAll()
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func preparePublication(_ request: CuratedPublicationRequest,
                            now: Date = Date()) throws -> PublicationSagaRecord {
        try request.validate()
        let existing = try publicationRecord(momentID: request.momentID)
        var request = request
        if let existing {
            if existing.request.hasSameContent(as: request) { return existing }
            // An in-flight save keeps its durable intent; a finished one is updated in place.
            guard existing.phase == .succeeded else { throw PublicationFailure.conflictingOperation }
            request = request.updating(albumID: existing.receipt?.albumID ?? existing.request.targetAlbumID)
        }
        let record = PublicationSagaRecord(request: request, phase: .requested, receipt: nil,
            verificationAttempts: 0, nextVerificationAt: nil, lastError: nil, updatedAt: now)
        try writePublicationRecord(record)
        return record
    }

    /// The request behind a Moment's finished save, or `nil` while none has succeeded.
    func publishedRequest(momentID: String) throws -> CuratedPublicationRequest? {
        guard let record = try publicationRecord(momentID: momentID), record.phase == .succeeded else { return nil }
        return record.request
    }

    func pendingPublications() throws -> [PublicationSagaRecord] {
        let statement = try prepare("SELECT request,phase,receipt,verification_attempts,next_verification_at,last_error,updated_at FROM publication_operations WHERE phase != 'succeeded' ORDER BY updated_at")
        defer { sqlite3_finalize(statement) }
        var result: [PublicationSagaRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let record = try? decodePublication(statement) { result.append(record) }
        }
        return result
    }

    func markPublicationApplying(operationID: UUID, now: Date = Date()) throws {
        try updatePublication(operationID: operationID, phase: .applying, receipt: nil,
                              attempts: 0, next: nil, error: nil, now: now)
    }

    func markPublicationVerifying(operationID: UUID, receipt: CuratedAlbumReceipt?,
                                  error: String?, now: Date = Date()) throws -> PublicationSagaRecord {
        try updatePublication(operationID: operationID, phase: .verifying, receipt: receipt,
                              attempts: 0, next: now, error: error, now: now)
        return try requiredPublicationRecord(operationID: operationID)
    }

    func recordPublicationVerification(operationID: UUID, error: String,
                                       now: Date = Date()) throws -> PublicationSagaRecord {
        let statement = try prepare("UPDATE publication_operations SET verification_attempts=verification_attempts+1,next_verification_at=?,last_error=?,updated_at=? WHERE operation_id=? AND phase='verifying'")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.addingTimeInterval(1).timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, error, -1, transient)
        sqlite3_bind_double(statement, 3, now.timeIntervalSince1970)
        sqlite3_bind_text(statement, 4, operationID.uuidString, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
            throw PublicationFailure.conflictingOperation
        }
        return try requiredPublicationRecord(operationID: operationID)
    }

    func resetPublicationForRetry(operationID: UUID, now: Date = Date()) throws {
        try updatePublication(operationID: operationID, phase: .requested, receipt: nil,
                              attempts: 0, next: nil, error: nil, now: now)
    }

    func completePublication(operationID: UUID, receipt: CuratedAlbumReceipt,
                             date: Date) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let operation = try requiredPublicationRecord(operationID: operationID)
            guard operation.request.assetIDs.count == receipt.assetIDs.count,
                  Set(operation.request.assetIDs) == Set(receipt.assetIDs),
                  !receipt.albumID.isEmpty else { throw PublicationFailure.invalidReceipt }
            let update = try prepare("UPDATE publication_operations SET phase='succeeded',receipt=?,verification_attempts=verification_attempts+1,next_verification_at=NULL,last_error=NULL,updated_at=? WHERE operation_id=?")
            defer { sqlite3_finalize(update) }
            bind(try JSONEncoder().encode(receipt), to: update, at: 1)
            sqlite3_bind_double(update, 2, date.timeIntervalSince1970)
            sqlite3_bind_text(update, 3, operationID.uuidString, -1, transient)
            guard sqlite3_step(update) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                throw PublicationFailure.conflictingOperation
            }
            let marker = try prepare("INSERT OR REPLACE INTO publications VALUES(?,?,?)")
            defer { sqlite3_finalize(marker) }
            sqlite3_bind_text(marker, 1, operation.request.momentID, -1, transient)
            sqlite3_bind_text(marker, 2, receipt.albumID, -1, transient)
            sqlite3_bind_double(marker, 3, date.timeIntervalSince1970)
            guard sqlite3_step(marker) == SQLITE_DONE else { throw failure() }
            try recordManagedContainers(receipt)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func managedPhotoContainers() throws -> [ManagedPhotoContainer] {
        let statement = try prepare("SELECT id,kind,parent_id FROM managed_photo_containers ORDER BY kind,id")
        defer { sqlite3_finalize(statement) }
        var result: [ManagedPhotoContainer] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let kind = ManagedPhotoContainer.Kind(rawValue: text(statement, 1)) else { continue }
            result.append(ManagedPhotoContainer(id: text(statement, 0), kind: kind,
                parentID: optionalText(statement, 2)))
        }
        return result
    }

    func publicationCount() throws -> Int { try scalar("SELECT COUNT(*) FROM publications") }

    private func recordManagedContainers(_ receipt: CuratedAlbumReceipt) throws {
        if let parent = receipt.storyFolderID ?? receipt.yearFolderID {
            // An updated album may have moved to another Story folder.
            let move = try prepare("UPDATE managed_photo_containers SET parent_id=? WHERE id=? AND kind='album'")
            defer { sqlite3_finalize(move) }
            sqlite3_bind_text(move, 1, parent, -1, transient)
            sqlite3_bind_text(move, 2, receipt.albumID, -1, transient)
            guard sqlite3_step(move) == SQLITE_DONE else { throw failure() }
        }
        let created = Set(receipt.createdContainerIDs)
        guard !created.isEmpty else { return }
        let insert = try prepare("INSERT OR IGNORE INTO managed_photo_containers(id,kind,parent_id) VALUES(?,?,?)")
        defer { sqlite3_finalize(insert) }
        let candidates: [(String?, ManagedPhotoContainer.Kind, String?)] = [
            (receipt.rootFolderID, .root, nil),
            (receipt.yearFolderID, .year, receipt.rootFolderID),
            (receipt.storyFolderID, .story, receipt.yearFolderID),
            (receipt.albumID, .album, receipt.storyFolderID ?? receipt.yearFolderID)
        ]
        for (id, kind, parent) in candidates where id.map(created.contains) == true {
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            sqlite3_bind_text(insert, 1, id!, -1, transient)
            sqlite3_bind_text(insert, 2, kind.rawValue, -1, transient)
            if let parent { sqlite3_bind_text(insert, 3, parent, -1, transient) }
            else { sqlite3_bind_null(insert, 3) }
            guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
        }
    }

    func reconcileMomentIdentities(groups: [Set<String>], newID: () -> String = { UUID().uuidString }) throws -> MomentIdentityResolution {
        try execute("BEGIN DEFERRED")
        do {
            var members: [String: Set<String>] = [:]
            var anchors: [String: Set<String>] = [:]
            let membership = try prepare("""
                SELECT ma.moment_id,ma.asset_id,d.decision
                FROM moment_assets ma
                LEFT JOIN asset_decisions d ON d.asset_id=ma.asset_id ORDER BY ma.moment_id,ma.sequence
                """)
            defer { sqlite3_finalize(membership) }
            while sqlite3_step(membership) == SQLITE_ROW {
                let momentID = text(membership, 0)
                let assetID = text(membership, 1)
                members[momentID, default: []].insert(assetID)
                if optionalText(membership, 2) == "include" {
                    anchors[momentID, default: []].insert(assetID)
                }
            }
            let edits = try prepare("SELECT moment_id,protected_members FROM moment_edits WHERE protected_members IS NOT NULL")
            defer { sqlite3_finalize(edits) }
            while sqlite3_step(edits) == SQLITE_ROW {
                if let members = try? JSONDecoder().decode([String].self, from: blob(edits, 1)) {
                    anchors[text(edits, 0), default: []].formUnion(members)
                }
            }
            let entries = members.map { MomentIdentityEntry(id: $0.key, members: $0.value) }
            let result = try MomentIdentityResolver.resolve(previous: entries, groups: groups, anchors: anchors, newID: newID)
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func validation() throws -> CatalogV2Validation {
        CatalogV2Validation(assets: try scalar("SELECT COUNT(*) FROM assets"),
            moments: try scalar("SELECT COUNT(*) FROM moments"),
            memberships: try scalar("SELECT COUNT(*) FROM moment_assets"),
            edits: try scalar("SELECT COUNT(*) FROM moment_edits"),
            decisions: try scalar("SELECT COUNT(*) FROM asset_decisions"),
            places: try scalar("SELECT COUNT(*) FROM meaningful_places"),
            reviewedGroups: try scalar("SELECT COUNT(*) FROM reviewed_groups"),
            publications: try scalar("SELECT COUNT(*) FROM publications"),
            foreignKeyViolations: try scalar("SELECT COUNT(*) FROM pragma_foreign_key_check"))
    }

    func beginCandidateGeneration(algorithmVersion: String, evidenceVersion: String,
                                  sourceGenerationID: String? = nil, now: Date = Date(),
                                  id: String = UUID().uuidString) throws -> CurationGenerationRecord {
        guard !id.isEmpty, !algorithmVersion.isEmpty, !evidenceVersion.isEmpty else {
            throw failure("Generation identity and versions are required")
        }
        let statement = try prepare("""
            INSERT INTO curation_generations(
              id,algorithm_version,evidence_version,state,created_at,source_generation_id,
              catalog_revision,source_catalog_revision
            ) VALUES(?,?,?,'building',?,?,?,?)
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, transient)
        sqlite3_bind_text(statement, 2, algorithmVersion, -1, transient)
        sqlite3_bind_text(statement, 3, evidenceVersion, -1, transient)
        sqlite3_bind_double(statement, 4, now.timeIntervalSince1970)
        let source: String?
        if let sourceGenerationID { source = sourceGenerationID }
        else { source = try activeGenerationID() }
        bind(source, to: statement, at: 5)
        let revision = try currentCatalogRevision()
        sqlite3_bind_text(statement, 6, revision, -1, transient)
        sqlite3_bind_text(statement, 7, revision, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        return try requiredGeneration(id: id)
    }

    func snapshotActiveGeneration(algorithmVersion: String, evidenceVersion: String,
                                  metrics: CurationGenerationMetrics, now: Date = Date(),
                                  id: String = UUID().uuidString) throws -> CurationGenerationRecord {
        let photoCount = try scalar("SELECT COUNT(*) FROM moment_assets")
        let momentCount = try scalar("SELECT COUNT(*) FROM moments")
        guard metrics.photoCount == photoCount, metrics.momentCount == momentCount else {
            throw failure("Active generation metrics do not match the active catalog")
        }
        let revision = try currentCatalogRevision()
        if let active = try activeGenerationID() {
            try execute("BEGIN IMMEDIATE")
            do {
                let remove = try prepare("DELETE FROM generation_moments WHERE generation_id=?")
                sqlite3_bind_text(remove, 1, active, -1, transient)
                guard sqlite3_step(remove) == SQLITE_DONE else { sqlite3_finalize(remove); throw failure() }
                sqlite3_finalize(remove)
                try copyActiveMoments(to: active)
                let update = try prepare("""
                    UPDATE curation_generations SET algorithm_version=?,evidence_version=?,
                      completed_at=?,catalog_revision=?,metrics=? WHERE id=? AND state='active'
                    """)
                sqlite3_bind_text(update, 1, algorithmVersion, -1, transient)
                sqlite3_bind_text(update, 2, evidenceVersion, -1, transient)
                sqlite3_bind_double(update, 3, now.timeIntervalSince1970)
                sqlite3_bind_text(update, 4, revision, -1, transient)
                bind(try JSONEncoder().encode(metrics), to: update, at: 5)
                sqlite3_bind_text(update, 6, active, -1, transient)
                guard sqlite3_step(update) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                    sqlite3_finalize(update); throw failure("Active snapshot could not be refreshed")
                }
                sqlite3_finalize(update)
                try execute("COMMIT")
                return try requiredGeneration(id: active)
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
        try execute("BEGIN IMMEDIATE")
        do {
            let insert = try prepare("""
                INSERT INTO curation_generations(
                  id,algorithm_version,evidence_version,state,created_at,completed_at,
                  catalog_revision,metrics
                ) VALUES(?,?,?,'active',?,?,?,?)
                """)
            sqlite3_bind_text(insert, 1, id, -1, transient)
            sqlite3_bind_text(insert, 2, algorithmVersion, -1, transient)
            sqlite3_bind_text(insert, 3, evidenceVersion, -1, transient)
            sqlite3_bind_double(insert, 4, now.timeIntervalSince1970)
            sqlite3_bind_double(insert, 5, now.timeIntervalSince1970)
            sqlite3_bind_text(insert, 6, revision, -1, transient)
            bind(try JSONEncoder().encode(metrics), to: insert, at: 7)
            guard sqlite3_step(insert) == SQLITE_DONE else { sqlite3_finalize(insert); throw failure() }
            sqlite3_finalize(insert)
            try copyActiveMoments(to: id)
            let state = try prepare("INSERT INTO catalog_generation_state VALUES(1,?,NULL)")
            sqlite3_bind_text(state, 1, id, -1, transient)
            guard sqlite3_step(state) == SQLITE_DONE else { sqlite3_finalize(state); throw failure() }
            sqlite3_finalize(state)
            try execute("COMMIT")
            return try requiredGeneration(id: id)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Candidate writes are isolated from the active read model. All validation and writes
    /// complete synchronously inside one transaction; no PhotoKit or other async work belongs here.
    func stageCandidateGeneration(id: String, moments: [PhotoMoment],
                                  metrics: CurationGenerationMetrics, now: Date = Date()) throws {
        let memberships = moments.flatMap { $0.photos.map(\.id) }
        guard Set(moments.map(\.id)).count == moments.count,
              moments.allSatisfy({ !$0.photos.isEmpty && Set($0.photos.map(\.id)).count == $0.photos.count }),
              Set(memberships).count == memberships.count,
              metrics.photoCount == moments.reduce(0, { $0 + $1.photos.count }),
              metrics.momentCount == moments.count,
              metrics.highlightCount == moments.reduce(0, { $0 + ($1.selection?.selected.count ?? 0) }) else {
            throw failure("Candidate generation metrics or membership are inconsistent")
        }
        try execute("BEGIN IMMEDIATE")
        do {
            let generation = try requiredGeneration(id: id)
            guard generation.state == .building else {
                throw failure("Only a building generation can be staged")
            }
            try ensureCandidateAssetsExist(moments)
            try writeGenerationMoments(generationID: id, moments: moments)
            let encodedMetrics = try JSONEncoder().encode(metrics)
            let update = try prepare("""
                UPDATE curation_generations SET state='candidate',completed_at=?,metrics=?,failure=NULL
                WHERE id=? AND state='building'
                """)
            defer { sqlite3_finalize(update) }
            sqlite3_bind_double(update, 1, now.timeIntervalSince1970)
            bind(encodedMetrics, to: update, at: 2)
            sqlite3_bind_text(update, 3, id, -1, transient)
            guard sqlite3_step(update) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                throw failure("Candidate generation changed while it was being staged")
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func failGeneration(id: String, reason: String, now: Date = Date()) throws {
        let statement = try prepare("""
            UPDATE curation_generations SET state='failed',completed_at=?,failure=?
            WHERE id=? AND state='building'
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, reason, -1, transient)
        sqlite3_bind_text(statement, 3, id, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
            throw failure("Only a building generation can fail")
        }
    }

    func generation(id: String) throws -> CurationGenerationRecord? {
        try generationRecord(where: "id=?", bindValue: id)
    }

    func activeGeneration() throws -> CurationGenerationRecord? {
        guard let id = try activeGenerationID() else { return nil }
        return try generation(id: id)
    }

    func candidateSummaries(generationID: String) throws -> [MomentSummary] {
        let statement = try prepare("""
            SELECT id,revision,start,end,headline,photo_count,highlight_count,cover_asset_id,
                   fallback_cover_2,fallback_cover_3,narrative IS NOT NULL,
                   COALESCE(grouping_state,'') NOT IN ('','preparing')
            FROM generation_moments WHERE generation_id=? ORDER BY start DESC,id
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, generationID, -1, transient)
        var result: [MomentSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(MomentSummary(id: text(statement, 0), revision: Int(sqlite3_column_int64(statement, 1)),
                start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                headline: optionalText(statement, 4), photoCount: Int(sqlite3_column_int64(statement, 5)),
                highlightCount: Int(sqlite3_column_int64(statement, 6)), coverAssetID: optionalText(statement, 7),
                fallbackCoverAssetIDs: [optionalText(statement, 7), optionalText(statement, 8),
                    optionalText(statement, 9)].compactMap { $0 }, customized: false, inPhotos: false,
                inGoogle: false, narrativeReady: sqlite3_column_int(statement, 10) != 0,
                groupingReady: sqlite3_column_int(statement, 11) != 0))
        }
        return result
    }

    func activateCandidateGeneration(id: String, comparison: CurationGenerationComparison,
                                     now: Date = Date()) throws {
        let candidate = try requiredGeneration(id: id)
        let currentRevision = try currentCatalogRevision()
        guard candidate.state == .candidate, candidate.metrics == comparison.candidate,
              comparison.canRecommendActivation,
              let activeID = try activeGenerationID(), candidate.sourceGenerationID == activeID,
              candidate.sourceCatalogRevision == currentRevision,
              try requiredGeneration(id: activeID).metrics == comparison.active else {
            throw failure("Candidate generation has not passed the activation comparison")
        }
        try installGeneration(id: id, replacing: activeID, now: now)
    }

    func rollbackGeneration(now: Date = Date()) throws {
        guard let activeID = try activeGenerationID(), let previousID = try previousGenerationID(),
              try requiredGeneration(id: activeID).state == .active,
              try requiredGeneration(id: previousID).state == .retired else {
            throw failure("No previous curation generation is available")
        }
        try installGeneration(id: previousID, replacing: activeID, now: now)
    }

    private static let schemaSQL = """
            CREATE TABLE IF NOT EXISTS assets(
              id TEXT PRIMARY KEY, created REAL, modified REAL, latitude REAL, longitude REAL,
              favorite INTEGER NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL,
              similarity_category TEXT, source_revision TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS assets_created ON assets(created DESC,id);
            CREATE TABLE IF NOT EXISTS moments(
              id TEXT PRIMARY KEY, revision INTEGER NOT NULL DEFAULT 1, start REAL NOT NULL, end REAL NOT NULL,
              headline TEXT, narrative BLOB, photo_count INTEGER NOT NULL, highlight_count INTEGER NOT NULL,
              cover_asset_id TEXT REFERENCES assets(id),selection BLOB,context_source TEXT,
              reviewed_group_title TEXT,grouping_source TEXT,grouping_reason TEXT,grouping_state TEXT,
              grouping_kind TEXT,display_evidence BLOB,continuity_reason TEXT,fallback_covers BLOB,
              fallback_cover_2 TEXT,fallback_cover_3 TEXT);
            CREATE INDEX IF NOT EXISTS moments_start ON moments(start DESC,id);
            CREATE TABLE IF NOT EXISTS moment_assets(
              moment_id TEXT NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
              asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
              sequence INTEGER NOT NULL, display_role TEXT NOT NULL,
              PRIMARY KEY(moment_id,asset_id), UNIQUE(moment_id,sequence));
            CREATE TABLE IF NOT EXISTS stories(
              id TEXT PRIMARY KEY,title TEXT NOT NULL,start REAL NOT NULL,end REAL NOT NULL,
              photo_count INTEGER NOT NULL,highlight_count INTEGER NOT NULL,
              cover_asset_id TEXT REFERENCES assets(id),moment_count INTEGER NOT NULL,
              kind TEXT NOT NULL DEFAULT 'outing',evidence BLOB);
            CREATE INDEX IF NOT EXISTS stories_start ON stories(start DESC,id);
            CREATE TABLE IF NOT EXISTS story_moments(
              story_id TEXT NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
              moment_id TEXT NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
              sequence INTEGER NOT NULL,PRIMARY KEY(story_id,moment_id),UNIQUE(story_id,sequence),
              UNIQUE(moment_id));
            CREATE TABLE IF NOT EXISTS story_edits(
              story_id TEXT PRIMARY KEY,title TEXT,synopsis TEXT);
            CREATE TABLE IF NOT EXISTS story_merges(
              id TEXT PRIMARY KEY, moment_ids TEXT NOT NULL, title TEXT);
            CREATE TABLE IF NOT EXISTS moment_edits(
              moment_id TEXT PRIMARY KEY,
              title TEXT, description TEXT, protected_members BLOB);
            CREATE TABLE IF NOT EXISTS asset_decisions(
              asset_id TEXT PRIMARY KEY, decision TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS meaningful_places(
              id TEXT PRIMARY KEY,label TEXT NOT NULL,address TEXT NOT NULL,latitude REAL NOT NULL,
              longitude REAL NOT NULL,radius REAL NOT NULL,payload BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS reviewed_groups(id TEXT PRIMARY KEY,title TEXT NOT NULL,source_text BLOB);
            CREATE TABLE IF NOT EXISTS reviewed_group_assets(
              group_id TEXT NOT NULL REFERENCES reviewed_groups(id) ON DELETE CASCADE,
              asset_id TEXT NOT NULL,
              PRIMARY KEY(group_id,asset_id));
            CREATE TABLE IF NOT EXISTS publications(
              moment_id TEXT PRIMARY KEY REFERENCES moments(id) ON DELETE CASCADE,
              album_id TEXT NOT NULL,published_at REAL);
            CREATE TABLE IF NOT EXISTS publication_operations(
              operation_id TEXT PRIMARY KEY,moment_id TEXT NOT NULL UNIQUE REFERENCES moments(id) ON DELETE CASCADE,
              request BLOB NOT NULL,phase TEXT NOT NULL,receipt BLOB,verification_attempts INTEGER NOT NULL,
              next_verification_at REAL,last_error TEXT,updated_at REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS publication_operations_phase ON publication_operations(phase,next_verification_at);
            CREATE TABLE IF NOT EXISTS managed_photo_containers(
              id TEXT PRIMARY KEY,kind TEXT NOT NULL CHECK(kind IN ('root','year','story','album')),parent_id TEXT);
            CREATE TABLE IF NOT EXISTS schema_migrations(name TEXT PRIMARY KEY,completed_at REAL NOT NULL,completed INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS curation_generations(
              id TEXT PRIMARY KEY,algorithm_version TEXT NOT NULL,evidence_version TEXT NOT NULL,
              state TEXT NOT NULL CHECK(state IN ('building','candidate','active','retired','failed')),
              created_at REAL NOT NULL,completed_at REAL,source_generation_id TEXT,
              catalog_revision TEXT NOT NULL,source_catalog_revision TEXT,metrics BLOB,failure TEXT);
            CREATE INDEX IF NOT EXISTS curation_generations_state ON curation_generations(state,created_at);
            CREATE TABLE IF NOT EXISTS generation_moments(
              generation_id TEXT NOT NULL REFERENCES curation_generations(id) ON DELETE CASCADE,
              id TEXT NOT NULL,revision INTEGER NOT NULL,start REAL NOT NULL,end REAL NOT NULL,
              headline TEXT,narrative BLOB,photo_count INTEGER NOT NULL,highlight_count INTEGER NOT NULL,
              cover_asset_id TEXT REFERENCES assets(id),selection BLOB,context_source TEXT,
              reviewed_group_title TEXT,grouping_source TEXT,grouping_reason TEXT,grouping_state TEXT,
              grouping_kind TEXT,display_evidence BLOB,continuity_reason TEXT,
              fallback_cover_2 TEXT,fallback_cover_3 TEXT,PRIMARY KEY(generation_id,id));
            CREATE INDEX IF NOT EXISTS generation_moments_start
              ON generation_moments(generation_id,start DESC,id);
            CREATE TABLE IF NOT EXISTS generation_moment_assets(
              generation_id TEXT NOT NULL,moment_id TEXT NOT NULL,asset_id TEXT NOT NULL REFERENCES assets(id),
              sequence INTEGER NOT NULL,display_role TEXT NOT NULL,
              PRIMARY KEY(generation_id,moment_id,asset_id),UNIQUE(generation_id,moment_id,sequence),
              FOREIGN KEY(generation_id,moment_id) REFERENCES generation_moments(generation_id,id) ON DELETE CASCADE);
            CREATE TABLE IF NOT EXISTS catalog_generation_state(
              singleton INTEGER PRIMARY KEY CHECK(singleton=1),
              active_generation_id TEXT NOT NULL REFERENCES curation_generations(id),
              previous_generation_id TEXT REFERENCES curation_generations(id));
            PRAGMA user_version=12;
            """

    private func activeGenerationID() throws -> String? {
        let statement = try prepare("SELECT active_generation_id FROM catalog_generation_state WHERE singleton=1")
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? text(statement, 0) : nil
    }

    private func previousGenerationID() throws -> String? {
        let statement = try prepare("SELECT previous_generation_id FROM catalog_generation_state WHERE singleton=1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return optionalText(statement, 0)
    }

    private func currentCatalogRevision() throws -> String {
        let statement = try prepare("SELECT id,revision FROM moments ORDER BY id")
        defer { sqlite3_finalize(statement) }
        var hash = SHA256()
        while sqlite3_step(statement) == SQLITE_ROW {
            hash.update(data: Data(text(statement, 0).utf8))
            var revision = sqlite3_column_int64(statement, 1).bigEndian
            withUnsafeBytes(of: &revision) { hash.update(bufferPointer: $0) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func copyActiveMoments(to generationID: String) throws {
        let moments = try prepare("""
            INSERT INTO generation_moments
            SELECT ?,id,revision,start,end,headline,narrative,photo_count,highlight_count,cover_asset_id,
                   selection,context_source,reviewed_group_title,grouping_source,grouping_reason,
                   grouping_state,grouping_kind,display_evidence,continuity_reason,
                   fallback_cover_2,fallback_cover_3 FROM moments
            """)
        sqlite3_bind_text(moments, 1, generationID, -1, transient)
        guard sqlite3_step(moments) == SQLITE_DONE else { sqlite3_finalize(moments); throw failure() }
        sqlite3_finalize(moments)
        let members = try prepare("""
            INSERT INTO generation_moment_assets
            SELECT ?,moment_id,asset_id,sequence,display_role FROM moment_assets
            """)
        sqlite3_bind_text(members, 1, generationID, -1, transient)
        guard sqlite3_step(members) == SQLITE_DONE else { sqlite3_finalize(members); throw failure() }
        sqlite3_finalize(members)
    }

    private func installGeneration(id: String, replacing activeID: String, now: Date) throws {
        let moments = try loadGenerationMoments(id: id)
        let candidateIDs = Set(moments.map(\.id))
        try validateDurableMomentState(candidateIDs: candidateIDs, generationID: id)
        try execute("BEGIN IMMEDIATE")
        do {
            let active = try prepare("SELECT id FROM moments")
            var stale: [String] = []
            while sqlite3_step(active) == SQLITE_ROW {
                let momentID = text(active, 0)
                if !candidateIDs.contains(momentID) { stale.append(momentID) }
            }
            sqlite3_finalize(active)
            let remove = try prepare("DELETE FROM moments WHERE id=?")
            for momentID in stale {
                sqlite3_reset(remove); sqlite3_clear_bindings(remove)
                sqlite3_bind_text(remove, 1, momentID, -1, transient)
                guard sqlite3_step(remove) == SQLITE_DONE else { sqlite3_finalize(remove); throw failure() }
            }
            sqlite3_finalize(remove)
            try upsertMoments(moments)
            let retire = try prepare("UPDATE curation_generations SET state='retired' WHERE id=? AND state='active'")
            sqlite3_bind_text(retire, 1, activeID, -1, transient)
            guard sqlite3_step(retire) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                sqlite3_finalize(retire); throw failure("Active generation changed during activation")
            }
            sqlite3_finalize(retire)
            let activate = try prepare("UPDATE curation_generations SET state='active',completed_at=? WHERE id=? AND state IN ('candidate','retired')")
            sqlite3_bind_double(activate, 1, now.timeIntervalSince1970)
            sqlite3_bind_text(activate, 2, id, -1, transient)
            guard sqlite3_step(activate) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                sqlite3_finalize(activate); throw failure("Target generation cannot be activated")
            }
            sqlite3_finalize(activate)
            let state = try prepare("UPDATE catalog_generation_state SET active_generation_id=?,previous_generation_id=? WHERE singleton=1 AND active_generation_id=?")
            sqlite3_bind_text(state, 1, id, -1, transient)
            sqlite3_bind_text(state, 2, activeID, -1, transient)
            sqlite3_bind_text(state, 3, activeID, -1, transient)
            guard sqlite3_step(state) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                sqlite3_finalize(state); throw failure("Generation state changed during activation")
            }
            sqlite3_finalize(state)
            try execute("COMMIT")
            cachedGoogleAssets.removeAll(); cachedReviewDecisions.removeAll(); cachedGoogleMoments.removeAll()
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func requiredGeneration(id: String) throws -> CurationGenerationRecord {
        guard let value = try generationRecord(where: "id=?", bindValue: id) else {
            throw failure("Curation generation does not exist")
        }
        return value
    }

    private func generationRecord(where clause: String, bindValue: String) throws -> CurationGenerationRecord? {
        let statement = try prepare("""
            SELECT id,algorithm_version,evidence_version,state,created_at,completed_at,
                   source_generation_id,catalog_revision,source_catalog_revision,metrics,failure
            FROM curation_generations WHERE \(clause)
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, bindValue, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let state = CurationGenerationState(rawValue: text(statement, 3)) else {
            throw failure("Curation generation has an invalid state")
        }
        let metrics = sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil
            : try JSONDecoder().decode(CurationGenerationMetrics.self, from: blob(statement, 9))
        return CurationGenerationRecord(id: text(statement, 0), algorithmVersion: text(statement, 1),
            evidenceVersion: text(statement, 2), state: state,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            completedAt: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            sourceGenerationID: optionalText(statement, 6), catalogRevision: text(statement, 7),
            sourceCatalogRevision: optionalText(statement, 8), metrics: metrics,
            failure: optionalText(statement, 10))
    }

    private func ensureCandidateAssetsExist(_ moments: [PhotoMoment]) throws {
        let candidateAssets = Set(moments.flatMap { $0.photos.map(\.id) })
        let statement = try prepare("SELECT 1 FROM assets WHERE id=?")
        defer { sqlite3_finalize(statement) }
        for assetID in candidateAssets {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, assetID, -1, transient)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw failure("Candidate generation references an asset outside the indexed corpus")
            }
        }
        let active = try prepare("SELECT asset_id FROM moment_assets")
        defer { sqlite3_finalize(active) }
        var activeAssets = Set<String>()
        while sqlite3_step(active) == SQLITE_ROW { activeAssets.insert(text(active, 0)) }
        guard candidateAssets == activeAssets else {
            throw failure("Candidate generation does not cover the complete active Moment corpus")
        }
    }

    private func writeGenerationMoments(generationID: String, moments: [PhotoMoment]) throws {
        let remove = try prepare("DELETE FROM generation_moments WHERE generation_id=?")
        sqlite3_bind_text(remove, 1, generationID, -1, transient)
        guard sqlite3_step(remove) == SQLITE_DONE else { sqlite3_finalize(remove); throw failure() }
        sqlite3_finalize(remove)
        let insertMoment = try prepare("""
            INSERT INTO generation_moments VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
        let insertMember = try prepare("INSERT INTO generation_moment_assets VALUES(?,?,?,?,?)")
        defer { sqlite3_finalize(insertMoment); sqlite3_finalize(insertMember) }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        for moment in moments {
            let revision = SHA256.hash(data: try encoder.encode(moment)).prefix(8)
                .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } & UInt64(Int64.max)
            let selected = moment.selection?.selected ?? []
            let fallbacks = Array((selected + moment.photos.map(\.id).filter { !selected.contains($0) }).prefix(3))
            sqlite3_reset(insertMoment); sqlite3_clear_bindings(insertMoment)
            sqlite3_bind_text(insertMoment, 1, generationID, -1, transient)
            sqlite3_bind_text(insertMoment, 2, moment.id, -1, transient)
            sqlite3_bind_int64(insertMoment, 3, Int64(revision))
            sqlite3_bind_double(insertMoment, 4, moment.start.timeIntervalSince1970)
            sqlite3_bind_double(insertMoment, 5, moment.end.timeIntervalSince1970)
            bind(moment.narrative?.headline, to: insertMoment, at: 6)
            if let narrative = moment.narrative { bind(try encoder.encode(narrative), to: insertMoment, at: 7) }
            else { sqlite3_bind_null(insertMoment, 7) }
            sqlite3_bind_int64(insertMoment, 8, Int64(moment.photos.count))
            sqlite3_bind_int64(insertMoment, 9, Int64(selected.count))
            bind(selected.first ?? moment.photos.first?.id, to: insertMoment, at: 10)
            if let selection = moment.selection { bind(try encoder.encode(selection), to: insertMoment, at: 11) }
            else { sqlite3_bind_null(insertMoment, 11) }
            bind(moment.contextSource, to: insertMoment, at: 12)
            bind(moment.reviewedGroupTitle, to: insertMoment, at: 13)
            bind(moment.groupingSource, to: insertMoment, at: 14)
            bind(moment.groupingReason, to: insertMoment, at: 15)
            bind(moment.groupingState?.rawValue, to: insertMoment, at: 16)
            bind(moment.groupingKind?.rawValue, to: insertMoment, at: 17)
            if let evidence = moment.displayEvidence { bind(try encoder.encode(evidence), to: insertMoment, at: 18) }
            else { sqlite3_bind_null(insertMoment, 18) }
            bind(moment.continuityReason, to: insertMoment, at: 19)
            bind(fallbacks.count > 1 ? fallbacks[1] : nil, to: insertMoment, at: 20)
            bind(fallbacks.count > 2 ? fallbacks[2] : nil, to: insertMoment, at: 21)
            guard sqlite3_step(insertMoment) == SQLITE_DONE else { throw failure() }
            let highlights = Set(selected)
            for (sequence, photo) in moment.photos.enumerated() {
                sqlite3_reset(insertMember); sqlite3_clear_bindings(insertMember)
                sqlite3_bind_text(insertMember, 1, generationID, -1, transient)
                sqlite3_bind_text(insertMember, 2, moment.id, -1, transient)
                sqlite3_bind_text(insertMember, 3, photo.id, -1, transient)
                sqlite3_bind_int64(insertMember, 4, Int64(sequence))
                sqlite3_bind_text(insertMember, 5, highlights.contains(photo.id) ? "highlight" : "member", -1, transient)
                guard sqlite3_step(insertMember) == SQLITE_DONE else { throw failure() }
            }
        }
    }

    private func loadGenerationMoments(id: String) throws -> [PhotoMoment] {
        let statement = try prepare("""
            SELECT id,start,end,narrative,selection,context_source,reviewed_group_title,
                   grouping_source,grouping_reason,grouping_state,grouping_kind,display_evidence,
                   continuity_reason FROM generation_moments WHERE generation_id=? ORDER BY start DESC,id
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, transient)
        let photos = try prepare("""
            SELECT a.payload FROM generation_moment_assets gma JOIN assets a ON a.id=gma.asset_id
            WHERE gma.generation_id=? AND gma.moment_id=? ORDER BY gma.sequence
            """)
        defer { sqlite3_finalize(photos) }
        let decoder = JSONDecoder()
        var result: [PhotoMoment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let momentID = text(statement, 0)
            sqlite3_reset(photos); sqlite3_clear_bindings(photos)
            sqlite3_bind_text(photos, 1, id, -1, transient)
            sqlite3_bind_text(photos, 2, momentID, -1, transient)
            var members: [IndexedPhoto] = []
            while sqlite3_step(photos) == SQLITE_ROW {
                members.append(try decoder.decode(IndexedPhoto.self, from: blob(photos, 0)))
            }
            let narrative: MomentNarrative? = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil
                : try decoder.decode(MomentNarrative.self, from: blob(statement, 3))
            let selection: MomentSelection? = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil
                : try decoder.decode(MomentSelection.self, from: blob(statement, 4))
            let evidence: [String: PhotoDisplayEvidence]? = sqlite3_column_type(statement, 11) == SQLITE_NULL ? nil
                : try decoder.decode([String: PhotoDisplayEvidence].self, from: blob(statement, 11))
            result.append(PhotoMoment(id: momentID,
                start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)), photos: members,
                selection: selection, narrative: narrative, contextSource: optionalText(statement, 5),
                reviewedGroupTitle: optionalText(statement, 6), groupingSource: optionalText(statement, 7),
                groupingReason: optionalText(statement, 8),
                groupingState: optionalText(statement, 9).flatMap(MomentGroupingState.init(rawValue:)),
                groupingKind: optionalText(statement, 10).flatMap(AutomaticMomentSegmentKind.init(rawValue:)),
                displayEvidence: evidence, continuityReason: optionalText(statement, 12)))
        }
        return result
    }

    private func validateDurableMomentState(candidateIDs: Set<String>, generationID: String) throws {
        let durable = try prepare("""
            SELECT moment_id FROM moment_edits
            WHERE title IS NOT NULL OR description IS NOT NULL OR protected_members IS NOT NULL
            UNION SELECT moment_id FROM publications
            UNION SELECT moment_id FROM publication_operations
            """)
        defer { sqlite3_finalize(durable) }
        while sqlite3_step(durable) == SQLITE_ROW {
            guard candidateIDs.contains(text(durable, 0)) else {
                throw failure("Candidate generation would orphan user work or publication history")
            }
        }
        let anchors = try prepare("SELECT moment_id,protected_members FROM moment_edits WHERE protected_members IS NOT NULL")
        defer { sqlite3_finalize(anchors) }
        let membership = try prepare("""
            SELECT 1 FROM generation_moment_assets
            WHERE generation_id=? AND moment_id=? AND asset_id=?
            """)
        defer { sqlite3_finalize(membership) }
        while sqlite3_step(anchors) == SQLITE_ROW {
            let momentID = text(anchors, 0)
            let members = try JSONDecoder().decode([String].self, from: blob(anchors, 1))
            for assetID in members {
                sqlite3_reset(membership); sqlite3_clear_bindings(membership)
                sqlite3_bind_text(membership, 1, generationID, -1, transient)
                sqlite3_bind_text(membership, 2, momentID, -1, transient)
                sqlite3_bind_text(membership, 3, assetID, -1, transient)
                guard sqlite3_step(membership) == SQLITE_ROW else {
                    throw failure("Candidate generation would move a protected asset")
                }
            }
        }
    }

    private func importAssets() throws {
        try execute("""
            INSERT INTO assets(id,created,modified,latitude,longitude,favorite,width,height,similarity_category,source_revision,payload)
            SELECT id,created,
              CASE WHEN json_type(CAST(payload AS TEXT),'$.modified') IS NULL THEN NULL ELSE json_extract(CAST(payload AS TEXT),'$.modified')+978307200 END,
              json_extract(CAST(payload AS TEXT),'$.latitude'),json_extract(CAST(payload AS TEXT),'$.longitude'),
              COALESCE(json_extract(CAST(payload AS TEXT),'$.favorite'),0),
              json_extract(CAST(payload AS TEXT),'$.width'),json_extract(CAST(payload AS TEXT),'$.height'),
              json_extract(CAST(payload AS TEXT),'$.similarityCategory'),generation,payload FROM legacy.photos;
            """)
    }

    private func importMoments(_ moments: [PhotoMoment]) throws {
        let insertMoment = try prepare("""
            INSERT INTO moments VALUES(?,1,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              start=excluded.start,end=excluded.end,headline=excluded.headline,narrative=excluded.narrative,
              photo_count=excluded.photo_count,highlight_count=excluded.highlight_count,
              cover_asset_id=excluded.cover_asset_id,selection=excluded.selection,
              context_source=excluded.context_source,reviewed_group_title=excluded.reviewed_group_title,
              grouping_source=excluded.grouping_source,grouping_reason=excluded.grouping_reason,
              grouping_state=excluded.grouping_state,grouping_kind=excluded.grouping_kind,
              display_evidence=excluded.display_evidence,continuity_reason=excluded.continuity_reason,
              fallback_covers=excluded.fallback_covers,fallback_cover_2=excluded.fallback_cover_2,
              fallback_cover_3=excluded.fallback_cover_3
            """)
        let clearMembers = try prepare("DELETE FROM moment_assets WHERE moment_id=?")
        let insertMember = try prepare("INSERT OR IGNORE INTO moment_assets VALUES(?,?,?,?)")
        let insertPublication = try prepare("INSERT OR REPLACE INTO publications VALUES(?,?,?)")
        let updateRevision = try prepare("UPDATE moments SET revision=? WHERE id=?")
        defer {
            sqlite3_finalize(insertMoment); sqlite3_finalize(clearMembers)
            sqlite3_finalize(insertMember); sqlite3_finalize(insertPublication)
            sqlite3_finalize(updateRevision)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        for moment in moments {
            guard moment.photos.count == Set(moment.photos.map(\.id)).count else {
                throw failure("Moment \(moment.id) contains duplicate assets")
            }
            sqlite3_reset(insertMoment); sqlite3_clear_bindings(insertMoment)
            sqlite3_bind_text(insertMoment, 1, moment.id, -1, transient)
            sqlite3_bind_double(insertMoment, 2, moment.start.timeIntervalSince1970)
            sqlite3_bind_double(insertMoment, 3, moment.end.timeIntervalSince1970)
            bind(moment.narrative?.headline, to: insertMoment, at: 4)
            if let narrative = moment.narrative { bind(try encoder.encode(narrative), to: insertMoment, at: 5) }
            else { sqlite3_bind_null(insertMoment, 5) }
            sqlite3_bind_int64(insertMoment, 6, Int64(moment.photos.count))
            sqlite3_bind_int64(insertMoment, 7, Int64(moment.selection?.selected.count ?? 0))
            bind(moment.selection?.selected.first ?? moment.photos.first?.id, to: insertMoment, at: 8)
            if let selection = moment.selection { bind(try encoder.encode(selection), to: insertMoment, at: 9) }
            else { sqlite3_bind_null(insertMoment, 9) }
            bind(moment.contextSource, to: insertMoment, at: 10)
            bind(moment.reviewedGroupTitle, to: insertMoment, at: 11)
            bind(moment.groupingSource, to: insertMoment, at: 12)
            bind(moment.groupingReason, to: insertMoment, at: 13)
            bind(moment.groupingState?.rawValue, to: insertMoment, at: 14)
            bind(moment.groupingKind?.rawValue, to: insertMoment, at: 15)
            if let evidence = moment.displayEvidence { bind(try encoder.encode(evidence), to: insertMoment, at: 16) }
            else { sqlite3_bind_null(insertMoment, 16) }
            bind(moment.continuityReason, to: insertMoment, at: 17)
            let selected = moment.selection?.selected ?? []
            let fallbackCovers = Array((selected + moment.photos.map(\.id).filter { !selected.contains($0) }).prefix(3))
            bind(try encoder.encode(fallbackCovers), to: insertMoment, at: 18)
            bind(fallbackCovers.count > 1 ? fallbackCovers[1] : nil, to: insertMoment, at: 19)
            bind(fallbackCovers.count > 2 ? fallbackCovers[2] : nil, to: insertMoment, at: 20)
            guard sqlite3_step(insertMoment) == SQLITE_DONE else { throw failure() }
            let revision = SHA256.hash(data: try encoder.encode(moment)).prefix(8)
                .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } & UInt64(Int64.max)
            sqlite3_reset(updateRevision); sqlite3_clear_bindings(updateRevision)
            sqlite3_bind_int64(updateRevision, 1, Int64(revision))
            sqlite3_bind_text(updateRevision, 2, moment.id, -1, transient)
            guard sqlite3_step(updateRevision) == SQLITE_DONE else { throw failure() }
            sqlite3_reset(clearMembers); sqlite3_clear_bindings(clearMembers)
            sqlite3_bind_text(clearMembers, 1, moment.id, -1, transient)
            guard sqlite3_step(clearMembers) == SQLITE_DONE else { throw failure() }
            let highlights = Set(moment.selection?.selected ?? [])
            for (sequence, photo) in moment.photos.enumerated() {
                sqlite3_reset(insertMember); sqlite3_clear_bindings(insertMember)
                sqlite3_bind_text(insertMember, 1, moment.id, -1, transient)
                sqlite3_bind_text(insertMember, 2, photo.id, -1, transient)
                sqlite3_bind_int64(insertMember, 3, Int64(sequence))
                sqlite3_bind_text(insertMember, 4, highlights.contains(photo.id) ? "highlight" : "member", -1, transient)
                guard sqlite3_step(insertMember) == SQLITE_DONE else { throw failure() }
            }
            if let album = moment.publishedAlbumID {
                sqlite3_reset(insertPublication); sqlite3_clear_bindings(insertPublication)
                sqlite3_bind_text(insertPublication, 1, moment.id, -1, transient)
                sqlite3_bind_text(insertPublication, 2, album, -1, transient)
                if let date = moment.publishedDate { sqlite3_bind_double(insertPublication, 3, date.timeIntervalSince1970) }
                else { sqlite3_bind_null(insertPublication, 3) }
                guard sqlite3_step(insertPublication) == SQLITE_DONE else { throw failure() }
            }
        }
    }

    private func upsertMoments(_ moments: [PhotoMoment]) throws {
        let encoder = JSONEncoder()
        let preservedOperations = try moments.compactMap { try publicationRecord(momentID: $0.id) }
        var preservedMarkers: [(String, String, Date?)] = []
        let readMarker = try prepare("SELECT album_id,published_at FROM publications WHERE moment_id=?")
        for moment in moments {
            sqlite3_reset(readMarker); sqlite3_clear_bindings(readMarker)
            sqlite3_bind_text(readMarker, 1, moment.id, -1, transient)
            if sqlite3_step(readMarker) == SQLITE_ROW {
                preservedMarkers.append((moment.id, text(readMarker, 0),
                    sqlite3_column_type(readMarker, 1) == SQLITE_NULL ? nil
                        : Date(timeIntervalSince1970: sqlite3_column_double(readMarker, 1))))
            }
        }
        sqlite3_finalize(readMarker)
        let asset = try prepare("""
            INSERT INTO assets VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              created=excluded.created,modified=excluded.modified,latitude=excluded.latitude,
              longitude=excluded.longitude,favorite=excluded.favorite,width=excluded.width,
              height=excluded.height,similarity_category=excluded.similarity_category,
              source_revision=excluded.source_revision,payload=excluded.payload
            """)
        defer { sqlite3_finalize(asset) }
        for moment in moments {
            for photo in moment.photos {
                sqlite3_reset(asset); sqlite3_clear_bindings(asset)
                sqlite3_bind_text(asset, 1, photo.id, -1, transient)
                if let created = photo.created { sqlite3_bind_double(asset, 2, created.timeIntervalSince1970) } else { sqlite3_bind_null(asset, 2) }
                if let modified = photo.modified { sqlite3_bind_double(asset, 3, modified.timeIntervalSince1970) } else { sqlite3_bind_null(asset, 3) }
                if let latitude = photo.latitude { sqlite3_bind_double(asset, 4, latitude) } else { sqlite3_bind_null(asset, 4) }
                if let longitude = photo.longitude { sqlite3_bind_double(asset, 5, longitude) } else { sqlite3_bind_null(asset, 5) }
                sqlite3_bind_int(asset, 6, photo.favorite ? 1 : 0)
                sqlite3_bind_int64(asset, 7, Int64(photo.width)); sqlite3_bind_int64(asset, 8, Int64(photo.height))
                bind(photo.similarityCategory?.rawValue, to: asset, at: 9)
                sqlite3_bind_text(asset, 10, photo.analysisRevision, -1, transient)
                bind(try encoder.encode(photo), to: asset, at: 11)
                guard sqlite3_step(asset) == SQLITE_DONE else { throw failure() }
            }
        }
        // Upsert Moment rows in place. Never DELETE moments here — that cascades story_moments
        // and empties Journeys in the UI until rebuildStories finishes.
        try importMoments(moments)
        let restoreMarker = try prepare("INSERT OR REPLACE INTO publications VALUES(?,?,?)")
        defer { sqlite3_finalize(restoreMarker) }
        for (momentID, albumID, date) in preservedMarkers {
            sqlite3_reset(restoreMarker); sqlite3_clear_bindings(restoreMarker)
            sqlite3_bind_text(restoreMarker, 1, momentID, -1, transient)
            sqlite3_bind_text(restoreMarker, 2, albumID, -1, transient)
            if let date { sqlite3_bind_double(restoreMarker, 3, date.timeIntervalSince1970) }
            else { sqlite3_bind_null(restoreMarker, 3) }
            guard sqlite3_step(restoreMarker) == SQLITE_DONE else { throw failure() }
        }
        for record in preservedOperations { try writePublicationRecord(record) }
    }

    private func googleUploadedMoments(assetIDs: Set<String>, decisions: [String: ReviewDecision]) throws -> Set<String> {
        let statement = try prepare("""
            SELECT ma.moment_id,ma.asset_id,ma.display_role,m.selection IS NOT NULL
            FROM moment_assets ma JOIN moments m ON m.id=ma.moment_id ORDER BY ma.moment_id,ma.sequence
            """)
        defer { sqlite3_finalize(statement) }
        var selected: [String: (count: Int, uploaded: Int)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let momentID = text(statement, 0), assetID = text(statement, 1)
            let isSelected: Bool
            switch decisions[assetID] {
            case .include: isSelected = true
            case .exclude: isSelected = false
            case nil: isSelected = sqlite3_column_int(statement, 3) == 0 || text(statement, 2) == "highlight"
            }
            guard isSelected else { continue }
            let uploaded = assetIDs.contains(assetID) ? 1 : 0
            selected[momentID, default: (0, 0)].count += 1
            selected[momentID, default: (0, 0)].uploaded += uploaded
        }
        return Set(selected.compactMap { id, values in
            values.count > 0 && values.count == values.uploaded ? id : nil
        })
    }

    private func importUserState(_ input: CatalogV2MigrationInput) throws {
        let edit = try prepare("INSERT OR IGNORE INTO moment_edits VALUES(?,?,?,?)")
        let decision = try prepare("INSERT OR IGNORE INTO asset_decisions VALUES(?,?)")
        let place = try prepare("INSERT INTO meaningful_places VALUES(?,?,?,?,?,?,?)")
        let group = try prepare("INSERT INTO reviewed_groups VALUES(?,?,?)")
        let member = try prepare("INSERT OR IGNORE INTO reviewed_group_assets VALUES(?,?)")
        defer {
            sqlite3_finalize(edit)
            sqlite3_finalize(decision)
            sqlite3_finalize(place)
            sqlite3_finalize(group)
            sqlite3_finalize(member)
        }
        let encoder = JSONEncoder()
        for id in Set(input.titles.keys).union(input.descriptions.keys) {
            sqlite3_reset(edit); sqlite3_clear_bindings(edit)
            sqlite3_bind_text(edit, 1, id, -1, transient); bind(input.titles[id], to: edit, at: 2)
            bind(input.descriptions[id], to: edit, at: 3)
            if let members = input.protectedMembership[id] { bind(try encoder.encode(members.sorted()), to: edit, at: 4) }
            else { sqlite3_bind_null(edit, 4) }
            guard sqlite3_step(edit) == SQLITE_DONE else { throw failure() }
        }
        for (id, value) in input.decisions {
            sqlite3_reset(decision); sqlite3_clear_bindings(decision)
            sqlite3_bind_text(decision, 1, id, -1, transient); sqlite3_bind_text(decision, 2, value.rawValue, -1, transient)
            guard sqlite3_step(decision) == SQLITE_DONE else { throw failure() }
        }
        for value in input.places {
            sqlite3_reset(place); sqlite3_clear_bindings(place)
            sqlite3_bind_text(place, 1, value.id.uuidString, -1, transient); sqlite3_bind_text(place, 2, value.label, -1, transient)
            sqlite3_bind_text(place, 3, value.address, -1, transient); sqlite3_bind_double(place, 4, value.latitude)
            sqlite3_bind_double(place, 5, value.longitude); sqlite3_bind_double(place, 6, value.radius)
            bind(try encoder.encode(value), to: place, at: 7)
            guard sqlite3_step(place) == SQLITE_DONE else { throw failure() }
        }
        for value in input.reviewedGroups.groups {
            sqlite3_reset(group); sqlite3_clear_bindings(group)
            sqlite3_bind_text(group, 1, value.id, -1, transient); sqlite3_bind_text(group, 2, value.title, -1, transient)
            if let source = value.sourceText { bind(try encoder.encode(source), to: group, at: 3) } else { sqlite3_bind_null(group, 3) }
            guard sqlite3_step(group) == SQLITE_DONE else { throw failure() }
            for asset in value.members {
                sqlite3_reset(member); sqlite3_clear_bindings(member)
                sqlite3_bind_text(member, 1, value.id, -1, transient); sqlite3_bind_text(member, 2, asset, -1, transient)
                guard sqlite3_step(member) == SQLITE_DONE else { throw failure() }
            }
        }
    }

    private func validateDurableValues(_ input: CatalogV2MigrationInput) throws {
        let edit = try prepare("SELECT title,description,protected_members FROM moment_edits WHERE moment_id=?")
        let decision = try prepare("SELECT decision FROM asset_decisions WHERE asset_id=?")
        let publication = try prepare("SELECT album_id,published_at FROM publications WHERE moment_id=?")
        defer { sqlite3_finalize(edit); sqlite3_finalize(decision); sqlite3_finalize(publication) }
        let decoder = JSONDecoder()

        for id in Set(input.titles.keys).union(input.descriptions.keys) {
            sqlite3_reset(edit); sqlite3_clear_bindings(edit); sqlite3_bind_text(edit, 1, id, -1, transient)
            guard sqlite3_step(edit) == SQLITE_ROW,
                  optionalText(edit, 0) == input.titles[id], optionalText(edit, 1) == input.descriptions[id] else {
                throw failure("A user-authored Moment edit did not round-trip")
            }
            let savedMembers: Set<String>? = sqlite3_column_type(edit, 2) == SQLITE_NULL ? nil
                : Set(try decoder.decode([String].self, from: blob(edit, 2)))
            guard savedMembers == input.protectedMembership[id] else {
                throw failure("A protected Moment membership did not round-trip")
            }
        }
        for (id, expected) in input.decisions {
            sqlite3_reset(decision); sqlite3_clear_bindings(decision); sqlite3_bind_text(decision, 1, id, -1, transient)
            guard sqlite3_step(decision) == SQLITE_ROW, text(decision, 0) == expected.rawValue else {
                throw failure("A manual photo decision did not round-trip")
            }
        }
        for moment in input.moments where moment.publishedAlbumID != nil {
            sqlite3_reset(publication); sqlite3_clear_bindings(publication)
            sqlite3_bind_text(publication, 1, moment.id, -1, transient)
            guard sqlite3_step(publication) == SQLITE_ROW,
                  optionalText(publication, 0) == moment.publishedAlbumID else {
                throw failure("A Photos publication marker did not round-trip")
            }
            let savedDate = sqlite3_column_type(publication, 1) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(publication, 1))
            let dateMatches: Bool
            switch (savedDate, moment.publishedDate) {
            case (nil, nil): dateMatches = true
            case let (saved?, expected?): dateMatches = abs(saved.timeIntervalSince(expected)) < 0.001
            default: dateMatches = false
            }
            guard dateMatches else {
                throw failure("A Photos publication date did not round-trip")
            }
        }
    }

    private func publicationRecord(momentID: String) throws -> PublicationSagaRecord? {
        let statement = try prepare("SELECT request,phase,receipt,verification_attempts,next_verification_at,last_error,updated_at FROM publication_operations WHERE moment_id=?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, momentID, -1, transient)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw failure() }
        // Older journal rows can lack fields after schema evolution; skip rather than fail the whole sync.
        return try? decodePublication(statement)
    }

    private func requiredPublicationRecord(operationID: UUID) throws -> PublicationSagaRecord {
        let statement = try prepare("SELECT request,phase,receipt,verification_attempts,next_verification_at,last_error,updated_at FROM publication_operations WHERE operation_id=?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, operationID.uuidString, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw PublicationFailure.conflictingOperation }
        return try decodePublication(statement)
    }

    private func decodePublication(_ statement: OpaquePointer) throws -> PublicationSagaRecord {
        let decoder = JSONDecoder()
        let request = try decoder.decode(CuratedPublicationRequest.self, from: blob(statement, 0))
        guard let phase = PublicationSagaPhase(rawValue: text(statement, 1)) else {
            throw PublicationFailure.corruptJournal
        }
        let receipt = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil
            : try decoder.decode(CuratedAlbumReceipt.self, from: blob(statement, 2))
        return PublicationSagaRecord(request: request, phase: phase, receipt: receipt,
            verificationAttempts: Int(sqlite3_column_int64(statement, 3)),
            nextVerificationAt: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            lastError: optionalText(statement, 5),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)))
    }

    private func writePublicationRecord(_ record: PublicationSagaRecord) throws {
        let statement = try prepare("INSERT OR REPLACE INTO publication_operations VALUES(?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, record.request.operationID.uuidString, -1, transient)
        sqlite3_bind_text(statement, 2, record.request.momentID, -1, transient)
        bind(try JSONEncoder().encode(record.request), to: statement, at: 3)
        sqlite3_bind_text(statement, 4, record.phase.rawValue, -1, transient)
        if let receipt = record.receipt { bind(try JSONEncoder().encode(receipt), to: statement, at: 5) }
        else { sqlite3_bind_null(statement, 5) }
        sqlite3_bind_int64(statement, 6, Int64(record.verificationAttempts))
        if let next = record.nextVerificationAt { sqlite3_bind_double(statement, 7, next.timeIntervalSince1970) }
        else { sqlite3_bind_null(statement, 7) }
        bind(record.lastError, to: statement, at: 8)
        sqlite3_bind_double(statement, 9, record.updatedAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func updatePublication(operationID: UUID, phase: PublicationSagaPhase,
                                   receipt: CuratedAlbumReceipt?, attempts: Int,
                                   next: Date?, error: String?, now: Date) throws {
        let statement = try prepare("UPDATE publication_operations SET phase=?,receipt=?,verification_attempts=?,next_verification_at=?,last_error=?,updated_at=? WHERE operation_id=? AND phase != 'succeeded'")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, phase.rawValue, -1, transient)
        if let receipt { bind(try JSONEncoder().encode(receipt), to: statement, at: 2) }
        else { sqlite3_bind_null(statement, 2) }
        sqlite3_bind_int64(statement, 3, Int64(attempts))
        if let next { sqlite3_bind_double(statement, 4, next.timeIntervalSince1970) }
        else { sqlite3_bind_null(statement, 4) }
        bind(error, to: statement, at: 5)
        sqlite3_bind_double(statement, 6, now.timeIntervalSince1970)
        sqlite3_bind_text(statement, 7, operationID.uuidString, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
            throw PublicationFailure.conflictingOperation
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func execute(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() } }
    private func scalar(_ sql: String) throws -> Int {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(statement, 0))
    }
    private func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) {
        if let value { sqlite3_bind_text(statement, index, value, -1, transient) } else { sqlite3_bind_null(statement, index) }
    }
    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) {
        _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient) }
    }
    private func text(_ statement: OpaquePointer, _ index: Int32) -> String { String(cString: sqlite3_column_text(statement, index)) }
    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(statement, index)
    }
    private func blob(_ statement: OpaquePointer, _ index: Int32) -> Data {
        Data(bytes: sqlite3_column_blob(statement, index), count: Int(sqlite3_column_bytes(statement, index)))
    }
    private func failure(_ message: String? = nil) -> NSError {
        NSError(domain: "PhotoCurator.CatalogV2", code: 1, userInfo: [NSLocalizedDescriptionKey:
            message ?? db.map { String(cString: sqlite3_errmsg($0)) } ?? "Catalog database unavailable"])
    }
}
