import CryptoKit
import Foundation
import SQLite3

enum NativeGoogleSyncError: LocalizedError, Equatable {
    case message(String)
    case uncertain(String)
    case aborted

    var errorDescription: String? {
        switch self {
        case .message(let message), .uncertain(let message): message
        case .aborted: "Upload aborted. Completed Google changes were kept; remaining work was stopped."
        }
    }
}

private final class GoogleUploadLedger {
    enum Upload { case missing, uncertain, known(String) }
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw failure() }
        try execute("CREATE TABLE IF NOT EXISTS uploads (account TEXT, digest TEXT, media_id TEXT, PRIMARY KEY (account, digest))")
        try execute("CREATE TABLE IF NOT EXISTS album_creations (account TEXT, title TEXT, album_id TEXT, PRIMARY KEY (account, title))")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    deinit { sqlite3_close(db) }

    func upload(account: String, digest: String) throws -> Upload {
        let statement = try prepare("SELECT media_id FROM uploads WHERE account=? AND digest=?")
        defer { sqlite3_finalize(statement) }
        bind(account, to: 1, in: statement); bind(digest, to: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return .missing }
        guard let value = sqlite3_column_text(statement, 0) else { return .uncertain }
        return .known(String(cString: value))
    }

    func uncertainDigests(account: String) throws -> Set<String> {
        let statement = try prepare("SELECT digest FROM uploads WHERE account=? AND media_id IS NULL")
        defer { sqlite3_finalize(statement) }
        bind(account, to: 1, in: statement)
        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            result.insert(String(cString: sqlite3_column_text(statement, 0)))
        }
        return result
    }

    func recordUpload(account: String, digest: String, mediaID: String?) throws {
        let statement = try prepare("INSERT OR REPLACE INTO uploads VALUES (?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(account, to: 1, in: statement); bind(digest, to: 2, in: statement)
        if let mediaID { bind(mediaID, to: 3, in: statement) } else { sqlite3_bind_null(statement, 3) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func discardPendingUpload(account: String, digest: String) throws {
        try mutate("DELETE FROM uploads WHERE account=? AND digest=? AND media_id IS NULL", account, digest)
    }

    func beginAlbum(account: String, title: String) throws {
        let statement = try prepare("INSERT INTO album_creations VALUES (?, ?, NULL)")
        defer { sqlite3_finalize(statement) }
        bind(account, to: 1, in: statement); bind(title, to: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NativeGoogleSyncError.uncertain("This album was previously created or its creation response was lost. Refresh the Google album browser and select it explicitly; no duplicate was created.")
        }
    }

    func finishAlbum(account: String, title: String, id: String) throws {
        let statement = try prepare("UPDATE album_creations SET album_id=? WHERE account=? AND title=?")
        defer { sqlite3_finalize(statement) }
        bind(id, to: 1, in: statement); bind(account, to: 2, in: statement); bind(title, to: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func discardPendingAlbum(account: String, title: String) throws {
        try mutate("DELETE FROM album_creations WHERE account=? AND title=? AND album_id IS NULL", account, title)
    }

    private func mutate(_ sql: String, _ first: String, _ second: String) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(first, to: 1, in: statement); bind(second, to: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func failure() -> Error {
        NativeGoogleSyncError.message(db.map { String(cString: sqlite3_errmsg($0)) } ?? "The Google upload ledger could not be opened.")
    }
}

actor NativeGoogleSync {
    struct DestinationChoice: Sendable { let id: String?; let title: String? }
    struct Snapshot: Sendable {
        let running: Bool
        let error: String?
        let progress: TransferProgress?
        let succeeded: Bool
    }

    private struct FileState: Sendable { let size: Int64; let modified: Date }
    private struct Destination: Sendable {
        let key: String
        let title: String
        var albumID: String?
        let oldIDs: Set<String>
        let existingCount: Int
        var paths: Set<String>
    }
    private struct Plan: Sendable {
        let token: String
        let account: String
        let created: Date
        let files: [String: FileState]
        let hashes: [String: String]
        var destinations: [String: Destination]
        let uncertainPaths: Set<String>
    }

    private let client: GooglePhotosServicing
    private let ledger: GoogleUploadLedger
    private var prepared: Plan?
    private var task: Task<Void, Never>?
    private var abortRequested = false
    private var currentProgress: TransferProgress?
    private var currentError: String?
    private var succeeded = false

    init(client: GooglePhotosServicing, ledgerURL: URL) throws {
        self.client = client
        ledger = try GoogleUploadLedger(url: ledgerURL)
    }

    func prepare(items: [ExportedPhotosItem], choices: [String: DestinationChoice]) async throws -> SyncReview {
        guard task == nil, !items.isEmpty else { throw NativeGoogleSyncError.message("Select photos to sync first.") }
        let albums = try await client.listAlbums()
        let albumsByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        let account = Self.digest(Data(try await client.accountIdentifier().utf8))
        var files: [String: FileState] = [:]
        var hashes: [String: String] = [:]
        var destinations: [String: Destination] = [:]
        for item in items {
            let url = URL(fileURLWithPath: item.path)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
                throw NativeGoogleSyncError.message("The exported photo is unavailable: \(url.lastPathComponent)")
            }
            files[item.path] = FileState(size: Int64(size), modified: values.contentModificationDate ?? .distantPast)
            hashes[item.path] = try await Self.fileDigest(url)
            let choice = choices[item.album] ?? DestinationChoice(id: nil, title: item.album)
            let album: GoogleAlbum?
            let title: String
            if let id = choice.id {
                guard let found = albumsByID[id] else {
                    throw NativeGoogleSyncError.message("The chosen Google album is no longer accessible. Choose it again.")
                }
                album = found; title = found.title
            } else {
                title = choice.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !title.isEmpty else { throw NativeGoogleSyncError.message("Enter a destination album name.") }
                let matches = albums.filter { $0.title == title }
                guard matches.count < 2 else {
                    throw NativeGoogleSyncError.message("Several Google albums are named '\(title)'. Choose one from the album browser.")
                }
                album = matches.first
            }
            let key = album?.id ?? "new:\(title)"
            if destinations[key] == nil {
                let oldIDs: Set<String>
                if let album { oldIDs = try await client.albumMediaIDs(album.id) }
                else { oldIDs = [] }
                destinations[key] = Destination(key: key, title: title, albumID: album?.id, oldIDs: oldIDs,
                                                existingCount: max(oldIDs.count, album?.count ?? 0), paths: [])
            }
            destinations[key]?.paths.insert(item.path)
        }
        let unresolved = try ledger.uncertainDigests(account: account)
        let uncertainPaths = Set(hashes.compactMap { unresolved.contains($0.value) ? $0.key : nil })
        let token = UUID().uuidString
        prepared = Plan(token: token, account: account, created: Date(), files: files, hashes: hashes,
                        destinations: destinations, uncertainPaths: uncertainPaths)
        return SyncReview(token: token, destinations: destinations.values.sorted { $0.title < $1.title }.map {
            SyncReview.Destination(id: $0.key, title: $0.title, isNew: $0.albumID == nil,
                                   existingCount: $0.existingCount, managedCount: $0.oldIDs.count,
                                   selectedCount: $0.paths.count)
        }, fileCount: files.count, totalBytes: files.values.reduce(0) { $0 + $1.size },
                          unresolvedFiles: uncertainPaths.sorted())
    }

    func start(token: String, replace: Bool, skipUnresolved: Bool) throws {
        guard task == nil, let plan = prepared, plan.token == token else {
            throw NativeGoogleSyncError.message("Review your Google destination before syncing.")
        }
        if skipUnresolved && replace {
            throw NativeGoogleSyncError.message("Use Add photos when leaving unresolved items out.")
        }
        prepared = nil; abortRequested = false; currentError = nil; succeeded = false
        currentProgress = progress(plan, phase: "preparing", message: "Preparing Google Photos sync")
        task = Task { await run(plan: plan, replace: replace, skipUnresolved: skipUnresolved) }
    }

    func abort() { abortRequested = true }

    func snapshot() -> Snapshot {
        Snapshot(running: task != nil, error: currentError, progress: currentProgress, succeeded: succeeded)
    }

    func clearAlbum(_ id: String) async throws -> Int {
        guard task == nil, try await client.listAlbums().contains(where: { $0.id == id }) else {
            throw NativeGoogleSyncError.message("The selected Google album is no longer accessible to Photo Curator.")
        }
        let ids = try await client.albumMediaIDs(id)
        guard !ids.isEmpty else { return 0 }
        try await client.changeAlbum(id, mediaIDs: ids, removing: true)
        guard ids.isDisjoint(with: try await client.albumMediaIDs(id)) else {
            throw NativeGoogleSyncError.message("Google did not confirm that the album was cleared. Check it before retrying.")
        }
        return ids.count
    }

    private func run(plan original: Plan, replace: Bool, skipUnresolved: Bool) async {
        var plan = original
        do {
            guard Date().timeIntervalSince(plan.created) < 1_800 else {
                throw NativeGoogleSyncError.message("The album review expired. Review the destination again.")
            }
            try checkAbort()
            for destination in plan.destinations.values where destination.albumID != nil && replace {
                guard try await client.albumMediaIDs(destination.albumID!) == destination.oldIDs else {
                    throw NativeGoogleSyncError.message("The Google album changed since review. Review it again; nothing was removed.")
                }
            }
            var known: [String: String] = [:]
            var unique: [String: String] = [:]
            for (path, digest) in plan.hashes {
                try checkAbort()
                if plan.uncertainPaths.contains(path) {
                    if skipUnresolved { continue }
                    throw NativeGoogleSyncError.uncertain("A previous upload has an uncertain Google response. Check Google Photos before retrying this photo.")
                }
                guard try Self.unchanged(path: path, expected: plan.files[path]!) else {
                    throw NativeGoogleSyncError.message("An exported photo changed since review. Prepare the selection again.")
                }
                unique[digest] = path
                if case .known(let id) = try ledger.upload(account: plan.account, digest: digest) { known[digest] = id }
            }
            if !known.isEmpty {
                let existing = try await client.existingMediaIDs(Set(known.values))
                known = known.filter { existing.contains($0.value) }
            }
            let uncertainPaths = plan.uncertainPaths
            for key in plan.destinations.keys {
                plan.destinations[key]?.paths.subtract(uncertainPaths)
            }
            plan.destinations = plan.destinations.filter { !$0.value.paths.isEmpty }
            for key in plan.destinations.keys.sorted() where plan.destinations[key]?.albumID == nil {
                var destination = plan.destinations[key]!
                guard !(try await client.listAlbums()).contains(where: { $0.title == destination.title }) else {
                    throw NativeGoogleSyncError.message("A destination album was created since review. Review it again to avoid a duplicate.")
                }
                try ledger.beginAlbum(account: plan.account, title: destination.title)
                do {
                    destination.albumID = try await client.createAlbum(title: destination.title)
                } catch {
                    if Self.definitivelyRejected(error) {
                        try? ledger.discardPendingAlbum(account: plan.account, title: destination.title)
                    }
                    throw error
                }
                try ledger.finishAlbum(account: plan.account, title: destination.title, id: destination.albumID!)
                plan.destinations[key] = destination
            }
            let pending = unique.filter { known[$0.key] == nil }
            let totalBytes = pending.values.reduce(Int64(0)) { $0 + (plan.files[$1]?.size ?? 0) }
            var sent: Int64 = 0
            let started = Date()
            for (digest, path) in pending.sorted(by: { $0.key < $1.key }) {
                try checkAbort()
                currentProgress = transferProgress(plan, completed: known.count, total: unique.count,
                    sent: sent, totalBytes: totalBytes, started: started, phase: "uploading")
                let file = URL(fileURLWithPath: path)
                let uploadToken = try await client.uploadBytes(at: file)
                sent += plan.files[path]?.size ?? 0
                try ledger.recordUpload(account: plan.account, digest: digest, mediaID: nil)
                do {
                    known[digest] = try await client.createMedia(uploadToken: uploadToken, filename: file.lastPathComponent)
                } catch {
                    if Self.definitivelyRejected(error) {
                        try? ledger.discardPendingUpload(account: plan.account, digest: digest)
                    }
                    throw error
                }
                try ledger.recordUpload(account: plan.account, digest: digest, mediaID: known[digest])
            }
            var selectedByAlbum: [String: Set<String>] = [:]
            currentProgress = progress(plan, phase: "updating", message: "Adding the selection to your Google albums")
            for destination in plan.destinations.values {
                try checkAbort()
                let id = destination.albumID!
                let selected = Set(destination.paths.compactMap { plan.hashes[$0].flatMap { known[$0] } })
                selectedByAlbum[id] = selected
                try await client.changeAlbum(id, mediaIDs: selected.subtracting(destination.oldIDs), removing: false)
            }
            for destination in plan.destinations.values {
                let id = destination.albumID!, actual = try await client.albumMediaIDs(id)
                let selected = selectedByAlbum[id]!
                guard selected.isSubset(of: actual) else {
                    throw NativeGoogleSyncError.message("Google has not confirmed all additions. Nothing old was removed; try again later.")
                }
                if replace && actual != destination.oldIDs.union(selected) {
                    throw NativeGoogleSyncError.message("The album changed during sync. New photos were added, but old photos were kept. Review again.")
                }
            }
            if replace {
                currentProgress = progress(plan, phase: "replacing", message: "Removing the previous Photo Curator selection from the album")
                for destination in plan.destinations.values {
                    let id = destination.albumID!, selected = selectedByAlbum[id]!
                    let removed = destination.oldIDs.subtracting(selected)
                    try await client.changeAlbum(id, mediaIDs: removed, removing: true)
                    let actual = try await client.albumMediaIDs(id)
                    guard selected.isSubset(of: actual), removed.isDisjoint(with: actual) else {
                        throw NativeGoogleSyncError.message("Google has not confirmed the album replacement. Check it before retrying.")
                    }
                }
            }
            currentProgress = TransferProgress(runID: plan.token, phase: "complete",
                message: "Google album updated. Your Nest Hub will refresh on its own schedule.",
                completed: unique.count, total: unique.count, reused: unique.count - pending.count,
                sentBytes: totalBytes, totalBytes: totalBytes, bytesPerSecond: nil, etaSeconds: nil,
                destinations: plan.destinations.values.map { .init(id: $0.albumID!, title: $0.title) })
            succeeded = true
        } catch {
            currentError = error.localizedDescription
            currentProgress = progress(plan, phase: error as? NativeGoogleSyncError == .aborted ? "aborted" : "failed",
                                       message: error.localizedDescription)
        }
        task = nil
    }

    private func checkAbort() throws { if abortRequested { throw NativeGoogleSyncError.aborted } }

    private func progress(_ plan: Plan, phase: String, message: String) -> TransferProgress {
        TransferProgress(runID: plan.token, phase: phase, message: message, completed: nil, total: nil,
                         reused: nil, sentBytes: nil, totalBytes: nil, bytesPerSecond: nil,
                         etaSeconds: nil, destinations: nil)
    }

    private func transferProgress(_ plan: Plan, completed: Int, total: Int, sent: Int64,
                                  totalBytes: Int64, started: Date, phase: String) -> TransferProgress {
        let elapsed = max(0.001, Date().timeIntervalSince(started))
        let speed = Double(sent) / elapsed
        let eta = elapsed >= 5 && speed > 0 ? Double(totalBytes - sent) / speed : nil
        return TransferProgress(runID: plan.token, phase: phase, message: "Sending photos to Google Photos",
            completed: completed, total: total, reused: total - completed,
            sentBytes: sent, totalBytes: totalBytes, bytesPerSecond: speed, etaSeconds: eta, destinations: nil)
    }

    private static func unchanged(path: String, expected: FileState) throws -> Bool {
        let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return Int64(values.fileSize ?? -1) == expected.size && (values.contentModificationDate ?? .distantPast) == expected.modified
    }

    private static func fileDigest(_ url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func definitivelyRejected(_ error: Error) -> Bool {
        guard case NativeGooglePhotosError.rejected(let status, _) = error else { return false }
        return (400..<500).contains(status) && status != 408 && status != 429
    }
}
