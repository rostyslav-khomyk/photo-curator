import Foundation

struct PhotoLibraryAssetCounts: Codable, Equatable, Sendable {
    let assets: Int
    let favorites: Int
}

func containsOnlyManagedContainers(_ childIDs: Set<String>, managedIDs: Set<String>) -> Bool {
    childIDs.isSubset(of: managedIDs)
}

struct CuratorResetPreview: Identifiable, Equatable, Sendable {
    let id = UUID()
    let containers: [ManagedPhotoContainer]
    let publishedAlbums: Int
    let reclaimableBytes: Int64
    let library: PhotoLibraryAssetCounts

    var verifiedAlbums: Int { containers.filter { $0.kind == .album }.count }
    var verifiedFolders: Int { containers.filter { $0.kind != .album }.count }
    var unverifiedAlbums: Int { max(0, publishedAlbums - verifiedAlbums) }
}

struct CuratorReanalysisPreview: Identifiable, Equatable, Sendable {
    let id = UUID()
    let photos: Int
    let currentCacheBytes: Int64

    var estimatedSeconds: TimeInterval { TimeInterval(photos) * 2 }
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

    static func production(fileManager: FileManager = .default) -> CuratorResetJournal {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Curator Maintenance", isDirectory: true)
        return CuratorResetJournal(url: root.appendingPathComponent("reset.json"))
    }

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
    private let delay: @Sendable (TimeInterval) async throws -> Void

    init(photos: CuratorResetPhotos, localData: CuratorResetLocalData, journal: CuratorResetJournal,
         delay: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.photos = photos
        self.localData = localData
        self.journal = journal
        self.delay = delay
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
                try await verifyDeletion(containers, preserving: operation.before)
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

    /// Runs all Photos-facing phases, then stops at the restart boundary so no live
    /// SQLite connection can write into data being erased.
    func resumeThroughPhotos(now: Date = Date()) async throws -> CuratorResetOperation {
        guard var operation = try journal.load() else { throw CocoaError(.fileNoSuchFile) }
        let containers = try decodedContainers(operation)
        while operation.phase != .erasingLocalData && operation.phase != .recreatingCatalog &&
                operation.phase != .completed {
            switch operation.phase {
            case .requested:
                try await photos.verifyOwnership(of: containers)
                try advance(&operation, to: .deletingContainers, now: now)
            case .deletingContainers:
                try await photos.deleteContainers(containers)
                try advance(&operation, to: .verifyingPhotos, now: now)
            case .verifyingPhotos:
                try await verifyDeletion(containers, preserving: operation.before)
                try advance(&operation, to: .erasingLocalData, now: now)
            case .erasingLocalData, .recreatingCatalog, .completed:
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

    private func verifyDeletion(_ containers: [ManagedPhotoContainer],
                                preserving counts: PhotoLibraryAssetCounts) async throws {
        for wait in [0.0, 0.25, 0.5, 1.0, 2.0] {
            if wait > 0 { try await delay(wait) }
            guard try await photos.containersAreAbsent(containers) else { continue }
            guard try await photos.assetCounts() == counts else {
                throw PublicationFailure.destinationConflict
            }
            return
        }
        throw PublicationFailure.verificationPending
    }

    private func decodedContainers(_ operation: CuratorResetOperation) throws -> [ManagedPhotoContainer] {
        let containers = operation.containers.compactMap(\.value)
        guard containers.count == operation.containers.count else { throw CocoaError(.fileReadCorruptFile) }
        return containers
    }
}

struct CuratorLocalDataReset: CuratorResetLocalData, @unchecked Sendable {
    let supportRoot: URL
    let cacheRoot: URL
    let defaults: UserDefaults
    var logsRoot: URL? = nil

    static func production(fileManager: FileManager = .default,
                           defaults: UserDefaults = .standard) -> CuratorLocalDataReset {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Relay/curator", isDirectory: true)
        let cache = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Curator", isDirectory: true)
        let logs = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Photo Relay", isDirectory: true)
        return CuratorLocalDataReset(supportRoot: support, cacheRoot: cache, defaults: defaults,
            logsRoot: logs)
    }

    func eraseCuratorData() async throws { try eraseSynchronously() }
    func recreateCatalog() async throws { try recreateSynchronously() }

    func eraseSynchronously(fileManager: FileManager = .default) throws {
        for root in [supportRoot, cacheRoot] where fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        if let logsRoot, let files = try? fileManager.contentsOfDirectory(at: logsRoot,
            includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("curator") && file.pathExtension == "jsonl" {
                try fileManager.removeItem(at: file)
            }
        }
        for key in ["curator.momentTitles.v1", "curator.momentDescriptions.v1",
                    "curator.manualReview.v1", "curator.namedMomentMembers.v1"] {
            defaults.removeObject(forKey: key)
        }
    }

    func recreateSynchronously(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: supportRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        _ = try CuratorStore(url: supportRoot.appendingPathComponent("index.sqlite3"))
        _ = try CatalogV2Store(url: supportRoot.appendingPathComponent(CatalogV2Migrator.catalogName))
    }

    func reclaimableBytes(fileManager: FileManager = .default) -> Int64 {
        [supportRoot, cacheRoot].reduce(0) { $0 + directoryBytes($1, fileManager: fileManager) }
    }

    private func directoryBytes(_ root: URL, fileManager: FileManager) -> Int64 {
        guard let files = fileManager.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}

enum CuratorResetBootstrap {
    static func finishLocalResetIfNeeded(journal: CuratorResetJournal = .production(),
                                         localData: CuratorLocalDataReset = .production(),
                                         now: Date = Date()) throws -> CuratorResetOperation? {
        guard var operation = try journal.load() else { return nil }
        if operation.phase == .erasingLocalData {
            try localData.eraseSynchronously()
            operation.phase = .recreatingCatalog
            operation.updatedAt = now
            try journal.save(operation)
        }
        if operation.phase == .recreatingCatalog {
            try localData.recreateSynchronously()
            operation.phase = .completed
            operation.updatedAt = now
            try journal.save(operation)
        }
        return operation
    }
}
