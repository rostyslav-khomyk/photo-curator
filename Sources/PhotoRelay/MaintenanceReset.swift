import Foundation

struct PhotoLibraryAssetCounts: Codable, Equatable, Sendable {
    let assets: Int
    let favorites: Int
}

enum CuratorResetPhase: String, Codable, Sendable {
    case requested, deletingContainers, verifyingPhotos, erasingLocalData, recreatingCatalog, completed
}

struct CuratorResetOperation: Codable, Equatable, Sendable {
    let id: UUID
    var phase: CuratorResetPhase
    let containers: [ManagedPhotoContainerRecord]
    let before: PhotoLibraryAssetCounts
    let reclaimableBytes: Int64
    let startedAt: Date
    var updatedAt: Date
}

struct ManagedPhotoContainerRecord: Codable, Equatable, Sendable {
    let id: String
    let kind: String
    let parentID: String?

    init(_ value: ManagedPhotoContainer) {
        id = value.id
        kind = value.kind.rawValue
        parentID = value.parentID
    }

    var value: ManagedPhotoContainer? {
        ManagedPhotoContainer.Kind(rawValue: kind).map {
            ManagedPhotoContainer(id: id, kind: $0, parentID: parentID)
        }
    }
}

protocol CuratorResetPhotos: Sendable {
    func assetCounts() async throws -> PhotoLibraryAssetCounts
    func verifyOwnership(of containers: [ManagedPhotoContainer]) async throws
    func deleteContainers(_ containers: [ManagedPhotoContainer]) async throws
    func containersAreAbsent(_ containers: [ManagedPhotoContainer]) async throws -> Bool
}

protocol CuratorResetLocalData: Sendable {
    func eraseCuratorData() async throws
    func recreateCatalog() async throws
}

struct CuratorResetJournal: Sendable {
    let url: URL

    func load() throws -> CuratorResetOperation? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(CuratorResetOperation.self, from: Data(contentsOf: url))
    }

    func save(_ operation: CuratorResetOperation) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try JSONEncoder().encode(operation).write(to: url, options: .atomic)
    }
}

actor CuratorResetCoordinator {
    private let photos: CuratorResetPhotos
    private let localData: CuratorResetLocalData
    private let journal: CuratorResetJournal

    init(photos: CuratorResetPhotos, localData: CuratorResetLocalData, journal: CuratorResetJournal) {
        self.photos = photos
        self.localData = localData
        self.journal = journal
    }

    func begin(containers: [ManagedPhotoContainer], reclaimableBytes: Int64,
               now: Date = Date()) async throws -> CuratorResetOperation {
        if let current = try journal.load(), current.phase != .completed { return current }
        let before = try await photos.assetCounts()
        let operation = CuratorResetOperation(id: UUID(), phase: .requested,
            containers: containers.map(ManagedPhotoContainerRecord.init), before: before,
            reclaimableBytes: reclaimableBytes, startedAt: now, updatedAt: now)
        try journal.save(operation)
        return operation
    }

    func resume(now: Date = Date()) async throws -> CuratorResetOperation {
        guard var operation = try journal.load() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let containers = operation.containers.compactMap(\.value)
        guard containers.count == operation.containers.count else {
            throw CocoaError(.fileReadCorruptFile)
        }

        while operation.phase != .completed {
            switch operation.phase {
            case .requested:
                try await photos.verifyOwnership(of: containers)
                try advance(&operation, to: .deletingContainers, now: now)
            case .deletingContainers:
                try await photos.deleteContainers(containers)
                try advance(&operation, to: .verifyingPhotos, now: now)
            case .verifyingPhotos:
                guard try await photos.containersAreAbsent(containers) else {
                    throw PublicationFailure.verificationPending
                }
                guard try await photos.assetCounts() == operation.before else {
                    throw PublicationFailure.destinationConflict
                }
                try advance(&operation, to: .erasingLocalData, now: now)
            case .erasingLocalData:
                try await localData.eraseCuratorData()
                try advance(&operation, to: .recreatingCatalog, now: now)
            case .recreatingCatalog:
                try await localData.recreateCatalog()
                try advance(&operation, to: .completed, now: now)
            case .completed:
                break
            }
        }
        return operation
    }

    private func advance(_ operation: inout CuratorResetOperation, to phase: CuratorResetPhase,
                         now: Date) throws {
        operation.phase = phase
        operation.updatedAt = now
        try journal.save(operation)
    }
}
