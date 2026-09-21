import Foundation

struct CuratedPublicationRequest: Codable, Equatable {
    let operationID: UUID
    let momentID: String
    let title: String
    var description: String? = nil
    var keyAssetID: String? = nil
    var date: Date? = nil
    let assetIDs: [String]

    init(operationID: UUID, momentID: String, title: String, description: String? = nil, keyAssetID: String? = nil, date: Date? = nil, assetIDs: [String]) {
        self.operationID = operationID
        self.momentID = momentID
        self.title = title
        self.description = description
        self.keyAssetID = keyAssetID
        self.date = date
        self.assetIDs = assetIDs
    }

    func validate() throws {
        guard !momentID.isEmpty, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !assetIDs.isEmpty, assetIDs.allSatisfy({ !$0.isEmpty }),
              Set(assetIDs).count == assetIDs.count else { throw PublicationFailure.invalidRequest }
        if let keyAssetID = keyAssetID {
            guard assetIDs.contains(keyAssetID) else { throw PublicationFailure.invalidRequest }
        }
    }
}

struct CuratedAlbumReceipt: Codable, Equatable {
    let albumID: String
    let assetIDs: [String]
}

enum PublicationFailure: Error, Equatable {
    case invalidRequest, conflictingOperation, invalidReceipt, uncertainPublication, uncertainUpload, corruptJournal
}

enum PublicationPhase: String, Codable {
    case prepared, publishing, published, uploading, complete
}

struct PublicationRecord: Codable, Equatable {
    var schemaVersion = 1
    let request: CuratedPublicationRequest
    var phase: PublicationPhase
    var album: CuratedAlbumReceipt?
    var uploadReceipt: String?
}

protocol CuratedAlbumAdapter: Sendable {
    func publish(_ request: CuratedPublicationRequest) async throws -> CuratedAlbumReceipt
    func recover(_ request: CuratedPublicationRequest) async throws -> CuratedAlbumReceipt?
}

protocol CuratedUploadAdapter: Sendable {
    func upload(_ album: CuratedAlbumReceipt, operationID: UUID) async throws -> String
    func recover(operationID: UUID) async throws -> String?
}

/// One immutable operation per journal. No automatic retry after an ambiguous external call.
/// A sidecar lock serializes processes; state is reloaded after acquiring it.
actor CuratedPublication {
    private let journal: URL
    private var record: PublicationRecord?
    private var running = false

    init(journal: URL) throws {
        self.journal = journal
        record = try Self.read(journal)
    }

    private static func read(_ journal: URL) throws -> PublicationRecord? {
        if FileManager.default.fileExists(atPath: journal.path) {
            do {
                let size = try journal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 8 * 1024 * 1024 else { throw PublicationFailure.corruptJournal }
                let saved = try JSONDecoder().decode(PublicationRecord.self, from: Data(contentsOf: journal))
                try saved.request.validate()
                guard saved.schemaVersion == 1 else { throw PublicationFailure.corruptJournal }
                if saved.phase == .prepared || saved.phase == .publishing {
                    guard saved.album == nil, saved.uploadReceipt == nil else { throw PublicationFailure.corruptJournal }
                }
                if saved.phase != .complete, saved.uploadReceipt != nil { throw PublicationFailure.corruptJournal }
                if saved.phase == .published || saved.phase == .uploading || saved.phase == .complete {
                    guard let album = saved.album, !album.albumID.isEmpty,
                          Set(album.assetIDs) == Set(saved.request.assetIDs),
                          album.assetIDs.count == saved.request.assetIDs.count else { throw PublicationFailure.corruptJournal }
                }
                if saved.phase == .complete, saved.uploadReceipt?.isEmpty != false { throw PublicationFailure.corruptJournal }
                return saved
            } catch { throw PublicationFailure.corruptJournal }
        }
        return nil
    }

    private func save(_ value: PublicationRecord) throws {
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        guard data.count <= 8 * 1024 * 1024 else { throw PublicationFailure.invalidRequest }
        try data.write(to: journal, options: .atomic)
        record = value
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
    }

    func snapshot() -> PublicationRecord? { record }

    func publish(_ request: CuratedPublicationRequest, adapter: CuratedAlbumAdapter,
                 retryAfterConfirmedAbsence: Bool = false) async throws -> CuratedAlbumReceipt {
        guard !running else { throw PublicationFailure.conflictingOperation }
        running = true
        defer { running = false }
        let lock = try PublicationJournalLock(journal: journal)
        defer { withExtendedLifetime(lock) {} }
        record = try Self.read(journal)
        try request.validate()
        if let record, record.request != request { throw PublicationFailure.conflictingOperation }
        if record == nil { try save(PublicationRecord(request: request, phase: .prepared)) }
        var state = record!
        if let album = state.album { return album }
        try Task.checkCancellation()
        let receipt: CuratedAlbumReceipt
        if state.phase == .publishing {
            if let recovered = try await adapter.recover(request) {
                receipt = recovered
            } else if retryAfterConfirmedAbsence {
                // The concrete adapter has verified that the exact managed destination is absent.
                // Return to prepared before retrying so another interruption remains recoverable.
                state.phase = .prepared
                try save(state)
                state.phase = .publishing
                try save(state)
                receipt = try await adapter.publish(request)
            } else {
                throw PublicationFailure.uncertainPublication
            }
        } else {
            state.phase = .publishing
            try save(state)
            receipt = try await adapter.publish(request)
        }
        guard !receipt.albumID.isEmpty, Set(receipt.assetIDs) == Set(request.assetIDs),
              receipt.assetIDs.count == request.assetIDs.count else { throw PublicationFailure.invalidReceipt }
        // Persist a confirmed effect even if cancellation arrived during the adapter call.
        state.album = receipt
        state.phase = .published
        try save(state)
        return receipt
    }

    func sync(adapter: CuratedUploadAdapter) async throws -> String {
        guard !running else { throw PublicationFailure.conflictingOperation }
        running = true
        defer { running = false }
        let lock = try PublicationJournalLock(journal: journal)
        defer { withExtendedLifetime(lock) {} }
        record = try Self.read(journal)
        guard var state = record, let album = state.album else { throw PublicationFailure.invalidRequest }
        if let receipt = state.uploadReceipt { return receipt }
        try Task.checkCancellation()
        let receipt: String
        if state.phase == .uploading {
            guard let recovered = try await adapter.recover(operationID: state.request.operationID) else { throw PublicationFailure.uncertainUpload }
            receipt = recovered
        } else {
            state.phase = .uploading
            try save(state)
            receipt = try await adapter.upload(album, operationID: state.request.operationID)
        }
        guard !receipt.isEmpty else { throw PublicationFailure.invalidReceipt }
        state.uploadReceipt = receipt
        state.phase = .complete
        try save(state)
        return receipt
    }
}
