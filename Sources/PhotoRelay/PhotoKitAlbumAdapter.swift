import Foundation
import Photos

struct PhotoKitAlbumAdapter: CuratedAlbumAdapter, Sendable {
    static let shared = PhotoKitAlbumAdapter()
    let rootFolderName = "Photo Curator"

    init() {}

    func publish(_ request: CuratedPublicationRequest) async throws -> CuratedAlbumReceipt {
        try request.validate()
        let auth = await requestAuthorization()
        guard auth == .authorized || auth == .limited else {
            throw PublicationFailure.invalidRequest
        }

        let yearString = resolveYear(for: request)
        let albumTitle = resolveAlbumTitle(for: request)

        var createdAlbumID: String?

        // Step 1: Find or create root folder and year folder
        let rootFolder = try await findOrCreateRootFolder()
        let yearFolder = try await findOrCreateYearFolder(year: yearString, in: rootFolder)

        // Step 2: Check if album already exists in year folder
        let existingAlbum = findAlbum(named: albumTitle, in: yearFolder)

        // Step 3: Create or update album and assign assets
        try await PHPhotoLibrary.shared().performChanges {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: request.assetIDs, options: nil)
            let albumRequest: PHAssetCollectionChangeRequest

            if let existing = existingAlbum {
                albumRequest = PHAssetCollectionChangeRequest(for: existing) ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
                createdAlbumID = existing.localIdentifier
            } else {
                let createAlbumReq = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
                let albumPlaceholder = createAlbumReq.placeholderForCreatedAssetCollection
                createdAlbumID = albumPlaceholder.localIdentifier

                if let yearReq = PHCollectionListChangeRequest(for: yearFolder) {
                    yearReq.addChildCollections([albumPlaceholder] as NSArray)
                }
                albumRequest = createAlbumReq
            }

            // Assign existing original assets by reference (zero duplication)
            albumRequest.addAssets(assets)

            // PhotoKit has no public API for editing a Photos caption. Keep the narrative
            // in Photo Curator rather than relying on a private KVC property.
        }

        // If album was newly created, resolve its localIdentifier
        guard let finalAlbumID = createdAlbumID ?? existingAlbum?.localIdentifier, !finalAlbumID.isEmpty else {
            throw PublicationFailure.verificationPending
        }

        return CuratedAlbumReceipt(albumID: finalAlbumID, assetIDs: request.assetIDs)
    }

    func recover(_ request: CuratedPublicationRequest) async throws -> CuratedAlbumRecovery {
        try request.validate()
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard auth == .authorized || auth == .limited else { throw PublicationFailure.invalidRequest }

        let yearString = resolveYear(for: request)
        let albumTitle = resolveAlbumTitle(for: request)

        guard let rootFolder = findRootFolder(),
              let yearFolder = findYearFolder(year: yearString, in: rootFolder),
              let album = findAlbum(named: albumTitle, in: yearFolder) else { return .absent }

        let assets = PHAsset.fetchAssets(in: album, options: nil)
        var memberIDs: [String] = []
        assets.enumerateObjects { asset, _, _ in
            memberIDs.append(asset.localIdentifier)
        }

        if Set(memberIDs) == Set(request.assetIDs) {
            return .confirmed(CuratedAlbumReceipt(albumID: album.localIdentifier, assetIDs: request.assetIDs))
        }
        return .conflicting
    }

    /// Deletes only album containers proven to be direct children of Photo Curator year folders.
    /// Assets remain in the Photos library and in every other album that references them.
    func deleteManagedAlbums(withIDs requestedIDs: Set<String>, keeping albumID: String) async throws {
        let ids = requestedIDs.subtracting([albumID])
        guard !ids.isEmpty else { return }
        guard let root = findRootFolder() else { throw PublicationFailure.destinationConflict }

        var managed: [String: PHAssetCollection] = [:]
        let rootChildren = PHCollection.fetchCollections(in: root, options: nil)
        rootChildren.enumerateObjects { child, _, _ in
            guard let year = child as? PHCollectionList else { return }
            let yearChildren = PHCollection.fetchCollections(in: year, options: nil)
            yearChildren.enumerateObjects { collection, _, _ in
                guard let album = collection as? PHAssetCollection else { return }
                managed[album.localIdentifier] = album
            }
        }

        guard ids.allSatisfy({ managed[$0] != nil }) else {
            throw PublicationFailure.destinationConflict
        }
        let albums = ids.compactMap { managed[$0] }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest.deleteAssetCollections(albums as NSArray)
        }
    }

    // MARK: - Folder & Album Helpers

    private func findRootFolder() -> PHCollectionList? {
        let top = PHCollectionList.fetchTopLevelUserCollections(with: nil)
        var root: PHCollectionList?
        top.enumerateObjects { col, _, stop in
            if let list = col as? PHCollectionList, list.localizedTitle == self.rootFolderName {
                root = list
                stop.pointee = true
            }
        }
        return root
    }

    private func findOrCreateRootFolder() async throws -> PHCollectionList {
        if let existing = findRootFolder() { return existing }
        var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: self.rootFolderName)
            placeholderID = req.placeholderForCreatedCollectionList.localIdentifier
        }
        if let placeholderID {
            let fetched = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [placeholderID], options: nil)
            if let first = fetched.firstObject { return first }
        }
        if let root = findRootFolder() { return root }
        throw PublicationFailure.verificationPending
    }

    private func findYearFolder(year: String, in root: PHCollectionList) -> PHCollectionList? {
        let children = PHCollection.fetchCollections(in: root, options: nil)
        var yearList: PHCollectionList?
        children.enumerateObjects { col, _, stop in
            if let list = col as? PHCollectionList, list.localizedTitle == year {
                yearList = list
                stop.pointee = true
            }
        }
        return yearList
    }

    private func findOrCreateYearFolder(year: String, in root: PHCollectionList) async throws -> PHCollectionList {
        if let existing = findYearFolder(year: year, in: root) { return existing }
        var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let yearReq = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: year)
            let holder = yearReq.placeholderForCreatedCollectionList
            placeholderID = holder.localIdentifier
            if let rootReq = PHCollectionListChangeRequest(for: root) {
                rootReq.addChildCollections([holder] as NSArray)
            }
        }
        if let placeholderID {
            let fetched = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [placeholderID], options: nil)
            if let first = fetched.firstObject { return first }
        }
        if let yearList = findYearFolder(year: year, in: root) { return yearList }
        throw PublicationFailure.verificationPending
    }

    private func findAlbum(named title: String, in yearFolder: PHCollectionList) -> PHAssetCollection? {
        let children = PHCollection.fetchCollections(in: yearFolder, options: nil)
        var album: PHAssetCollection?
        children.enumerateObjects { col, _, stop in
            if let item = col as? PHAssetCollection, item.localizedTitle == title {
                album = item
                stop.pointee = true
            }
        }
        return album
    }

    // MARK: - Date & Title Formatting

    private func resolveYear(for request: CuratedPublicationRequest) -> String {
        if let date = request.date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy"
            return formatter.string(from: date)
        }
        // Fallback: check if title starts with YYYY-
        let prefix = String(request.title.prefix(4))
        if prefix.count == 4, let _ = Int(prefix) {
            return prefix
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: Date())
    }

    private func resolveAlbumTitle(for request: CuratedPublicationRequest) -> String {
        guard let date = request.date else { return request.title }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let datePrefix = formatter.string(from: date)
        if request.title.hasPrefix(datePrefix) {
            return request.title
        }
        return "\(datePrefix) \(request.title)"
    }

    private func requestAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current != .notDetermined { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }
}
