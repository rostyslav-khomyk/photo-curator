import Foundation
import SQLite3

/// Last-resort experimental Journeys for unlocated pre-GPS life.
///
/// Wired as a last-resort pass after GPS Journeys and place outings in
/// `StoryHierarchyBuilder`. Signals may come from Photos.sqlite / private
/// PhotoKit and are not guaranteed across macOS updates. Never invents
/// coordinates and never glues years because the same person appears.
enum ExperimentalUnlocatedJourneyBuilder {
    static let stabilityWarning =
        "Experimental. Uses Photos.sqlite / private PhotoKit fields that may disappear in a future macOS update."
    static let extendedAccessKey = "curatorExperimentalPhotosMetadata"

    /// Settings opt-out for the Photos.sqlite pass. Unset keeps the shipped default (on).
    static var extendedAccessEnabled: Bool {
        UserDefaults.standard.object(forKey: extendedAccessKey) == nil
            || UserDefaults.standard.bool(forKey: extendedAccessKey)
    }
    static let defaultCutoff = Date(timeIntervalSince1970: 1_262_304_000) // 2010-01-01 UTC
    static let minimumLeftovers = 12
    static let maxDayGap = 4
    static let seasonMergeGap = 8
    static let minActiveDayPhotos = 3

    struct Photo: Equatable, Sendable {
        var id: String
        var created: Date
        var unlocated: Bool = true
        var claimedByGPSJourney: Bool = false
        var claimedByAlbumStory: Bool = false
        var namedPeople: [String] = []
        var faceCount: Int = 0
        var filenameFamily: String? = nil
        var filenameNumber: Int? = nil
        var timezoneName: String? = nil
        var albumTitles: [String] = []
    }

    struct Proposal: Equatable, Sendable, Identifiable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var photoIDs: [String]
        var namedPeople: [String: Int]
        var reasons: [String]
        var lastResort: Bool
        var experimental: Bool
        var stabilityWarning: String
        var latitude: Double?
        var longitude: Double?
    }

    /// Offer only when leftovers remain after GPS and album paths.
    static func shouldOffer(eligibleCount: Int) -> Bool {
        eligibleCount >= minimumLeftovers
    }

    static func eligible(_ photo: Photo, cutoff: Date = defaultCutoff) -> Bool {
        photo.unlocated
            && !photo.claimedByGPSJourney
            && !photo.claimedByAlbumStory
            && photo.created < cutoff
    }

    static func propose(
        photos: [Photo],
        review: OwnerAlbumStoryReview = .september2026OwnerPass,
        cutoff: Date = defaultCutoff,
        calendar: Calendar = utcCalendar
    ) -> [Proposal] {
        let leftover = photos.filter { eligible($0, cutoff: cutoff) }.sorted { $0.created < $1.created }
        guard shouldOffer(eligibleCount: leftover.count) else { return [] }
        let household = householdNames(leftover)
        let byDay = Dictionary(grouping: leftover, by: { calendar.startOfDay(for: $0.created) })
        let dumpDays = Set(byDay.keys.filter { isDump(byDay[$0] ?? []) })
        let activeDays = byDay.keys.sorted().filter { day in
            !dumpDays.contains(day) && (byDay[day]?.count ?? 0) >= minActiveDayPhotos
        }
        return mergeSameSeason(clusterDays(activeDays, calendar: calendar), calendar: calendar)
            .compactMap { days in
                let shots = days.flatMap { byDay[$0] ?? [] }.sorted { $0.created < $1.created }
                guard qualifies(shots, days: days, household: household, review: review, calendar: calendar)
                else { return nil }
                return makeProposal(shots, household: household, review: review, calendar: calendar)
            }
    }

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        return calendar
    }

    /// Import/scan burst: many files in minutes, almost no faces.
    static func isDump(_ photos: [Photo]) -> Bool {
        guard photos.count >= 50, let first = photos.min(by: { $0.created < $1.created }),
              let last = photos.max(by: { $0.created < $1.created }) else { return false }
        let duration = last.created.timeIntervalSince(first.created)
        guard duration < 30 * 60 else { return false }
        if photos.count >= 80 { return true }
        let faced = photos.filter { $0.faceCount > 0 }.count
        return Double(faced) / Double(photos.count) < 0.10
    }

    static func householdNames(_ photos: [Photo], threshold: Double = 0.30) -> Set<String> {
        let namedPhotos = photos.filter { !$0.namedPeople.isEmpty }
        guard namedPhotos.count >= 8 else { return [] }
        var counts: [String: Int] = [:]
        for photo in namedPhotos {
            for name in Set(photo.namedPeople) { counts[name, default: 0] += 1 }
        }
        let floor = Int((Double(namedPhotos.count) * threshold).rounded(.up))
        return Set(counts.compactMap { $0.value >= floor ? $0.key : nil })
    }

    private static func clusterDays(_ days: [Date], calendar: Calendar) -> [[Date]] {
        guard let first = days.first else { return [] }
        var groups: [[Date]] = [[first]]
        for day in days.dropFirst() {
            guard let previous = groups[groups.count - 1].last else { continue }
            let gap = calendar.dateComponents([.day], from: previous, to: day).day ?? 99
            let sameYear = calendar.component(.year, from: previous) == calendar.component(.year, from: day)
            if gap > maxDayGap || !sameYear {
                groups.append([day])
            } else {
                groups[groups.count - 1].append(day)
            }
        }
        return groups
    }

    /// Same calendar season and year may rejoin after a short rest. Never across years.
    static func mergeSameSeason(_ groups: [[Date]], calendar: Calendar) -> [[Date]] {
        guard var current = groups.first else { return [] }
        var merged: [[Date]] = []
        for next in groups.dropFirst() {
            guard let last = current.last, let first = next.first else { continue }
            let gap = calendar.dateComponents([.day], from: last, to: first).day ?? 99
            let sameYear = calendar.component(.year, from: last) == calendar.component(.year, from: first)
            let sameSeason = seasonName(last, calendar: calendar) == seasonName(first, calendar: calendar)
            if sameYear && sameSeason && gap <= seasonMergeGap {
                current.append(contentsOf: next)
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }

    private static func qualifies(_ photos: [Photo], days: [Date], household: Set<String>,
                                  review: OwnerAlbumStoryReview, calendar: Calendar) -> Bool {
        guard photos.count >= minimumLeftovers, let start = days.first, let end = days.last else { return false }
        let span = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        let busyDays = days.filter { day in
            photos.filter { calendar.startOfDay(for: $0.created) == day }.count >= 8
        }.count
        let kinds = albumKindCounts(photos, review: review)
        let journeyHits = kinds.photoCount[.journey] ?? 0
        let outingHits = kinds.photoCount[.outing] ?? 0
        let peopleHits = kinds.photoCount[.people] ?? 0
        let run = longestFilenameRun(photos, calendar: calendar)
        let faceRate = photos.isEmpty ? 0 : Double(photos.filter { $0.faceCount > 0 }.count) / Double(photos.count)
        let away = majorityAwayTimezone(photos) != nil
        let guests = personCounts(photos).filter { !household.contains($0.key) && $0.value >= 3 }
        let householdOnly = guests.isEmpty
        let density = Double(busyDays) / Double(max(span, 1))

        if peopleHits > 0, journeyHits == 0, outingHits == 0, busyDays < 2, span >= 10 {
            return false
        }
        if outingHits >= 8, journeyHits == 0, span <= 2, photos.count < 40 {
            return false
        }
        // Busy home months: only household, home timezone, no Journey album, sparse busy days.
        if householdOnly, !away, journeyHits < 8, span >= 12, density < 0.45 {
            return false
        }
        if journeyHits >= 8 { return true }
        if span >= 2, run >= 10, photos.count >= minimumLeftovers { return true }
        if busyDays >= 2, span >= 2, photos.count >= 20 { return true }
        if span == 1, photos.count >= 40, faceRate >= 0.30 { return true }
        return false
    }

    private static func makeProposal(_ photos: [Photo], household: Set<String>,
                                     review: OwnerAlbumStoryReview, calendar: Calendar) -> Proposal {
        guard let first = photos.first, let last = photos.last else {
            return Proposal(id: "experimental-empty", title: "", start: .distantPast, end: .distantPast,
                            photoIDs: [], namedPeople: [:], reasons: [], lastResort: true,
                            experimental: true, stabilityWarning: stabilityWarning,
                            latitude: nil, longitude: nil)
        }
        let start = first.created
        let end = last.created
        let people = personCounts(photos)
        let kinds = albumKindCounts(photos, review: review)
        let run = longestFilenameRun(photos, calendar: calendar)
        let faceRate = Int((Double(photos.filter { $0.faceCount > 0 }.count) / Double(photos.count) * 100)
            .rounded())
        let span = (calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                            to: calendar.startOfDay(for: end)).day ?? 0) + 1
        var reasons = [
            "last-resort after GPS and album Stories",
            "\(photos.count) unlocated photos across \(span) day\(span == 1 ? "" : "s")",
            "faces on \(faceRate)% of photos"
        ]
        if let album = kinds.topJourneyTitle {
            reasons.append("owner Journey album “\(album)”")
        }
        if run >= 10 { reasons.append("filename run of \(run)") }
        let cast = castNames(people, photos: photos, household: household)
        if !cast.isEmpty {
            reasons.append("cast \(formatCast(cast) ?? "")")
        }
        let guests = cast.filter { !household.contains($0) }
        if !guests.isEmpty {
            reasons.append("guests \(formatCast(guests) ?? "")")
        }
        let title = title(for: photos, people: people, household: household, kinds: kinds, calendar: calendar)
        let fingerprint = "experimental-unlocated|\(Int(start.timeIntervalSince1970))|\(Int(end.timeIntervalSince1970))|\(photos.map(\.id).sorted().joined(separator: ","))"
        return Proposal(
            id: "experimental-" + MomentContinuity.digest(Data(fingerprint.utf8)),
            title: title,
            start: start,
            end: end,
            photoIDs: photos.map(\.id),
            namedPeople: people,
            reasons: reasons,
            lastResort: true,
            experimental: true,
            stabilityWarning: stabilityWarning,
            latitude: nil,
            longitude: nil
        )
    }

    private static func title(for photos: [Photo], people: [String: Int], household: Set<String>,
                              kinds: AlbumKindSummary, calendar: Calendar) -> String {
        let mid = photos[photos.count / 2].created
        let seasonYear = "\(seasonName(mid, calendar: calendar)) \(calendar.component(.year, from: mid))"
        let peopleLabel = formatCast(castNames(people, photos: photos, household: household))
        let base: String
        if let album = kinds.topJourneyTitle {
            base = UnlocatedAlbumStoryBuilder.displayTitle(
                albumTitle: album, start: photos[0].created, end: photos[photos.count - 1].created,
                disambiguateByYear: false, calendar: calendar
            )
        } else if let place = majorityAwayTimezone(photos) {
            base = "\(seasonYear) · \(place)"
        } else {
            base = seasonYear
        }
        guard let peopleLabel else { return base }
        return "\(base) · \(peopleLabel)"
    }

    /// Household present on the stretch, then quieter guests. Cap 5 people by full name.
    static func castNames(_ people: [String: Int], photos: [Photo], household: Set<String> = [],
                          limit: Int = 5) -> [String] {
        let named = photos.filter { !$0.namedPeople.isEmpty }.count
        guard named >= 6 else { return [] }
        let householdFloor = max(3, Int((Double(named) * 0.12).rounded(.up)))
        let guestFloor = max(3, Int((Double(named) * 0.05).rounded(.up)))
        func ranked(inHousehold: Bool, floor: Int) -> [String] {
            people
                .filter { inHousehold ? household.contains($0.key) : !household.contains($0.key) }
                .filter { $0.value >= floor }
                .sorted {
                    if $0.value != $1.value { return $0.value > $1.value }
                    return $0.key < $1.key
                }
                .map(\.key)
        }
        var chosen: [String] = []
        var seen = Set<String>()
        func take(_ names: [String]) {
            for name in names {
                guard chosen.count < limit else { return }
                guard seen.insert(displayName(name).lowercased()).inserted else { continue }
                chosen.append(name)
            }
        }
        take(ranked(inHousehold: true, floor: householdFloor))
        take(ranked(inHousehold: false, floor: guestFloor))
        return chosen
    }

    static func formatCast(_ names: [String]) -> String? {
        var seen = Set<String>()
        var labels: [String] = []
        for name in names {
            let label = displayName(name)
            guard !label.isEmpty, seen.insert(label.lowercased()).inserted else { continue }
            labels.append(label)
        }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    private static func personCounts(_ photos: [Photo]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for photo in photos {
            for name in Set(photo.namedPeople) { counts[name, default: 0] += 1 }
        }
        return counts
    }

    private struct AlbumKindSummary {
        var photoCount: [OwnerAlbumStoryKind: Int] = [:]
        var topJourneyTitle: String?
    }

    private static func albumKindCounts(_ photos: [Photo], review: OwnerAlbumStoryReview) -> AlbumKindSummary {
        var summary = AlbumKindSummary()
        var journeyTitles: [String: Int] = [:]
        for photo in photos {
            var seen = Set<OwnerAlbumStoryKind>()
            for title in photo.albumTitles {
                guard let kind = review.kind(forAlbumTitle: title) else { continue }
                if seen.insert(kind).inserted {
                    summary.photoCount[kind, default: 0] += 1
                }
                if kind == .journey {
                    journeyTitles[title, default: 0] += 1
                }
            }
        }
        summary.topJourneyTitle = journeyTitles.max(by: { $0.value < $1.value })?.key
        return summary
    }

    private static func longestFilenameRun(_ photos: [Photo], calendar: Calendar) -> Int {
        let rows: [(family: String, number: Int, day: Int)] = photos.compactMap { photo in
            guard let family = photo.filenameFamily, let number = photo.filenameNumber else { return nil }
            let day = Int(calendar.startOfDay(for: photo.created).timeIntervalSince1970 / 86_400)
            return (family, number, day)
        }
        return UnlocatedHistorySignals.filenameRuns(rows).max() ?? 0
    }

    private static func majorityAwayTimezone(_ photos: [Photo]) -> String? {
        var counts: [String: Int] = [:]
        for photo in photos {
            guard let zone = photo.timezoneName, let place = placeName(forTimeZone: zone) else { continue }
            counts[place, default: 0] += 1
        }
        guard let best = counts.max(by: { $0.value < $1.value }),
              best.value * 2 >= photos.count else { return nil }
        return best.key
    }

    static func placeName(forTimeZone zone: String) -> String? {
        let trimmed = zone.trimmingCharacters(in: .whitespacesAndNewlines)
        let home: Set<String> = ["Europe/Kiev", "Europe/Kyiv", "GMT+0200", "GMT+2"]
        if home.contains(trimmed) { return nil }
        switch trimmed {
        case "Europe/London": return "London"
        case "Europe/Uzhgorod", "Europe/Uzhhorod": return "Uzhhorod"
        case "Europe/Amsterdam": return "Amsterdam"
        default:
            guard let city = trimmed.split(separator: "/").last, city.count >= 3 else { return nil }
            return city.replacingOccurrences(of: "_", with: " ")
        }
    }

    static func seasonName(_ date: Date, calendar: Calendar = utcCalendar) -> String {
        switch calendar.component(.month, from: date) {
        case 12, 1, 2: return "Winter"
        case 3, 4, 5: return "Spring"
        case 6, 7, 8: return "Summer"
        default: return "Autumn"
        }
    }

    /// Photos People name with collapsed whitespace; first and last names both stay.
    private static func displayName(_ full: String) -> String {
        full.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Map leftover Moments to Stories after GPS/outing claim. Empty stops — no invented pins.
    static func stories(
        moments: [UnlocatedAlbumStoryBuilder.MomentMembership],
        photos: [Photo],
        claimedMomentIDs: Set<String>,
        review: OwnerAlbumStoryReview = .september2026OwnerPass,
        cutoff: Date = defaultCutoff,
        calendar: Calendar = utcCalendar
    ) -> [CurationStory] {
        let available = moments.filter { !claimedMomentIDs.contains($0.id) }
        let availableAssets = Set(available.flatMap(\.assetIDs))
        let leftover = photos.map { photo -> Photo in
            var copy = photo
            copy.claimedByGPSJourney = !availableAssets.contains(photo.id)
            copy.claimedByAlbumStory = false
            return copy
        }
        return propose(photos: leftover, review: review, cutoff: cutoff, calendar: calendar).compactMap { proposal in
            let members = Set(proposal.photoIDs)
            let matched = available.filter { !$0.assetIDs.isDisjoint(with: members) }
                .sorted { $0.start < $1.start }
            guard let first = matched.first, let last = matched.last else { return nil }
            return CurationStory(
                id: proposal.id,
                start: first.start,
                end: last.end,
                momentIDs: matched.map(\.id),
                placeID: proposal.title,
                kind: .journey,
                stops: []
            )
        }
    }
}

/// Optional Photos.sqlite overlay. Soft-fails when the library is unreadable.
enum ExperimentalUnlocatedSignalLoader {
    struct Overlay: Equatable, Sendable {
        var namedPeople: [String: [String]] = [:]
        var filenames: [String: String] = [:]
        var timezones: [String: String] = [:]
        var albums: [String: [String]] = [:]

        func applied(to photo: ExperimentalUnlocatedJourneyBuilder.Photo) -> ExperimentalUnlocatedJourneyBuilder.Photo {
            var copy = photo
            if let names = namedPeople[photo.id] ?? namedPeople[Self.uuid(photo.id)] {
                copy.namedPeople = names
                copy.faceCount = max(copy.faceCount, names.count)
            }
            if let name = filenames[photo.id] ?? filenames[Self.uuid(photo.id)] {
                copy.filenameFamily = UnlocatedHistorySignals.filenameFamily(name)
                copy.filenameNumber = UnlocatedHistorySignals.filenameNumber(name)
            }
            if let zone = timezones[photo.id] ?? timezones[Self.uuid(photo.id)] {
                copy.timezoneName = zone
            }
            if let titles = albums[photo.id] ?? albums[Self.uuid(photo.id)] {
                copy.albumTitles = titles
            }
            return copy
        }

        static func uuid(_ catalogID: String) -> String {
            String(catalogID.split(separator: "/").first ?? Substring(catalogID))
        }
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var key: String?
        var loaded = Date.distantPast
        var overlay = Overlay()
    }
    private static let cache = Cache()
    /// Photos' own background work touches the WAL constantly; pre-2010 names, filenames and
    /// timezones rarely change, so a snapshot this recent is reused even when the key moved.
    static let maximumOverlayAge: TimeInterval = 15 * 60

    /// Photos rewrites its database and WAL on every change; size and modification date of both
    /// identify a snapshot cheaply.
    static func snapshotKey(_ source: URL, fileManager: FileManager = .default) -> String? {
        let parts = [source.path, source.path + "-wal"].map { path -> String in
            let attributes = try? fileManager.attributesOfItem(atPath: path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return "\(size)@\(modified)"
        }
        guard parts[0] != "-1@-1.0" else { return nil }
        return "\(source.path)|" + parts.joined(separator: "|")
    }

    /// Story rebuilds run after every Moment change; re-reading Photos.sqlite each time dominated
    /// refinement, so the overlay is reused until the Photos database changes.
    static func load(library: URL = PhotosInternalsProbe.defaultLibrary,
                     fileManager: FileManager = .default) -> Overlay {
        let source = library.appendingPathComponent("database/Photos.sqlite")
        let key = snapshotKey(source, fileManager: fileManager)
        cache.lock.lock()
        let sameSource = cache.key?.hasPrefix(source.path + "|") == true
        if let key, sameSource, cache.key == key || Date().timeIntervalSince(cache.loaded) < maximumOverlayAge {
            defer { cache.lock.unlock() }
            return cache.overlay
        }
        cache.lock.unlock()
        let overlay = loadUncached(source: source, fileManager: fileManager)
        cache.lock.lock()
        cache.key = key
        cache.loaded = Date()
        cache.overlay = overlay
        cache.lock.unlock()
        return overlay
    }

    private static func loadUncached(source: URL, fileManager: FileManager) -> Overlay {
        do {
            let url = try PhotosInternalsProbe.readableDatabase(source, fileManager: fileManager)
            defer { if url != source {
                try? fileManager.removeItem(at: url)
                try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
                try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
            } }
            return try read(url: url)
        } catch {
            return Overlay()
        }
    }

    static func read(url: URL) throws -> Overlay {
        let db = try SQLiteReadOnly(url: url)
        defer { db.close() }
        let assetTable = try db.firstTable(in: ["ZASSET", "ZGENERICASSET"])
        let attrTable = try? db.firstTable(in: ["ZADDITIONALASSETATTRIBUTES"])
        let assetColumns = try db.columns(assetTable)
        let attrColumns = (try? attrTable.map { try db.columns($0) }) ?? []
        guard let uuidColumn = ["ZUUID", "ZIDENTIFIER"].first(where: { assetColumns.contains($0) }) else {
            return Overlay()
        }
        let cutoff = PhotosInternalsProbe.pre2010.timeIntervalSince1970 - PhotosInternalsProbe.coreDataEpoch
        let dateColumn = try db.firstColumn(in: assetColumns, names: ["ZDATECREATED"])
        let latExpr = assetColumns.contains("ZLATITUDE") ? "a.ZLATITUDE" : "NULL"
        let lonExpr = assetColumns.contains("ZLONGITUDE") ? "a.ZLONGITUDE" : "NULL"
        let unlocated = """
            (\(latExpr) IS NULL OR \(lonExpr) IS NULL OR (
                ABS(\(latExpr)) < 0.0001 AND ABS(\(lonExpr)) < 0.0001
            ) OR ABS(\(latExpr)) > 90 OR ABS(\(lonExpr)) > 180)
            """
        let scope = "a.\(dateColumn) < \(cutoff) AND \(unlocated)"
        var overlay = Overlay()
        if let attrTable {
            if attrColumns.contains("ZORIGINALFILENAME") {
                overlay.filenames = try labeled(db: db, sql: """
                    SELECT a.\(uuidColumn), r.ZORIGINALFILENAME FROM \(assetTable) a
                    JOIN \(attrTable) r ON a.Z_PK = r.ZASSET
                    WHERE \(scope) AND r.ZORIGINALFILENAME IS NOT NULL
                    """)
            }
            if attrColumns.contains("ZTIMEZONENAME") {
                overlay.timezones = try labeled(db: db, sql: """
                    SELECT a.\(uuidColumn), r.ZTIMEZONENAME FROM \(assetTable) a
                    JOIN \(attrTable) r ON a.Z_PK = r.ZASSET
                    WHERE \(scope) AND r.ZTIMEZONENAME IS NOT NULL AND TRIM(r.ZTIMEZONENAME) != ''
                    """)
            }
        }
        let tables = try db.tables()
        if tables.contains("ZDETECTEDFACE"), tables.contains("ZPERSON") {
            let faceColumns = try db.columns("ZDETECTEDFACE")
            let personColumns = try db.columns("ZPERSON")
            let assetFK = ["ZASSETFORFACE", "ZASSET"].first { faceColumns.contains($0) }
            let personFK = ["ZPERSONFORFACE", "ZPERSON"].first { faceColumns.contains($0) }
            let nameColumn = ["ZFULLNAME", "ZDISPLAYNAME"].first { personColumns.contains($0) }
            if let assetFK, let personFK, let nameColumn {
                overlay.namedPeople = try names(db: db, sql: """
                    SELECT a.\(uuidColumn), p.\(nameColumn) FROM \(assetTable) a
                    JOIN ZDETECTEDFACE f ON f.\(assetFK) = a.Z_PK
                    JOIN ZPERSON p ON p.Z_PK = f.\(personFK)
                    WHERE \(scope) AND p.\(nameColumn) IS NOT NULL AND TRIM(p.\(nameColumn)) != ''
                    """)
            }
        }
        return overlay
    }

    private static func labeled(db: SQLiteReadOnly, sql: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for (uuid, value) in try db.stringPairsAsText(sql) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            result[uuid] = trimmed
            result[uuid + "/L0/001"] = trimmed
        }
        return result
    }

    private static func names(db: SQLiteReadOnly, sql: String) throws -> [String: [String]] {
        var result: [String: Set<String>] = [:]
        for (uuid, name) in try db.stringPairsAsText(sql) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            result[uuid, default: []].insert(trimmed)
            result[uuid + "/L0/001", default: []].insert(trimmed)
        }
        return result.mapValues { $0.sorted() }
    }
}

extension SQLiteReadOnly {
    func stringPairsAsText(_ sql: String) throws -> [(String, String)] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var values: [(String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let left = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let right = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            values.append((left, right))
        }
        return values
    }
}
