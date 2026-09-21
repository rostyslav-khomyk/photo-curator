import Foundation
import SQLite3

struct MomentSummary: Equatable, Sendable {
    let id: String
    let revision: Int
    let start: Date
    let end: Date
    let headline: String?
    let photoCount: Int
    let highlightCount: Int
    let coverAssetID: String?
    let customized: Bool
    let inPhotos: Bool
}

struct CatalogV2MigrationInput: @unchecked Sendable {
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
private final class CatalogV2Connection: @unchecked Sendable {
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
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            guard sqlite3_exec(opened, "PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;", nil, nil, nil) == SQLITE_OK,
                  sqlite3_exec(opened, schema, nil, nil, nil) == SQLITE_OK else {
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
    static let schemaVersion = 1
    private let connection: CatalogV2Connection
    private var db: OpaquePointer? { connection.db }
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

    func summaries() throws -> [MomentSummary] {
        let statement = try prepare("""
            SELECT m.id,m.revision,m.start,m.end,COALESCE(e.title,m.headline),m.photo_count,m.highlight_count,
                   m.cover_asset_id,e.moment_id IS NOT NULL,p.moment_id IS NOT NULL
            FROM moments m LEFT JOIN moment_edits e ON e.moment_id=m.id
            LEFT JOIN publications p ON p.moment_id=m.id ORDER BY m.start DESC,m.id
            """)
        defer { sqlite3_finalize(statement) }
        var result: [MomentSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(MomentSummary(id: text(statement, 0), revision: Int(sqlite3_column_int64(statement, 1)),
                start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                headline: optionalText(statement, 4), photoCount: Int(sqlite3_column_int64(statement, 5)),
                highlightCount: Int(sqlite3_column_int64(statement, 6)), coverAssetID: optionalText(statement, 7),
                customized: sqlite3_column_int(statement, 8) != 0, inPhotos: sqlite3_column_int(statement, 9) != 0))
        }
        return result
    }

    func detail(momentID: String) throws -> PhotoMoment? {
        let moment = try prepare("""
            SELECT m.start,m.end,m.narrative,p.album_id,p.published_at FROM moments m
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
        var photos: [IndexedPhoto] = []
        while sqlite3_step(photosStatement) == SQLITE_ROW {
            photos.append(try JSONDecoder().decode(IndexedPhoto.self, from: blob(photosStatement, 0)))
        }
        let narrative: MomentNarrative? = sqlite3_column_type(moment, 2) == SQLITE_NULL
            ? nil : try JSONDecoder().decode(MomentNarrative.self, from: blob(moment, 2))
        return PhotoMoment(id: momentID,
            start: Date(timeIntervalSince1970: sqlite3_column_double(moment, 0)),
            end: Date(timeIntervalSince1970: sqlite3_column_double(moment, 1)), photos: photos,
            narrative: narrative, publishedAlbumID: optionalText(moment, 3),
            publishedDate: sqlite3_column_type(moment, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(moment, 4)))
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
                anchors[text(edits, 0), default: []].formUnion(
                    try JSONDecoder().decode([String].self, from: blob(edits, 1)))
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

    private static let schemaSQL = """
            CREATE TABLE IF NOT EXISTS assets(
              id TEXT PRIMARY KEY, created REAL, modified REAL, latitude REAL, longitude REAL,
              favorite INTEGER NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL,
              similarity_category TEXT, source_revision TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS assets_created ON assets(created DESC,id);
            CREATE TABLE IF NOT EXISTS moments(
              id TEXT PRIMARY KEY, revision INTEGER NOT NULL DEFAULT 1, start REAL NOT NULL, end REAL NOT NULL,
              headline TEXT, narrative BLOB, photo_count INTEGER NOT NULL, highlight_count INTEGER NOT NULL,
              cover_asset_id TEXT REFERENCES assets(id));
            CREATE INDEX IF NOT EXISTS moments_start ON moments(start DESC,id);
            CREATE TABLE IF NOT EXISTS moment_assets(
              moment_id TEXT NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
              asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
              sequence INTEGER NOT NULL, display_role TEXT NOT NULL,
              PRIMARY KEY(moment_id,asset_id), UNIQUE(moment_id,sequence));
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
            CREATE TABLE IF NOT EXISTS schema_migrations(name TEXT PRIMARY KEY,completed_at REAL NOT NULL,completed INTEGER NOT NULL);
            PRAGMA user_version=1;
            """

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
        let insertMoment = try prepare("INSERT INTO moments VALUES(?,1,?,?,?,?,?,?,?)")
        let insertMember = try prepare("INSERT OR IGNORE INTO moment_assets VALUES(?,?,?,?)")
        let insertPublication = try prepare("INSERT INTO publications VALUES(?,?,?)")
        defer { sqlite3_finalize(insertMoment); sqlite3_finalize(insertMember); sqlite3_finalize(insertPublication) }
        let encoder = JSONEncoder()
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
            guard sqlite3_step(insertMoment) == SQLITE_DONE else { throw failure() }
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
