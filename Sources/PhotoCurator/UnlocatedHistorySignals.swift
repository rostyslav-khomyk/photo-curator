import Foundation
import SQLite3

/// Read-only measurements for clustering unlocated Journeys from time, people,
/// cameras and shooting density. Does not invent coordinates or write Stories.
struct UnlocatedHistorySignals: Codable, Equatable {
    var withAnyFace: Int
    var withNamedFace: Int
    var withUnnamedCluster: Int
    var distinctNamedPeople: Int
    var distinctUnnamedClusters: Int
    var namedPeopleCounts: [String: Int]
    var daysWithPhotos: Int
    var busyDays8Plus: Int
    var quietDays1or2: Int
    var maxPhotosInADay: Int
    var medianPhotosPerDay: Int
    var withAddedDate: Int
    var addedDateDiffersFromCapture: Int
    var importDumpDays: Int
    var filenameFamilies: [String: Int]
    var longestFilenameRun: Int
    var filenameRunsOf10Plus: Int
    var withCameraMake: Int
    var cameraMakeCounts: [String: Int]
    var albumKindPhotos: [String: Int]
    var busyDayShareByKind: [String: Int]
    var discoveredFaceColumns: [String]
    var discoveredCameraColumns: [String]

    static let empty = UnlocatedHistorySignals(
        withAnyFace: 0, withNamedFace: 0, withUnnamedCluster: 0,
        distinctNamedPeople: 0, distinctUnnamedClusters: 0, namedPeopleCounts: [:],
        daysWithPhotos: 0, busyDays8Plus: 0, quietDays1or2: 0, maxPhotosInADay: 0,
        medianPhotosPerDay: 0, withAddedDate: 0, addedDateDiffersFromCapture: 0,
        importDumpDays: 0, filenameFamilies: [:], longestFilenameRun: 0,
        filenameRunsOf10Plus: 0, withCameraMake: 0, cameraMakeCounts: [:],
        albumKindPhotos: [:], busyDayShareByKind: [:],
        discoveredFaceColumns: [], discoveredCameraColumns: []
    )

    static func measure(db: SQLiteReadOnly, review: OwnerAlbumStoryReview = .september2026OwnerPass) throws -> UnlocatedHistorySignals {
        let tables = try db.tables()
        let assetTable = try db.firstTable(in: ["ZASSET", "ZGENERICASSET"])
        let attrTable = try? db.firstTable(in: ["ZADDITIONALASSETATTRIBUTES"])
        let assetColumns = try db.columns(assetTable)
        let attrColumns = (try? attrTable.map { try db.columns($0) }) ?? []
        let dateColumn = try db.firstColumn(in: assetColumns, names: ["ZDATECREATED"])
        let cutoff = PhotosInternalsProbe.pre2010.timeIntervalSince1970 - PhotosInternalsProbe.coreDataEpoch
        let latExpr = assetColumns.contains("ZLATITUDE") ? "a.ZLATITUDE" : "NULL"
        let lonExpr = assetColumns.contains("ZLONGITUDE") ? "a.ZLONGITUDE" : "NULL"
        let unlocated = """
            (\(latExpr) IS NULL OR \(lonExpr) IS NULL OR (
                ABS(\(latExpr)) < 0.0001 AND ABS(\(lonExpr)) < 0.0001
            ) OR ABS(\(latExpr)) > 90 OR ABS(\(lonExpr)) > 180)
            """
        let scope = "a.\(dateColumn) < \(cutoff) AND \(unlocated)"
        var signals = UnlocatedHistorySignals.empty

        fputs("unlocated-signals: faces\n", stderr)
        try measureFaces(db: db, tables: tables, assetTable: assetTable, scope: scope, signals: &signals)
        fputs("unlocated-signals: density\n", stderr)
        try measureDensityAndImports(db: db, assetTable: assetTable, assetColumns: assetColumns,
                                     dateColumn: dateColumn, scope: scope, cutoff: cutoff, signals: &signals)
        fputs("unlocated-signals: cameras\n", stderr)
        try measureCamerasAndFilenames(db: db, assetTable: assetTable, attrTable: attrTable,
                                       assetColumns: assetColumns, attrColumns: attrColumns,
                                       scope: scope, signals: &signals)
        fputs("unlocated-signals: albums\n", stderr)
        try measureAlbumOverlap(db: db, tables: tables, assetTable: assetTable, dateColumn: dateColumn,
                                scope: scope, review: review, signals: &signals)
        fputs("unlocated-signals: done\n", stderr)
        return signals
    }

    private static func measureFaces(db: SQLiteReadOnly, tables: [String], assetTable: String,
                                     scope: String, signals: inout UnlocatedHistorySignals) throws {
        guard tables.contains("ZDETECTEDFACE"), tables.contains("ZPERSON") else { return }
        let faceColumns = try db.columns("ZDETECTEDFACE")
        let personColumns = try db.columns("ZPERSON")
        let assetFK = ["ZASSETFORFACE", "ZASSET"].first { faceColumns.contains($0) }
        let personFK = ["ZPERSONFORFACE", "ZPERSON"].first { faceColumns.contains($0) }
        let nameColumn = ["ZFULLNAME", "ZDISPLAYNAME"].first { personColumns.contains($0) }
        let clusterColumn = ["ZFACEGROUP", "ZCLUSTERSEQUENCENUMBER"].first { faceColumns.contains($0) }
        signals.discoveredFaceColumns = [assetFK, personFK, nameColumn, clusterColumn].compactMap { $0 }
        guard let assetFK, let personFK else { return }
        signals.withAnyFace = try db.int("""
            SELECT COUNT(DISTINCT a.Z_PK) FROM \(assetTable) a
            JOIN ZDETECTEDFACE f ON f.\(assetFK) = a.Z_PK
            WHERE \(scope)
            """)
        if let nameColumn {
            signals.withNamedFace = try db.int("""
                SELECT COUNT(DISTINCT a.Z_PK) FROM \(assetTable) a
                JOIN ZDETECTEDFACE f ON f.\(assetFK) = a.Z_PK
                JOIN ZPERSON p ON p.Z_PK = f.\(personFK)
                WHERE \(scope) AND p.\(nameColumn) IS NOT NULL AND TRIM(p.\(nameColumn)) != ''
                """)
            signals.distinctNamedPeople = try db.int("""
                SELECT COUNT(DISTINCT p.Z_PK) FROM \(assetTable) a
                JOIN ZDETECTEDFACE f ON f.\(assetFK) = a.Z_PK
                JOIN ZPERSON p ON p.Z_PK = f.\(personFK)
                WHERE \(scope) AND p.\(nameColumn) IS NOT NULL AND TRIM(p.\(nameColumn)) != ''
                """)
            signals.namedPeopleCounts = try db.labeledCounts("""
                SELECT p.\(nameColumn), COUNT(DISTINCT a.Z_PK) FROM \(assetTable) a
                JOIN ZDETECTEDFACE f ON f.\(assetFK) = a.Z_PK
                JOIN ZPERSON p ON p.Z_PK = f.\(personFK)
                WHERE \(scope) AND p.\(nameColumn) IS NOT NULL AND TRIM(p.\(nameColumn)) != ''
                GROUP BY p.\(nameColumn)
                ORDER BY COUNT(DISTINCT a.Z_PK) DESC
                LIMIT 12
                """)
        }
        if let clusterColumn {
            signals.withUnnamedCluster = try db.int("""
                SELECT COUNT(DISTINCT a.Z_PK) FROM \(assetTable) a
                JOIN ZDETECTEDFACE f ON f.\(assetFK) = a.Z_PK
                LEFT JOIN ZPERSON p ON p.Z_PK = f.\(personFK)
                WHERE \(scope) AND f.\(clusterColumn) IS NOT NULL
                  AND (f.\(personFK) IS NULL OR p.Z_PK IS NULL
                       \(nameColumn.map { "OR p.\($0) IS NULL OR TRIM(p.\($0)) = ''" } ?? ""))
                """)
            signals.distinctUnnamedClusters = try db.int("""
                SELECT COUNT(DISTINCT f.\(clusterColumn)) FROM \(assetTable) a
                JOIN ZDETECTEDFACE f ON f.\(assetFK) = a.Z_PK
                LEFT JOIN ZPERSON p ON p.Z_PK = f.\(personFK)
                WHERE \(scope) AND f.\(clusterColumn) IS NOT NULL
                  AND (f.\(personFK) IS NULL OR p.Z_PK IS NULL
                       \(nameColumn.map { "OR p.\($0) IS NULL OR TRIM(p.\($0)) = ''" } ?? ""))
                """)
        }
    }

    private static func measureDensityAndImports(db: SQLiteReadOnly, assetTable: String,
                                                 assetColumns: [String], dateColumn: String,
                                                 scope: String, cutoff: Double,
                                                 signals: inout UnlocatedHistorySignals) throws {
        let dayCounts = try db.intsList("""
            SELECT COUNT(*) FROM \(assetTable) a
            WHERE \(scope)
            GROUP BY CAST((a.\(dateColumn) + \(Int(PhotosInternalsProbe.coreDataEpoch))) / 86400 AS INT)
            """)
        signals.daysWithPhotos = dayCounts.count
        signals.busyDays8Plus = dayCounts.filter { $0 >= 8 }.count
        signals.quietDays1or2 = dayCounts.filter { $0 <= 2 }.count
        signals.maxPhotosInADay = dayCounts.max() ?? 0
        signals.medianPhotosPerDay = median(dayCounts)
        guard assetColumns.contains("ZADDEDDATE") else { return }
        signals.withAddedDate = try db.int("""
            SELECT COUNT(*) FROM \(assetTable) a
            WHERE \(scope) AND a.ZADDEDDATE IS NOT NULL
            """)
        signals.addedDateDiffersFromCapture = try db.int("""
            SELECT COUNT(*) FROM \(assetTable) a
            WHERE \(scope) AND a.ZADDEDDATE IS NOT NULL
              AND ABS(a.ZADDEDDATE - a.\(dateColumn)) >= 1
            """)
        signals.importDumpDays = try db.int("""
            SELECT COUNT(*) FROM (
                SELECT 1 FROM \(assetTable) a
                WHERE \(scope) AND a.ZADDEDDATE IS NOT NULL
                GROUP BY CAST((a.ZADDEDDATE + \(Int(PhotosInternalsProbe.coreDataEpoch))) / 86400 AS INT)
                HAVING MAX(a.\(dateColumn)) - MIN(a.\(dateColumn)) >= \(3 * 86_400)
            )
            """)
        _ = cutoff
    }

    private static func measureCamerasAndFilenames(db: SQLiteReadOnly, assetTable: String,
                                                   attrTable: String?, assetColumns: [String],
                                                   attrColumns: [String], scope: String,
                                                   signals: inout UnlocatedHistorySignals) throws {
        let makeColumn = ["ZCAMERAMAKE", "ZMAKE", "ZCAMERAMODELMAKE"].first { attrColumns.contains($0) || assetColumns.contains($0) }
        let modelColumn = ["ZCAMERAMODEL", "ZMODEL"].first { attrColumns.contains($0) || assetColumns.contains($0) }
        signals.discoveredCameraColumns = [makeColumn, modelColumn].compactMap { $0 }
        if let makeColumn {
            let table = attrColumns.contains(makeColumn) ? "r" : "a"
            let join = attrTable.map { "LEFT JOIN \($0) r ON a.Z_PK = r.ZASSET" } ?? ""
            signals.withCameraMake = try db.int("""
                SELECT COUNT(*) FROM \(assetTable) a \(join)
                WHERE \(scope) AND \(table).\(makeColumn) IS NOT NULL
                  AND TRIM(CAST(\(table).\(makeColumn) AS TEXT)) != ''
                """)
            signals.cameraMakeCounts = try db.labeledCounts("""
                SELECT \(table).\(makeColumn), COUNT(*) FROM \(assetTable) a \(join)
                WHERE \(scope) AND \(table).\(makeColumn) IS NOT NULL
                  AND TRIM(CAST(\(table).\(makeColumn) AS TEXT)) != ''
                GROUP BY \(table).\(makeColumn)
                ORDER BY COUNT(*) DESC
                LIMIT 8
                """)
            _ = modelColumn
        }
        let rows: [(String, Double)]
        if attrColumns.contains("ZORIGINALFILENAME"), let attrTable {
            rows = try db.stringPairs("""
                SELECT r.ZORIGINALFILENAME, a.ZDATECREATED FROM \(assetTable) a
                JOIN \(attrTable) r ON a.Z_PK = r.ZASSET
                WHERE \(scope) AND r.ZORIGINALFILENAME IS NOT NULL
                """)
        } else if assetColumns.contains("ZFILENAME") {
            rows = try db.stringPairs("""
                SELECT a.ZFILENAME, a.ZDATECREATED FROM \(assetTable) a
                WHERE \(scope) AND a.ZFILENAME IS NOT NULL
                """)
        } else {
            return
        }
        var families: [String: Int] = [:]
        var parsed: [(family: String, number: Int, day: Int)] = []
        for (name, created) in rows {
            let family = filenameFamily(name)
            families[family, default: 0] += 1
            if let number = filenameNumber(name) {
                let day = Int((created + PhotosInternalsProbe.coreDataEpoch) / 86_400)
                parsed.append((family, number, day))
            }
        }
        signals.filenameFamilies = families
        let runs = filenameRuns(parsed)
        signals.longestFilenameRun = runs.max() ?? 0
        signals.filenameRunsOf10Plus = runs.filter { $0 >= 10 }.count
    }

    private static func measureAlbumOverlap(db: SQLiteReadOnly, tables: [String], assetTable: String,
                                            dateColumn: String, scope: String,
                                            review: OwnerAlbumStoryReview,
                                            signals: inout UnlocatedHistorySignals) throws {
        guard let albumTable = try? db.firstTable(in: ["ZGENERICALBUM", "ZALBUM"]) else { return }
        let joinTable = try albumAssetJoinTable(db: db, tables: tables)
        guard let joinTable else { return }
        let joinColumns = try db.columns(joinTable)
        guard let albumFK = joinColumns.first(where: { $0.contains("ALBUM") && !$0.contains("FOK") }),
              let assetFK = joinColumns.first(where: {
                  $0.contains("ASSET") && !$0.contains("ALBUM") && !$0.contains("FOK")
              }) else { return }
        let albumColumns = try db.columns(albumTable)
        guard albumColumns.contains("ZTITLE") else { return }
        let joinRows = try db.int("SELECT COUNT(*) FROM \(joinTable)")
        guard joinRows <= 400_000 else {
            fputs("unlocated-signals: albums-skip joinRows=\(joinRows)\n", stderr)
            return
        }
        let rows = try db.stringIntPairs("""
            SELECT b.ZTITLE, COUNT(DISTINCT a.Z_PK) FROM \(assetTable) a
            JOIN \(joinTable) j ON j.\(assetFK) = a.Z_PK
            JOIN \(albumTable) b ON b.Z_PK = j.\(albumFK)
            WHERE \(scope) AND b.ZTITLE IS NOT NULL
            GROUP BY b.ZTITLE
            """)
        var kindPhotos: [String: Int] = [:]
        for (title, count) in rows {
            let kind = review.kind(forAlbumTitle: title)?.rawValue ?? "unlabeled"
            kindPhotos[kind, default: 0] += count
        }
        signals.albumKindPhotos = kindPhotos
        let epoch = Int(PhotosInternalsProbe.coreDataEpoch)
        let rowsByBusyDay = try db.stringIntPairs("""
            SELECT b.ZTITLE, COUNT(DISTINCT day) FROM (
                SELECT CAST((d.\(dateColumn) + \(epoch)) / 86400 AS INT) AS day
                FROM \(assetTable) d
                WHERE \(scope.replacingOccurrences(of: "a.", with: "d."))
                GROUP BY day
                HAVING COUNT(*) >= 8
            ) busy
            JOIN \(assetTable) a ON CAST((a.\(dateColumn) + \(epoch)) / 86400 AS INT) = busy.day
            JOIN \(joinTable) j ON j.\(assetFK) = a.Z_PK
            JOIN \(albumTable) b ON b.Z_PK = j.\(albumFK)
            WHERE \(scope) AND b.ZTITLE IS NOT NULL
            GROUP BY b.ZTITLE
            """)
        var busyShare: [String: Int] = [:]
        for (title, days) in rowsByBusyDay {
            let kind = review.kind(forAlbumTitle: title)?.rawValue ?? "unlabeled"
            busyShare[kind, default: 0] += days
        }
        signals.busyDayShareByKind = busyShare
    }

    private static func albumAssetJoinTable(db: SQLiteReadOnly, tables: [String]) throws -> String? {
        let candidates = tables.filter { $0.range(of: #"^Z_\d+ASSETS$"#, options: .regularExpression) != nil }
        var best: (name: String, rows: Int)?
        for name in candidates {
            let columns = try db.columns(name)
            guard columns.contains(where: { $0.contains("ALBUM") && !$0.contains("FOK") }),
                  columns.contains(where: { $0.contains("ASSET") && !$0.contains("ALBUM") && !$0.contains("FOK") })
            else { continue }
            let rows = try db.int("SELECT COUNT(*) FROM \(name)")
            if best == nil || rows > best!.rows {
                best = (name, rows)
            }
        }
        return best?.name
    }

    static func filenameFamily(_ name: String) -> String {
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent.uppercased()
        if stem.hasPrefix("DSC") { return "DSC" }
        if stem.hasPrefix("IMG") { return "IMG" }
        if stem.hasPrefix("SCAN") || stem.contains("SCAN") { return "Scan" }
        if stem.hasPrefix("P") && stem.dropFirst().allSatisfy(\.isNumber) { return "P-numeric" }
        return "other"
    }

    static func filenameNumber(_ name: String) -> Int? {
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let digits = stem.reversed().prefix { $0.isNumber }
        guard !digits.isEmpty, let value = Int(String(digits.reversed())) else { return nil }
        return value
    }

    static func filenameRuns(_ rows: [(family: String, number: Int, day: Int)]) -> [Int] {
        let ordered = rows.sorted {
            if $0.family != $1.family { return $0.family < $1.family }
            if $0.number != $1.number { return $0.number < $1.number }
            return $0.day < $1.day
        }
        var runs: [Int] = []
        var current = 0
        var last: (family: String, number: Int, day: Int)?
        for row in ordered {
            if let last, last.family == row.family,
               row.number >= last.number, row.number - last.number <= 2,
               abs(row.day - last.day) <= 2 {
                current += 1
            } else {
                if current > 0 { runs.append(current) }
                current = 1
            }
            last = row
        }
        if current > 0 { runs.append(current) }
        return runs
    }

    private static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

extension SQLiteReadOnly {
    func intsList(_ sql: String) throws -> [Int] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var values: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(Int(sqlite3_column_int64(statement, 0)))
        }
        return values
    }

    func stringPairs(_ sql: String) throws -> [(String, Double)] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var values: [(String, Double)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let name = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            values.append((name, sqlite3_column_double(statement, 1)))
        }
        return values
    }

    func stringIntPairs(_ sql: String) throws -> [(String, Int)] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var values: [(String, Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let name = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            values.append((name, Int(sqlite3_column_int64(statement, 1))))
        }
        return values
    }
}
