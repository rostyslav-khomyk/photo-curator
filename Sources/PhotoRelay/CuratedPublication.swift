import Foundation

struct CuratedPublicationRequest: Codable, Equatable, Sendable {
    let operationID: UUID
    let momentID: String
    let title: String
    var description: String? = nil
    var keyAssetID: String? = nil
    var date: Date? = nil
    let assetIDs: [String]

    init(operationID: UUID, momentID: String, title: String, description: String? = nil,
         keyAssetID: String? = nil, date: Date? = nil, assetIDs: [String]) {
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
        if let keyAssetID, !assetIDs.contains(keyAssetID) { throw PublicationFailure.invalidRequest }
    }
}

struct CuratedAlbumReceipt: Codable, Equatable, Sendable {
    let albumID: String
    let assetIDs: [String]
    var rootFolderID: String? = nil
    var yearFolderID: String? = nil
    var createdContainerIDs: [String] = []
}

struct ManagedPhotoContainer: Equatable, Sendable {
    enum Kind: String, Sendable { case root, year, album }
    let id: String
    let kind: Kind
    let parentID: String?
}

enum PublicationFailure: Error, Equatable {
    case invalidRequest
    case conflictingOperation
    case invalidReceipt
    case verificationPending
    case destinationConflict
    case catalogUnavailable
    case corruptJournal
}

extension PublicationFailure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "This Moment has no valid photos or title to save."
        case .conflictingOperation: return "Another save for this Moment is already in progress."
        case .invalidReceipt: return "Photos returned an incomplete album receipt. Nothing was marked as saved."
        case .verificationPending: return "Photos is still confirming the album. Photo Curator will verify it again."
        case .destinationConflict: return "The managed Photos album exists with unexpected contents. It was left unchanged."
        case .catalogUnavailable: return "The local catalog is unavailable. The Photos library was left unchanged."
        case .corruptJournal: return "Saved operation state could not be read safely."
        }
    }
}

enum PublicationSagaPhase: String, Codable, Sendable {
    case requested, applying, verifying, succeeded
}

struct PublicationSagaRecord: Equatable, Sendable {
    let request: CuratedPublicationRequest
    var phase: PublicationSagaPhase
    var receipt: CuratedAlbumReceipt?
    var verificationAttempts: Int
    var nextVerificationAt: Date?
    var lastError: String?
    var updatedAt: Date
}

enum CuratedAlbumRecovery: Equatable, Sendable {
    case confirmed(CuratedAlbumReceipt)
    case absent
    case conflicting
}

protocol CuratedAlbumAdapter: Sendable {
    func publish(_ request: CuratedPublicationRequest) async throws -> CuratedAlbumReceipt
    func recover(_ request: CuratedPublicationRequest) async throws -> CuratedAlbumRecovery
}

/// Owns every Photos publication. Database transactions are synchronous and never span PhotoKit awaits.
actor PublicationCoordinator {
    typealias Delay = @Sendable (TimeInterval) async throws -> Void

    private let store: CatalogV2Store
    private let adapter: CuratedAlbumAdapter
    private let delay: Delay
    private var runningMomentIDs = Set<String>()

    init(store: CatalogV2Store, adapter: CuratedAlbumAdapter,
         delay: @escaping Delay = { seconds in
             try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.store = store
        self.adapter = adapter
        self.delay = delay
    }

    func publish(_ request: CuratedPublicationRequest) async throws -> CuratedAlbumReceipt {
        try request.validate()
        guard runningMomentIDs.insert(request.momentID).inserted else {
            throw PublicationFailure.conflictingOperation
        }
        defer { runningMomentIDs.remove(request.momentID) }

        let record = try await store.preparePublication(request)
        let durableRequest = record.request
        if record.phase == .succeeded, let receipt = record.receipt { return receipt }
        switch record.phase {
        case .requested:
            return try await apply(durableRequest)
        case .applying:
            let verifying = try await store.markPublicationVerifying(
                operationID: durableRequest.operationID, receipt: record.receipt,
                error: record.lastError)
            return try await verify(durableRequest, record: verifying)
        case .verifying:
            return try await verify(durableRequest, record: record)
        case .succeeded:
            throw PublicationFailure.invalidReceipt
        }
    }

    func recoverPending() async -> [String: Result<CuratedAlbumReceipt, Error>] {
        let requests: [CuratedPublicationRequest]
        do { requests = try await store.pendingPublications().map(\.request) }
        catch { return ["catalog": .failure(error)] }
        var results: [String: Result<CuratedAlbumReceipt, Error>] = [:]
        for request in requests {
            do { results[request.momentID] = .success(try await publish(request)) }
            catch { results[request.momentID] = .failure(error) }
        }
        return results
    }

    private func apply(_ request: CuratedPublicationRequest) async throws -> CuratedAlbumReceipt {
        try await store.markPublicationApplying(operationID: request.operationID)
        try Task.checkCancellation()
        let receipt: CuratedAlbumReceipt
        do {
            receipt = try await adapter.publish(request)
        } catch {
            let record = try await store.markPublicationVerifying(
                operationID: request.operationID, receipt: nil, error: error.localizedDescription)
            return try await verify(request, record: record)
        }
        try validate(receipt, for: request)
        let record = try await store.markPublicationVerifying(
            operationID: request.operationID, receipt: receipt, error: nil)
        return try await verify(request, record: record)
    }

    private func verify(_ request: CuratedPublicationRequest,
                        record initial: PublicationSagaRecord) async throws -> CuratedAlbumReceipt {
        var record = initial
        for backoff in [0.0, 0.25, 0.5, 1.0] {
            if backoff > 0 { try await delay(backoff) }
            try Task.checkCancellation()
            switch try await adapter.recover(request) {
            case .confirmed(let receipt):
                let completed = receipt.preservingOwnership(from: record.receipt)
                try validate(completed, for: request)
                try await store.completePublication(operationID: request.operationID,
                                                    receipt: completed, date: Date())
                return completed
            case .absent:
                record = try await store.recordPublicationVerification(
                    operationID: request.operationID, error: "Managed album is not visible yet")
            case .conflicting:
                record = try await store.recordPublicationVerification(
                    operationID: request.operationID, error: "Managed album has unexpected contents")
                if record.verificationAttempts >= 4 { throw PublicationFailure.destinationConflict }
            }
        }

        // A crash may leave an applying operation with no receipt. Once absence has been
        // observed repeatedly, retrying is safe because the PhotoKit adapter is title-idempotent.
        if record.receipt == nil, record.verificationAttempts >= 4 {
            try await store.resetPublicationForRetry(operationID: request.operationID)
            return try await apply(request)
        }
        throw PublicationFailure.verificationPending
    }

    private func validate(_ receipt: CuratedAlbumReceipt,
                          for request: CuratedPublicationRequest) throws {
        guard !receipt.albumID.isEmpty,
              receipt.assetIDs.count == request.assetIDs.count,
              Set(receipt.assetIDs) == Set(request.assetIDs) else {
            throw PublicationFailure.invalidReceipt
        }
    }
}

private extension CuratedAlbumReceipt {
    func preservingOwnership(from durable: CuratedAlbumReceipt?) -> CuratedAlbumReceipt {
        guard let durable, durable.albumID == albumID else { return self }
        return CuratedAlbumReceipt(albumID: albumID, assetIDs: assetIDs,
            rootFolderID: rootFolderID ?? durable.rootFolderID,
            yearFolderID: yearFolderID ?? durable.yearFolderID,
            createdContainerIDs: createdContainerIDs.isEmpty
                ? durable.createdContainerIDs : createdContainerIDs)
    }
}
