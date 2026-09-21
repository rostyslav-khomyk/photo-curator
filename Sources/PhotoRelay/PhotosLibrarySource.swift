import Foundation
import Photos

struct PhotosAlbum: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let count: Int
}

struct PhotosAlbumSelection: Decodable {
    let id: String
    let title: String
}

struct ExportedPhotosItem: Codable {
    let path: String
    let album: String
    let assetID: String?

    init(path: String, album: String, assetID: String? = nil) {
        self.path = path
        self.album = album
        self.assetID = assetID
    }
}

final class PhotosLibrarySource {
    private let allPhotosIdentifier = "photo-relay://all-photos"

    func listAlbums(completion: @escaping (Result<[PhotosAlbum], Error>) -> Void) {
        authorize { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                DispatchQueue.global(qos: .userInitiated).async {
                    var albums = [
                        PhotosAlbum(
                            id: self.allPhotosIdentifier,
                            title: "All Photos",
                            count: PHAsset.fetchAssets(with: nil).count
                        )
                    ]
                    let collections = PHAssetCollection.fetchAssetCollections(
                        with: .album,
                        subtype: .any,
                        options: nil
                    )
                    collections.enumerateObjects { collection, _, _ in
                        guard let title = collection.localizedTitle, !title.isEmpty else { return }
                        albums.append(
                            PhotosAlbum(
                                id: collection.localIdentifier,
                                title: title,
                                count: PHAsset.fetchAssets(in: collection, options: nil).count
                            )
                        )
                    }
                    albums.sort {
                        if $0.id == self.allPhotosIdentifier { return true }
                        if $1.id == self.allPhotosIdentifier { return false }
                        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    }
                    completion(.success(albums))
                }
            }
        }
    }

    func export(
        selections: [PhotosAlbumSelection],
        directory: String,
        skipVideos: Bool,
        skipLivePhotos: Bool,
        recent: Int?,
        dryRun: Bool,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<[ExportedPhotosItem], Error>) -> Void
    ) {
        authorize { [weak self] result in
            guard let self else { return }
            guard case .success = result else {
                if case .failure(let error) = result { completion(.failure(error)) }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let expanded = (directory as NSString).expandingTildeInPath
                    let root = URL(fileURLWithPath: expanded, isDirectory: true)
                    if !dryRun {
                        try FileManager.default.createDirectory(
                            at: root,
                            withIntermediateDirectories: true
                        )
                    }
                    var exported: [ExportedPhotosItem] = []
                    var exportFailures: [String] = []
                    for selection in selections {
                        let assets = self.assets(for: selection.id, recent: recent)
                        progress("Exporting \(selection.title): \(assets.count) asset(s)…")
                        assets.enumerateObjects { asset, index, _ in
                            if skipVideos && asset.mediaType == .video { return }
                            if skipLivePhotos && asset.mediaSubtypes.contains(.photoLive) { return }
                            progress("Preparing \(selection.title): \(index + 1) of \(assets.count) items…")
                            let resources = self.resources(for: asset)
                            if resources.isEmpty { exportFailures.append(asset.localIdentifier) }
                            for resource in resources {
                                let albumDirectory = root.appendingPathComponent(
                                    self.safePathComponent(selection.title),
                                    isDirectory: true
                                )
                                .appendingPathComponent("_assets", isDirectory: true)
                                .appendingPathComponent(self.safePathComponent(asset.localIdentifier), isDirectory: true)
                                .appendingPathComponent("\(resource.type.rawValue)-\(asset.modificationDate?.timeIntervalSince1970 ?? 0)", isDirectory: true)
                                let fileURL = albumDirectory.appendingPathComponent(
                                    self.safePathComponent(resource.originalFilename)
                                )
                                do {
                                    if !dryRun && !FileManager.default.fileExists(atPath: fileURL.path) {
                                        try FileManager.default.createDirectory(
                                            at: albumDirectory,
                                            withIntermediateDirectories: true
                                        )
                                        try self.write(resource: resource, to: fileURL)
                                        if let creationDate = asset.creationDate {
                                            try? FileManager.default.setAttributes(
                                                [
                                                    .creationDate: creationDate,
                                                    .modificationDate: creationDate,
                                                ],
                                                ofItemAtPath: fileURL.path
                                            )
                                        }
                                    }
                                    exported.append(
                                        ExportedPhotosItem(path: fileURL.path, album: selection.title,
                                                           assetID: asset.localIdentifier)
                                    )
                                } catch {
                                    exportFailures.append(resource.originalFilename)
                                    progress("Could not export \(resource.originalFilename): \(error.localizedDescription)")
                                }
                            }
                        }
                    }
                    if !exportFailures.isEmpty {
                        throw NSError(domain: "PhotoRelay.Photos", code: 2, userInfo: [
                            NSLocalizedDescriptionKey: "Could not prepare \(exportFailures.count) item(s), including \(exportFailures[0]). Google Photos was not changed. Try again when these photos are available."
                        ])
                    }
                    completion(.success(exported))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    func export(assetIDs: [String], albumTitle: String, directory: String,
                skipVideos: Bool, skipLivePhotos: Bool,
                progress: @escaping (String) -> Void,
                completion: @escaping (Result<[ExportedPhotosItem], Error>) -> Void) {
        authorize { [weak self] result in
            guard let self else { return }
            guard case .success = result else {
                if case .failure(let error) = result { completion(.failure(error)) }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let root = URL(fileURLWithPath: directory, isDirectory: true)
                    try? FileManager.default.removeItem(at: root)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(Set(assetIDs)), options: nil)
                    var exported: [ExportedPhotosItem] = []
                    var failures: [String] = []
                    assets.enumerateObjects { asset, index, _ in
                        if skipVideos && asset.mediaType == .video { return }
                        if skipLivePhotos && asset.mediaSubtypes.contains(.photoLive) { return }
                        progress("Preparing (index + 1) of (assets.count) selected items…")
                        let resources = self.resources(for: asset)
                        if resources.isEmpty { failures.append(asset.localIdentifier) }
                        for resource in resources {
                            let folder = root.appendingPathComponent(self.safePathComponent(asset.localIdentifier), isDirectory: true)
                            let file = folder.appendingPathComponent(self.safePathComponent(resource.originalFilename))
                            do {
                                if !FileManager.default.fileExists(atPath: file.path) {
                                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                                    try self.write(resource: resource, to: file)
                                }
                                exported.append(ExportedPhotosItem(path: file.path, album: albumTitle,
                                                                   assetID: asset.localIdentifier))
                            } catch { failures.append(resource.originalFilename) }
                        }
                    }
                    guard failures.isEmpty else {
                        throw NSError(domain: "PhotoRelay.Photos", code: 2, userInfo: [NSLocalizedDescriptionKey:
                            "Could not prepare (failures.count) selected item(s). Google Photos was not changed."])
                    }
                    completion(.success(exported))
                } catch { completion(.failure(error)) }
            }
        }
    }

    private func authorize(completion: @escaping (Result<Void, Error>) -> Void) {
        let finish: (PHAuthorizationStatus) -> Void = { status in
            if status == .authorized || status == .limited {
                completion(.success(()))
            } else {
                completion(
                    .failure(
                        NSError(
                            domain: "PhotoRelay.Photos",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Photos access is required. Enable Photo Curator in System Settings > Privacy & Security > Photos."
                            ]
                        )
                    )
                )
            }
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite, handler: finish)
        } else {
            finish(status)
        }
    }

    private func assets(for identifier: String, recent: Int?) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let recent { options.fetchLimit = recent }
        if identifier == allPhotosIdentifier {
            return PHAsset.fetchAssets(with: options)
        }
        let collection = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [identifier],
            options: nil
        ).firstObject
        guard let collection else { return PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil) }
        return PHAsset.fetchAssets(in: collection, options: options)
    }

    private func resources(for asset: PHAsset) -> [PHAssetResource] {
        let resources = PHAssetResource.assetResources(for: asset)
        if asset.mediaType == .video {
            if let fullSize = resources.first(where: { $0.type == .fullSizeVideo }) {
                return [fullSize]
            }
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

    private func write(resource: PHAssetResource, to url: URL) throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let semaphore = DispatchSemaphore(value: 0)
        var writeError: Error?
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        PHAssetResourceManager.default().writeData(
            for: resource,
            toFile: temporaryURL,
            options: options
        ) { error in
            writeError = error
            semaphore.signal()
        }
        semaphore.wait()
        if let writeError { throw writeError }
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }

    private func safePathComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        return value.components(separatedBy: invalid).joined(separator: "-")
    }
}
