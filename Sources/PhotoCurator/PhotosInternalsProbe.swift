import Foundation
import Photos
import SQLite3

/// Read-only probes for PhotoKit internals used to qualify unlocated-history evidence.
/// Never writes the Photos library. Live sqlite work copies WAL sidecars into a temp
/// snapshot when the source is readable; otherwise it records `unauthorized`.
enum PhotosInternalsProbe {
    static let coreDataEpoch: TimeInterval = 978_307_200
    static let pre2010 = Date(timeIntervalSince1970: 1_262_304_000)
    static let defaultLibrary = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Photos Library.photoslibrary")

    struct Report: Codable, Equatable {
        var generatedAt: TimeInterval
        var libraryPath: String
        var privatePhotoKit: Source
        var photosSQLite: Source
        var searchIndex: Source
    }

    struct Source: Codable, Equatable {
        var status: String
        var detail: String
        var coverage: Coverage?
    }

    struct Coverage: Codable, Equatable {
        var photos: Int
        var unlocated: Int
        var pre2010: Int
        var pre2010Unlocated: Int
        var withTitle: Int
        var withTimezoneName: Int
        var withTimezoneOffset: Int
        var withInferredTimezone: Int
        var withReverseLocation: Int
        var reverseLocationOnUnlocatedPre2010: Int
        var withImportSession: Int
        var withExifTimestamp: Int
        var withOriginalFilename: Int
        var placeLikeTitles: Int
        var searchPlaceOnUnlocatedPre2010: Int
        var searchDetectedTextOnUnlocatedPre2010: Int
        var searchCameraOnUnlocatedPre2010: Int
        var searchCategoryCounts: [String: Int]
        var discoveredKeys: [String]
        var sampleKinds: [String]
        var signals: UnlocatedHistorySignals?
    }

    static let searchCategories: [Int: String] = [
        1: "placeName", 2: "street", 3: "neighborhood", 4: "locality", 5: "city",
        6: "subLocality", 7: "region", 8: "locality8", 9: "namedArea", 10: "state",
        11: "stateAbbreviation", 12: "country", 14: "bodyOfWater",
        1000: "home", 1001: "work", 1100: "month", 1101: "year", 1103: "holiday",
        1104: "season", 1200: "keywords", 1201: "title", 1202: "description",
        1203: "detectedText", 1300: "person", 1500: "label", 1600: "activity",
        1700: "venue", 1701: "venueType", 2100: "photoName", 2200: "source",
        2300: "camera"
    ]

    static let privateAssetKeys = [
        "title", "filename", "originalFilename", "timeZoneOffset", "timezoneOffset",
        "timeZoneName", "timezoneName", "inferredTimeZoneOffset", "comment",
        "assetDescription", "accessibilityDescription"
    ]

    /// Early-exit for `Photo Curator --probe-photos-internals [report.json]`.
    /// Returns true when the process should not continue into the UI.
    @discardableResult
    static func runCommandLineIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let index = arguments.firstIndex(of: "--probe-photos-internals") else { return false }
        let destination: URL
        if arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("-") {
            destination = URL(fileURLWithPath: arguments[index + 1])
        } else {
            destination = fileManager.temporaryDirectory
                .appendingPathComponent("photo-curator-internals-probe.json")
        }
        do {
            logProgress("start \(destination.path)")
            let report = live(fileManager: fileManager, requestAccess: true)
            try write(report, to: destination, fileManager: fileManager)
            logProgress("wrote \(destination.path)")
            fputs(summary(report) + "\nWrote \(destination.path)\n", stdout)
            exit(0)
        } catch {
            logProgress("failed \(error.localizedDescription)")
            fputs("Photos internals probe failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func write(_ report: Report, to destination: URL, fileManager: FileManager = .default) throws {
        let data = try JSONEncoder().encode(report)
        try data.write(to: destination, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    static func summary(_ report: Report) -> String {
        func line(_ name: String, _ source: Source) -> String {
            let coverage = source.coverage.map {
                let extra = $0.signals.map {
                    " faces=\($0.withAnyFace) named=\($0.withNamedFace) unnamedClusters=\($0.distinctUnnamedClusters) busyDays=\($0.busyDays8Plus) dumps=\($0.importDumpDays) fileRuns10=\($0.filenameRunsOf10Plus)"
                } ?? ""
                return "pre2010Unlocated=\($0.pre2010Unlocated) title=\($0.withTitle) tzName=\($0.withTimezoneName) reverseOnUnlocated=\($0.reverseLocationOnUnlocatedPre2010)\(extra)"
            } ?? "no-coverage"
            return "\(name): \(source.status) — \(source.detail); \(coverage)"
        }
        return [
            line("privatePhotoKit", report.privatePhotoKit),
            line("photosSQLite", report.photosSQLite),
            line("searchIndex", report.searchIndex)
        ].joined(separator: "\n")
    }

    static func live(fileManager: FileManager = .default, library: URL = defaultLibrary,
                     requestAccess: Bool = false) -> Report {
        // PhotoKit/TCC callbacks need the main run loop. Opening Photos.sqlite
        // on the main thread deadlocks: guarded_open waits for a grant that
        // cannot finish while this thread is blocked.
        let kit = privatePhotoKit(requestAccess: requestAccess)
        logProgress("photoKit \(kit.status)")
        let sql = pumpWhile {
            photosSQLite(library: library, fileManager: fileManager)
        } ?? Source(status: "error", detail: "sqlite open timed out", coverage: nil)
        logProgress("sqlite \(sql.status)")
        var merged = sql
        if var coverage = merged.coverage {
            var signals = coverage.signals ?? .empty
            applyPhotoKitAlbumSignals(to: &signals)
            coverage.signals = signals
            merged.coverage = coverage
        }
        let search = pumpWhile {
            searchIndex(library: library, fileManager: fileManager)
        } ?? Source(status: "error", detail: "search open timed out", coverage: nil)
        return Report(
            generatedAt: Date().timeIntervalSince1970,
            libraryPath: library.path,
            privatePhotoKit: kit,
            photosSQLite: merged,
            searchIndex: search
        )
    }

    static func applyPhotoKitAlbumSignals(to signals: inout UnlocatedHistorySignals,
                                          review: OwnerAlbumStoryReview = .september2026OwnerPass) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d AND creationDate < %@",
            PHAssetMediaType.image.rawValue,
            pre2010 as NSDate
        )
        var kindPhotos: [String: Int] = signals.albumKindPhotos
        var busyShare: [String: Int] = signals.busyDayShareByKind
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        albums.enumerateObjects { album, _, _ in
            guard let title = album.localizedTitle, !title.isEmpty else { return }
            let kind = review.kind(forAlbumTitle: title)?.rawValue ?? "unlabeled"
            let members = PHAsset.fetchAssets(in: album, options: options)
            guard members.count > 0 else { return }
            kindPhotos[kind, default: 0] += members.count
            guard kind != "unlabeled" else { return }
            var days: [Int: Int] = [:]
            members.enumerateObjects { asset, _, _ in
                guard asset.location == nil, let created = asset.creationDate else { return }
                let day = Int(created.timeIntervalSince1970 / 86_400)
                days[day, default: 0] += 1
            }
            busyShare[kind, default: 0] += days.values.filter { $0 >= 8 }.count
        }
        signals.albumKindPhotos = kindPhotos
        signals.busyDayShareByKind = busyShare
    }

    static func privatePhotoKit(sampleLimit: Int = 400, requestAccess: Bool = false) -> Source {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if requestAccess, status == .notDetermined {
            let lock = DispatchSemaphore(value: 0)
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                status = newStatus
                lock.signal()
            }
            let deadline = Date().addingTimeInterval(60)
            while lock.wait(timeout: .now() + 0.05) == .timedOut {
                if Date() > deadline { break }
                if Thread.isMainThread {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
            }
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
        guard status == .authorized || status == .limited else {
            return Source(status: "unauthorized",
                          detail: "PhotoKit status \(HistoricalMetadataAudit.authorizationLabel(status))",
                          coverage: nil)
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d AND creationDate < %@",
            PHAssetMediaType.image.rawValue,
            pre2010 as NSDate
        )
        let assets = PHAsset.fetchAssets(with: options)
        var coverage = Coverage.empty
        coverage.photos = assets.count
        var discovered = Set<String>()
        var kinds: [String] = []
        assets.enumerateObjects { asset, index, stop in
            if asset.location == nil { coverage.unlocated += 1 }
            coverage.pre2010 += 1
            let unlocated = asset.location == nil
            if unlocated { coverage.pre2010Unlocated += 1 }
            guard index < sampleLimit else { return }
            let values = safeValues(on: asset)
            discovered.formUnion(values.keys)
            if nonempty(values["title"]) {
                coverage.withTitle += 1
                if AlbumOutlinePatterns.looksPlaceLike(values["title"] ?? "") {
                    coverage.placeLikeTitles += 1
                    appendKind("placeLikeTitle", to: &kinds)
                } else {
                    appendKind("title", to: &kinds)
                }
            }
            if nonempty(values["timeZoneName"]) || nonempty(values["timezoneName"]) {
                coverage.withTimezoneName += 1
                appendKind("timezoneName", to: &kinds)
            }
            if values["timeZoneOffset"] != nil || values["timezoneOffset"] != nil {
                coverage.withTimezoneOffset += 1
            }
            if values["inferredTimeZoneOffset"] != nil {
                coverage.withInferredTimezone += 1
            }
            if nonempty(values["filename"]) || nonempty(values["originalFilename"]) {
                coverage.withOriginalFilename += 1
            }
        }
        coverage.discoveredKeys = discovered.sorted()
        coverage.sampleKinds = kinds
        return Source(status: "ok",
                      detail: "sampled \(min(sampleLimit, assets.count)) of \(assets.count) pre-2010 PhotoKit images",
                      coverage: coverage)
    }

    static func photosSQLite(url: URL) throws -> Coverage {
        let db = try SQLiteReadOnly(url: url)
        defer { db.close() }
        let assetTable = try db.firstTable(in: ["ZASSET", "ZGENERICASSET"])
        let attrTable = try db.firstTable(in: ["ZADDITIONALASSETATTRIBUTES"])
        let assetColumns = try db.columns(assetTable)
        let attrColumns = try db.columns(attrTable)
        let dateColumn = try db.firstColumn(in: assetColumns, names: ["ZDATECREATED"])
        let latColumn = assetColumns.contains("ZLATITUDE") ? "ZLATITUDE" : nil
        let lonColumn = assetColumns.contains("ZLONGITUDE") ? "ZLONGITUDE" : nil
        let join = "a.Z_PK = r.ZASSET"
        let cutoff = pre2010.timeIntervalSince1970 - coreDataEpoch
        func present(_ column: String, table: String = "r") -> String {
            "CASE WHEN \(table).\(column) IS NULL THEN 0 WHEN TRIM(CAST(\(table).\(column) AS TEXT)) = '' THEN 0 ELSE 1 END"
        }
        let latExpr = latColumn.map { "a.\($0)" } ?? "NULL"
        let lonExpr = lonColumn.map { "a.\($0)" } ?? "NULL"
        let unlocatedExpr = """
            (\(latExpr) IS NULL OR \(lonExpr) IS NULL OR (
                ABS(\(latExpr)) < 0.0001 AND ABS(\(lonExpr)) < 0.0001
            ) OR ABS(\(latExpr)) > 90 OR ABS(\(lonExpr)) > 180)
            """
        let title = attrColumns.contains("ZTITLE") ? present("ZTITLE") : "0"
        let tzName = attrColumns.contains("ZTIMEZONENAME") ? present("ZTIMEZONENAME") : "0"
        let tzOff = attrColumns.contains("ZTIMEZONEOFFSET") ? "CASE WHEN r.ZTIMEZONEOFFSET IS NULL THEN 0 ELSE 1 END" : "0"
        let inferred = attrColumns.contains("ZINFERREDTIMEZONEOFFSET")
            ? "CASE WHEN r.ZINFERREDTIMEZONEOFFSET IS NULL THEN 0 ELSE 1 END" : "0"
        let reverseFlag = attrColumns.contains("ZREVERSELOCATIONDATAISVALID")
            ? "CASE WHEN r.ZREVERSELOCATIONDATAISVALID != 0 THEN 1 ELSE 0 END" : "0"
        let reverseBlob = attrColumns.contains("ZREVERSELOCATIONDATA")
            ? "CASE WHEN r.ZREVERSELOCATIONDATA IS NULL THEN 0 ELSE 1 END" : "0"
        let session = attrColumns.contains("ZIMPORTSESSIONID") ? present("ZIMPORTSESSIONID") : "0"
        let exif = attrColumns.contains("ZEXIFTIMESTAMPSTRING") ? present("ZEXIFTIMESTAMPSTRING") : "0"
        let filename = attrColumns.contains("ZORIGINALFILENAME") ? present("ZORIGINALFILENAME") : "0"
        let sql = """
            SELECT
              COUNT(*) AS photos,
              SUM(CASE WHEN \(unlocatedExpr) THEN 1 ELSE 0 END) AS unlocated,
              SUM(CASE WHEN a.\(dateColumn) < \(cutoff) THEN 1 ELSE 0 END) AS pre2010,
              SUM(CASE WHEN a.\(dateColumn) < \(cutoff) AND \(unlocatedExpr) THEN 1 ELSE 0 END) AS pre2010Unlocated,
              SUM(CASE WHEN a.\(dateColumn) < \(cutoff) AND \(unlocatedExpr) AND \(title) = 1 THEN 1 ELSE 0 END) AS titled,
              SUM(CASE WHEN a.\(dateColumn) < \(cutoff) AND \(unlocatedExpr) AND \(tzName) = 1 THEN 1 ELSE 0 END) AS tzName,
              SUM(CASE WHEN a.\(dateColumn) < \(cutoff) AND \(unlocatedExpr) AND \(tzOff) = 1 THEN 1 ELSE 0 END) AS tzOff,
              SUM(CASE WHEN a.\(dateColumn) < \(cutoff) AND \(unlocatedExpr) AND \(inferred) = 1 THEN 1 ELSE 0 END) AS inferred,
              SUM(\(reverseFlag)) AS reverseAny,
              SUM(CASE WHEN a.\(dateColumn) < \(cutoff) AND \(unlocatedExpr) AND (\(reverseFlag) = 1 OR \(reverseBlob) = 1) THEN 1 ELSE 0 END) AS reverseUnlocated,
              SUM(CASE WHEN a.\(dateColumn) < \(cutoff) AND \(unlocatedExpr) AND \(session) = 1 THEN 1 ELSE 0 END) AS sessions,
              SUM(CASE WHEN a.\(dateColumn) < \(cutoff) AND \(unlocatedExpr) AND \(exif) = 1 THEN 1 ELSE 0 END) AS exif,
              SUM(CASE WHEN a.\(dateColumn) < \(cutoff) AND \(unlocatedExpr) AND \(filename) = 1 THEN 1 ELSE 0 END) AS filename
            FROM \(assetTable) a
            LEFT JOIN \(attrTable) r ON \(join)
            """
        let row = try db.ints(sql)
        var coverage = Coverage.empty
        coverage.photos = row["photos"] ?? 0
        coverage.unlocated = row["unlocated"] ?? 0
        coverage.pre2010 = row["pre2010"] ?? 0
        coverage.pre2010Unlocated = row["pre2010Unlocated"] ?? 0
        coverage.withTitle = row["titled"] ?? 0
        coverage.withTimezoneName = row["tzName"] ?? 0
        coverage.withTimezoneOffset = row["tzOff"] ?? 0
        coverage.withInferredTimezone = row["inferred"] ?? 0
        coverage.withReverseLocation = row["reverseAny"] ?? 0
        coverage.reverseLocationOnUnlocatedPre2010 = row["reverseUnlocated"] ?? 0
        coverage.withImportSession = row["sessions"] ?? 0
        coverage.withExifTimestamp = row["exif"] ?? 0
        coverage.withOriginalFilename = row["filename"] ?? 0
        coverage.discoveredKeys = (assetColumns + attrColumns).filter {
            ["ZTITLE", "ZTIMEZONENAME", "ZTIMEZONEOFFSET", "ZINFERREDTIMEZONEOFFSET",
             "ZREVERSELOCATIONDATA", "ZREVERSELOCATIONDATAISVALID", "ZIMPORTSESSIONID",
             "ZEXIFTIMESTAMPSTRING", "ZORIGINALFILENAME"].contains($0)
        }.sorted()
        if attrColumns.contains("ZTITLE") {
            let titles = try db.strings("""
                SELECT r.ZTITLE FROM \(assetTable) a
                JOIN \(attrTable) r ON \(join)
                WHERE a.\(dateColumn) < \(cutoff)
                  AND \(unlocatedExpr)
                  AND \(title) = 1
                LIMIT 200
                """)
            coverage.placeLikeTitles = titles.filter { AlbumOutlinePatterns.looksPlaceLike($0) }.count
            coverage.sampleKinds = titles.prefix(8).map { AlbumOutlinePatterns.looksPlaceLike($0) ? "placeLikeTitle" : "title" }
        }
        if attrColumns.contains("ZTIMEZONENAME") {
            let zones = try db.labeledCounts("""
                SELECT r.ZTIMEZONENAME, COUNT(*) FROM \(assetTable) a
                JOIN \(attrTable) r ON \(join)
                WHERE a.\(dateColumn) < \(cutoff) AND \(unlocatedExpr)
                  AND r.ZTIMEZONENAME IS NOT NULL AND TRIM(r.ZTIMEZONENAME) != ''
                GROUP BY r.ZTIMEZONENAME
                ORDER BY COUNT(*) DESC
                LIMIT 8
                """)
            coverage.searchCategoryCounts = zones
        }
        if attrColumns.contains("ZREVERSELOCATIONDATA") {
            coverage.reverseLocationOnUnlocatedPre2010 = try db.int("""
                SELECT COUNT(*) FROM \(assetTable) a
                JOIN \(attrTable) r ON \(join)
                WHERE a.\(dateColumn) < \(cutoff) AND \(unlocatedExpr)
                  AND r.ZREVERSELOCATIONDATA IS NOT NULL
                """)
        }
        do {
            coverage.signals = try UnlocatedHistorySignals.measure(db: db)
        } catch {
            coverage.sampleKinds.append("signalsError")
        }
        return coverage
    }

    static func searchIndex(url: URL, photos: URL? = nil) throws -> Coverage {
        let db = try SQLiteReadOnly(url: url)
        defer { db.close() }
        let tables = try db.tables()
        guard tables.contains("groups"), tables.contains("assets") else {
            throw ProbeError.missingTable("groups/assets")
        }
        var coverage = Coverage.empty
        coverage.photos = try db.int("SELECT COUNT(*) FROM assets")
        let dateColumn = (try db.columns("assets")).contains("creationDate") ? "creationDate" : nil
        var pre2010Filter = "1"
        if let dateColumn {
            let maxDate = try db.int("SELECT MAX(\(dateColumn)) FROM assets")
            let picked: Int64
            if maxDate > 10_000_000_000 {
                picked = Int64(pre2010.timeIntervalSince1970 * 1_000)
            } else if maxDate > 1_400_000_000 {
                picked = Int64(pre2010.timeIntervalSince1970)
            } else {
                picked = Int64(pre2010.timeIntervalSince1970 - coreDataEpoch)
            }
            pre2010Filter = "a.\(dateColumn) < \(picked)"
            coverage.pre2010 = try db.int("SELECT COUNT(*) FROM assets a WHERE \(pre2010Filter)")
        }
        let categoryRows = try db.pairs("SELECT category, COUNT(*) FROM groups GROUP BY category")
        var names: [String: Int] = [:]
        for (category, count) in categoryRows {
            names[searchCategories[category] ?? "category-\(category)"] = count
        }
        coverage.searchCategoryCounts = names
        if tables.contains("ga") {
            func count(categories: [Int]) throws -> Int {
                let list = categories.map(String.init).joined(separator: ",")
                return try db.int("""
                    SELECT COUNT(DISTINCT a.rowid) FROM assets a
                    JOIN ga ON ga.assetid = a.rowid
                    JOIN groups g ON g.groupid = ga.groupid
                    WHERE \(pre2010Filter) AND g.category IN (\(list))
                    """)
            }
            coverage.searchPlaceOnUnlocatedPre2010 = try count(categories: [1, 5, 9, 12, 1700])
            coverage.searchDetectedTextOnUnlocatedPre2010 = try count(categories: [1203])
            coverage.searchCameraOnUnlocatedPre2010 = try count(categories: [2300])
        }
        coverage.pre2010Unlocated = coverage.pre2010
        coverage.discoveredKeys = tables.sorted()
        coverage.sampleKinds = names.keys.sorted().prefix(8).map { "search:\($0)" }
        _ = photos
        return coverage
    }

    static func safeValues(on object: NSObject) -> [String: String] {
        var result: [String: String] = [:]
        for key in privateAssetKeys {
            guard object.responds(to: NSSelectorFromString(key)) else { continue }
            guard let value = object.value(forKey: key) else { continue }
            if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result[key] = text
            } else if let number = value as? NSNumber {
                result[key] = number.stringValue
            }
        }
        return result
    }

    private static func photosSQLite(library: URL, fileManager: FileManager) -> Source {
        let source = library.appendingPathComponent("database/Photos.sqlite")
        do {
            let url = try readableDatabase(source, fileManager: fileManager)
            defer { cleanupSnapshot(url, original: source, fileManager: fileManager) }
            let coverage = try photosSQLite(url: url)
            return Source(status: "ok", detail: "read \(url.lastPathComponent)", coverage: coverage)
        } catch let error as ProbeError {
            return Source(status: error.status, detail: error.localizedDescription, coverage: nil)
        } catch {
            return Source(status: "error", detail: error.localizedDescription, coverage: nil)
        }
    }

    private static func searchIndex(library: URL, fileManager: FileManager) -> Source {
        let candidates = discoverSearchDatabases(library: library, fileManager: fileManager)
        let databaseFolder = library.appendingPathComponent("database")
        let searchFolder = databaseFolder.appendingPathComponent("search")
        let databaseListing = (try? fileManager.contentsOfDirectory(atPath: databaseFolder.path))?.sorted() ?? []
        let searchListing = (try? fileManager.contentsOfDirectory(atPath: searchFolder.path))?.sorted() ?? []
        var last: ProbeError = .missingFile(
            "search folder listing=\(searchListing.joined(separator: ",")) database listing=\(databaseListing.joined(separator: ","))"
        )
        for candidate in candidates {
            do {
                let url = try readableDatabase(candidate, fileManager: fileManager)
                defer { cleanupSnapshot(url, original: candidate, fileManager: fileManager) }
                let coverage = try searchIndex(url: url)
                return Source(status: "ok", detail: "read \(candidate.lastPathComponent)", coverage: coverage)
            } catch let error as ProbeError {
                last = error
            } catch {
                return Source(status: "error", detail: error.localizedDescription, coverage: nil)
            }
        }
        let sqliteOnly = databaseListing.filter { $0.hasSuffix(".sqlite") || $0 == "search" }
        return Source(
            status: last.status,
            detail: "\(last.localizedDescription); database=\(sqliteOnly.joined(separator: ",")) search=\(searchListing.joined(separator: ","))",
            coverage: nil
        )
    }

    static func readableDatabase(_ url: URL, fileManager: FileManager) throws -> URL {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if fileManager.isReadableFile(atPath: url.path) {
            return url
        }
        do {
            let handle = try SQLiteReadOnly(url: url)
            handle.close()
            return url
        } catch {
            let dest = fileManager.temporaryDirectory.appendingPathComponent("photocurator-\(url.lastPathComponent)")
            try? fileManager.removeItem(at: dest)
            do {
                try fileManager.copyItem(at: url, to: dest)
                for suffix in ["-wal", "-shm"] {
                    let side = URL(fileURLWithPath: url.path + suffix)
                    let sideDest = URL(fileURLWithPath: dest.path + suffix)
                    try? fileManager.removeItem(at: sideDest)
                    try? fileManager.copyItem(at: side, to: sideDest)
                }
                return dest
            } catch {
                if !exists { throw ProbeError.missingFile(url.path) }
                throw ProbeError.unauthorized(url.path)
            }
        }
    }

    static func discoverSearchDatabases(library: URL, fileManager: FileManager) -> [URL] {
        let folder = library.appendingPathComponent("database/search")
        let named = ["leo.sqlite", "psi.sqlite"].map { folder.appendingPathComponent($0) }
        let extras = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
            .map { $0.filter { $0.pathExtension == "sqlite" } } ?? []
        var seen = Set<String>()
        return (named + extras).filter { url in
            seen.insert(url.path).inserted
        }
    }

    private static func cleanupSnapshot(_ url: URL, original: URL, fileManager: FileManager) {
        guard url != original else { return }
        try? fileManager.removeItem(at: url)
        try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    }

    private static func logProgress(_ message: String) {
        fputs("photos-internals: \(message)\n", stderr)
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("CascadeProjects/icloud_photos_downloader/Artifacts/photos-internals-probe.log")
        let line = "\(Int(Date().timeIntervalSince1970)) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: log) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: log, atomically: true, encoding: .utf8)
        }
    }

    /// Run work off the main thread while pumping TCC/PhotoKit callbacks.
    private static func pumpWhile<T>(timeout: TimeInterval = 180, _ work: @escaping () -> T) -> T? {
        if !Thread.isMainThread { return work() }
        let box = ProbeBox<T>()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = work()
            group.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while group.wait(timeout: .now() + 0.05) == .timedOut {
            if Date() > deadline { return box.value }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return box.value
    }

    private static func nonempty(_ value: String?) -> Bool {
        !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private static func appendKind(_ kind: String, to kinds: inout [String]) {
        if kinds.count < 12 { kinds.append(kind) }
    }

    enum ProbeError: LocalizedError {
        case unauthorized(String)
        case missingFile(String)
        case missingTable(String)
        case missingColumn(String)
        case sqlite(String)

        var status: String {
            switch self {
            case .unauthorized: return "unauthorized"
            case .missingFile, .missingTable, .missingColumn: return "missing"
            case .sqlite: return "error"
            }
        }

        var errorDescription: String? {
            switch self {
            case .unauthorized(let path): return "authorization denied for \(path)"
            case .missingFile(let path): return "missing \(path)"
            case .missingTable(let name): return "missing table \(name)"
            case .missingColumn(let name): return "missing column \(name)"
            case .sqlite(let message): return message
            }
        }
    }
}

extension PhotosInternalsProbe.Coverage {
    static let empty = PhotosInternalsProbe.Coverage(
        photos: 0, unlocated: 0, pre2010: 0, pre2010Unlocated: 0, withTitle: 0,
        withTimezoneName: 0, withTimezoneOffset: 0, withInferredTimezone: 0,
        withReverseLocation: 0, reverseLocationOnUnlocatedPre2010: 0,
        withImportSession: 0, withExifTimestamp: 0, withOriginalFilename: 0,
        placeLikeTitles: 0, searchPlaceOnUnlocatedPre2010: 0,
        searchDetectedTextOnUnlocatedPre2010: 0, searchCameraOnUnlocatedPre2010: 0,
        searchCategoryCounts: [:], discoveredKeys: [], sampleKinds: [], signals: nil
    )
}

private final class ProbeBox<T>: @unchecked Sendable {
    var value: T?
}

/// Minimal read-only sqlite helper for internals probes. Opens URI files as immutable.
final class SQLiteReadOnly {
    private var db: OpaquePointer?

    init(url: URL) throws {
        let uri = "file:\(url.path)?mode=ro"
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw PhotosInternalsProbe.ProbeError.unauthorized(url.path)
        }
        db = handle
        sqlite3_busy_timeout(handle, 3_000)
    }

    func close() {
        sqlite3_close(db)
        db = nil
    }

    func tables() throws -> [String] {
        try strings("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
    }

    func columns(_ table: String) throws -> [String] {
        try pragmaColumns(table)
    }

    func firstTable(in names: [String]) throws -> String {
        let have = Set(try tables())
        if let match = names.first(where: { have.contains($0) }) { return match }
        throw PhotosInternalsProbe.ProbeError.missingTable(names.joined(separator: "/"))
    }

    func firstColumn(in columns: [String], names: [String]) throws -> String {
        if let match = names.first(where: { columns.contains($0) }) { return match }
        throw PhotosInternalsProbe.ProbeError.missingColumn(names.joined(separator: "/"))
    }

    func int(_ sql: String) throws -> Int {
        try ints(sql).values.first ?? 0
    }

    func ints(_ sql: String) throws -> [String: Int] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return [:] }
        var result: [String: Int] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, index))
            result[name] = Int(sqlite3_column_int64(statement, index))
        }
        return result
    }

    func strings(_ sql: String) throws -> [String] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                values.append(String(cString: text))
            }
        }
        return values
    }

    func labeledCounts(_ sql: String) throws -> [String: Int] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var values: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let name = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            values[name] = Int(sqlite3_column_int64(statement, 1))
        }
        return values
    }

    func pairs(_ sql: String) throws -> [(Int, Int)] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var values: [(Int, Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append((Int(sqlite3_column_int64(statement, 0)), Int(sqlite3_column_int64(statement, 1))))
        }
        return values
    }

    private func pragmaColumns(_ table: String) throws -> [String] {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 1) {
                names.append(String(cString: text))
            }
        }
        return names
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw PhotosInternalsProbe.ProbeError.sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? sql)
        }
        return statement
    }
}
