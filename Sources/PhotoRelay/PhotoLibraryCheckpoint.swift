import Foundation
import Photos

struct PhotoLibraryFingerprint: Codable, Equatable {
    struct Asset: Codable, Equatable {
        let id: String
        let modified: Date?
    }

    let count: Int
    let newest: [Asset]

    static func current(sampleSize: Int = 12) -> Self {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        let assets = PHAsset.fetchAssets(with: options)
        let newest = (0..<min(sampleSize, assets.count)).map { index in
            let asset = assets.object(at: index)
            return Asset(id: asset.localIdentifier, modified: asset.modificationDate)
        }
        return Self(count: assets.count, newest: newest)
    }
}

struct PhotoLibraryCheckpoint: Codable, Equatable {
    let fingerprint: PhotoLibraryFingerprint
    let fullyVerifiedAt: Date
    let persistentToken: Data?

    init(fingerprint: PhotoLibraryFingerprint, fullyVerifiedAt: Date, persistentToken: Data? = nil) {
        self.fingerprint = fingerprint
        self.fullyVerifiedAt = fullyVerifiedAt
        self.persistentToken = persistentToken
    }

    func requiresFullReconciliation(current: PhotoLibraryFingerprint, now: Date,
                                    maximumAge: TimeInterval = 7 * 24 * 60 * 60) -> Bool {
        let sourceCannotReplayChanges: Bool
        if let persistentToken {
            sourceCannotReplayChanges = PhotoLibraryChangeToken.decode(persistentToken) == nil
        } else {
            sourceCannotReplayChanges = fingerprint != current
        }
        return sourceCannotReplayChanges || now.timeIntervalSince(fullyVerifiedAt) >= maximumAge
    }
}

enum PhotoLibraryChangeToken {
    static func encode(_ token: PHPersistentChangeToken) -> Data? {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        token.encode(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    static func decode(_ data: Data) -> PHPersistentChangeToken? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return PHPersistentChangeToken(coder: unarchiver)
    }

    static func capture(library: PHPhotoLibrary = .shared()) -> Data? {
        encode(library.currentChangeToken)
    }

    static func matchesCurrent(_ data: Data, library: PHPhotoLibrary = .shared()) -> Bool {
        guard let saved = decode(data) else { return false }
        return saved == library.currentChangeToken
    }
}

struct PhotoLibraryCheckpointStore {
    let url: URL

    func load() -> PhotoLibraryCheckpoint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PhotoLibraryCheckpoint.self, from: data)
    }

    func save(_ checkpoint: PhotoLibraryCheckpoint) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(checkpoint).write(to: url, options: .atomic)
    }

    func updateFingerprint(_ fingerprint: PhotoLibraryFingerprint) throws {
        guard let previous = load() else { return }
        try save(PhotoLibraryCheckpoint(fingerprint: fingerprint,
                                        fullyVerifiedAt: previous.fullyVerifiedAt,
                                        persistentToken: previous.persistentToken))
    }
}
