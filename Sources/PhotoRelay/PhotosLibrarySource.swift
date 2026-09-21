import Foundation
import Photos

struct PhotosAlbum: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let count: Int
}

struct PhotosAlbumSelection: Decodable, Sendable {
    let id: String
    let title: String
}

struct ExportedPhotosItem: Codable, Sendable {
    let path: String
    let album: String
    let assetID: String?

    init(path: String, album: String, assetID: String? = nil) {
        self.path = path
        self.album = album
        self.assetID = assetID
    }
}

struct PhotosLibrarySource: Sendable {
    private static let allPhotosIdentifier = "photo-relay://all-photos"

    func listAlbums() async throws -> [PhotosAlbum] {
        try await authorize()
        return await Task.detached(priority: .userInitiated) {
            var albums = [
                PhotosAlbum(
                    id: Self.allPhotosIdentifier,
                    title: "All Photos",
                    count: PHAsset.fetchAssets(with: nil).count
                )
            ]
            let collections = PHAssetCollection.fetchAssetCollections(
                with: .album,
                subtype: .any,
                options: nil
            )
            for index in 0..<collections.count {
                let collection = collections.object(at: index)
                guard let title = collection.localizedTitle, !title.isEmpty else { continue }
                albums.append(
                    PhotosAlbum(
                        id: collection.localIdentifier,
                        title: title,
                        count: PHAsset.fetchAssets(in: collection, options: nil).count
                    )
                )
            }
            albums.sort {
                if $0.id == Self.allPhotosIdentifier { return true }
                if $1.id == Self.allPhotosIdentifier { return false }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return albums
        }.value
    }

    func export(
        selections: [PhotosAlbumSelection],
        directory: String,
        skipVideos: Bool,
        skipLivePhotos: Bool,
        recent: Int?,
        dryRun: Bool,
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> [ExportedPhotosItem] {
        try await authorize()
        return try await Task.detached(priority: .userInitiated) {
            let expanded = (directory as NSString).expandingTildeInPath
            let root = URL(fileURLWithPath: expanded, isDirectory: true)
            if !dryRun {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            }
            var exported: [ExportedPhotosItem] = []
            var failures: [String] = []
            for selection in selections {
                let assets = Self.assets(for: selection.id, recent: recent)
                await progress("Exporting \(selection.title): \(assets.count) asset(s)...")
                for index in 0..<assets.count {
                    try Task.checkCancellation()
                    let asset = assets.object(at: index)
                    if skipVideos && asset.mediaType == .video { continue }
                    if skipLivePhotos && asset.mediaSubtypes.contains(.photoLive) { continue }
                    await progress("Preparing \(selection.title): \(index + 1) of \(assets.count) items...")
                    let resources = Self.resources(for: asset)
                    if resources.isEmpty { failures.append(asset.localIdentifier) }
                    for resource in resources {
                        let folder = root
                            .appendingPathComponent(Self.safePathComponent(selection.title), isDirectory: true)
                            .appendingPathComponent("_assets", isDirectory: true)
                            .appendingPathComponent(Self.safePathComponent(asset.localIdentifier), isDirectory: true)
                            .appendingPathComponent("\(resource.type.rawValue)-\(asset.modificationDate?.timeIntervalSince1970 ?? 0)", isDirectory: true)
                        let file = folder.appendingPathComponent(Self.safePathComponent(resource.originalFilename))
                        do {
                            if !dryRun && !FileManager.default.fileExists(atPath: file.path) {
                                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                                try await Self.write(resource: resource, to: file)
                                if let date = asset.creationDate {
                                    try? FileManager.default.setAttributes(
                                        [.creationDate: date, .modificationDate: date],
                                        ofItemAtPath: file.path
                                    )
                                }
                            }
                            exported.append(ExportedPhotosItem(path: file.path, album: selection.title,
                                                               assetID: asset.localIdentifier))
                        } catch {
                            failures.append(resource.originalFilename)
                            await progress("Could not export \(resource.originalFilename): \(error.localizedDescription)")
                        }
                    }
                }
            }
            guard failures.isEmpty else {
                throw NSError(domain: "PhotoRelay.Photos", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Could not prepare \(failures.count) item(s), including \(failures[0]). Google Photos was not changed. Try again when these photos are available."
                ])
            }
            return exported
        }.value
    }

    func export(
        assetIDs: [String],
        albumTitle: String,
        directory: String,
        skipVideos: Bool,
        skipLivePhotos: Bool,
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> [ExportedPhotosItem] {
        try await authorize()
        return try await Task.detached(priority: .userInitiated) {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(Set(assetIDs)), options: nil)
            var exported: [ExportedPhotosItem] = []
            var failures: [String] = []
            for index in 0..<assets.count {
                try Task.checkCancellation()
                let asset = assets.object(at: index)
                if skipVideos && asset.mediaType == .video { continue }
                if skipLivePhotos && asset.mediaSubtypes.contains(.photoLive) { continue }
                await progress("Preparing \(index + 1) of \(assets.count) selected items...")
                let resources = Self.resources(for: asset)
                if resources.isEmpty { failures.append(asset.localIdentifier) }
                for resource in resources {
                    let folder = root.appendingPathComponent(Self.safePathComponent(asset.localIdentifier), isDirectory: true)
                    let file = folder.appendingPathComponent(Self.safePathComponent(resource.originalFilename))
                    do {
                        if !FileManager.default.fileExists(atPath: file.path) {
                            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            try await Self.write(resource: resource, to: file)
                        }
                        exported.append(ExportedPhotosItem(path: file.path, album: albumTitle,
                                                           assetID: asset.localIdentifier))
                    } catch {
                        failures.append(resource.originalFilename)
                    }
                }
            }
            guard failures.isEmpty else {
                throw NSError(domain: "PhotoRelay.Photos", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Could not prepare \(failures.count) selected item(s). Google Photos was not changed."
                ])
            }
            return exported
        }.value
    }

    private func authorize() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let resolved: PHAuthorizationStatus
        if status == .notDetermined {
            resolved = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        } else {
            resolved = status
        }
        guard resolved == .authorized || resolved == .limited else {
            throw NSError(
                domain: "PhotoRelay.Photos",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Photos access is required. Enable Photo Curator in System Settings > Privacy & Security > Photos."
                ]
            )
        }
    }

    private static func assets(for identifier: String, recent: Int?) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let recent { options.fetchLimit = recent }
        if identifier == allPhotosIdentifier { return PHAsset.fetchAssets(with: options) }
        guard let collection = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [identifier],
            options: nil
        ).firstObject else {
            return PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil)
        }
        return PHAsset.fetchAssets(in: collection, options: options)
    }

    private static func resources(for asset: PHAsset) -> [PHAssetResource] {
        let resources = PHAssetResource.assetResources(for: asset)
        if asset.mediaType == .video {
            if let fullSize = resources.first(where: { $0.type == .fullSizeVideo }) { return [fullSize] }
            return resources.first(where: { $0.type == .video }).map { [$0] } ?? []
        }
        var selected: [PHAssetResource] = []
        if let photo = resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first(where: { $0.type == .photo }) {
            selected.append(photo)
        }
        if asset.mediaSubtypes.contains(.photoLive),
           let pairedVideo = resources.first(where: { $0.type == .pairedVideo }) {
            selected.append(pairedVideo)
        }
        return selected
    }

    private static func write(resource: PHAssetResource, to url: URL) async throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: temporaryURL,
                options: options
            ) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }

    private static func safePathComponent(_ value: String) -> String {
        value.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
    }
}
