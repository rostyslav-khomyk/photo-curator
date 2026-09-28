import Foundation
import Photos

struct PhotoKitAlbumAdapter: CuratedAlbumAdapter, Sendable {
    static let shared = PhotoKitAlbumAdapter()
    let rootFolderName = "Photo Curator"
    /// Fallback Story folder when a Moment is not part of a Journey or Outing.
    static let ungroupedStoryFolderName = "Moments"

    init() {}

    func publish(_ request: CuratedPublicationRequest) async throws -> CuratedAlbumReceipt {
        try request.validate()
        let auth = await requestAuthorization()
        guard auth == .authorized || auth == .limited else {
            throw PublicationFailure.invalidRequest
        }

        let yearString = resolveYear(for: request)
        let storyFolderTitle = resolveStoryFolderTitle(for: request)
        let albumTitle = resolveAlbumTitle(for: request)

        var createdAlbumID: String?

        // Photo Curator / Year / Story (timeline-sorted) / Moment album
        let (rootFolder, createdRoot) = try await findOrCreateRootFolder()
        let (yearFolder, createdYear) = try await findOrCreateFolder(named: yearString, in: rootFolder)
        let (storyFolder, createdStory) = try await findOrCreateFolder(named: storyFolderTitle, in: yearFolder)

        let existingAlbum = findAlbum(named: albumTitle, in: storyFolder)

        try await PHPhotoLibrary.shared().performChanges {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: request.assetIDs, options: nil)
            let albumRequest: PHAssetCollectionChangeRequest

            if let existing = existingAlbum {
                albumRequest = PHAssetCollectionChangeRequest(for: existing)
                    ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
                createdAlbumID = existing.localIdentifier
            } else {
                let createAlbumReq = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
                let albumPlaceholder = createAlbumReq.placeholderForCreatedAssetCollection
                createdAlbumID = albumPlaceholder.localIdentifier

                if let storyReq = PHCollectionListChangeRequest(for: storyFolder) {
                    storyReq.addChildCollections([albumPlaceholder] as NSArray)
                }
                albumRequest = createAlbumReq
            }

            albumRequest.addAssets(assets)
        }

        guard let finalAlbumID = createdAlbumID ?? existingAlbum?.localIdentifier, !finalAlbumID.isEmpty else {
            throw PublicationFailure.verificationPending
        }

        var created = [String]()
        if createdRoot { created.append(rootFolder.localIdentifier) }
        if createdYear { created.append(yearFolder.localIdentifier) }
        if createdStory { created.append(storyFolder.localIdentifier) }
        if existingAlbum == nil { created.append(finalAlbumID) }
        return CuratedAlbumReceipt(albumID: finalAlbumID, assetIDs: request.assetIDs,
            rootFolderID: rootFolder.localIdentifier, yearFolderID: yearFolder.localIdentifier,
            storyFolderID: storyFolder.localIdentifier, createdContainerIDs: created)
    }

    func recover(_ request: CuratedPublicationRequest) async throws -> CuratedAlbumRecovery {
        try request.validate()
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard auth == .authorized || auth == .limited else { throw PublicationFailure.invalidRequest }

        let yearString = resolveYear(for: request)
        let storyFolderTitle = resolveStoryFolderTitle(for: request)
        let albumTitle = resolveAlbumTitle(for: request)

        guard let rootFolder = findRootFolder(),
              let yearFolder = findFolder(named: yearString, in: rootFolder),
              let storyFolder = findFolder(named: storyFolderTitle, in: yearFolder),
              let album = findAlbum(named: albumTitle, in: storyFolder) else { return .absent }

        let assets = PHAsset.fetchAssets(in: album, options: nil)
        var memberIDs: [String] = []
        assets.enumerateObjects { asset, _, _ in
            memberIDs.append(asset.localIdentifier)
        }

        if Set(memberIDs) == Set(request.assetIDs) {
            return .confirmed(CuratedAlbumReceipt(albumID: album.localIdentifier, assetIDs: request.assetIDs,
                rootFolderID: rootFolder.localIdentifier, yearFolderID: yearFolder.localIdentifier,
                storyFolderID: storyFolder.localIdentifier))
        }
        return .conflicting
    }

    /// Deletes only album containers proven to be under Photo Curator / Year / Story.
    func deleteManagedAlbums(withIDs requestedIDs: Set<String>, keeping albumID: String) async throws {
        let ids = requestedIDs.subtracting([albumID])
        guard !ids.isEmpty else { return }
        guard let root = findRootFolder() else { throw PublicationFailure.destinationConflict }

        var managed: [String: PHAssetCollection] = [:]
        let rootChildren = PHCollection.fetchCollections(in: root, options: nil)
        rootChildren.enumerateObjects { yearChild, _, _ in
            guard let year = yearChild as? PHCollectionList else { return }
            let yearChildren = PHCollection.fetchCollections(in: year, options: nil)
            yearChildren.enumerateObjects { storyChild, _, _ in
                if let album = storyChild as? PHAssetCollection {
                    // Legacy: Moment album directly under Year.
                    managed[album.localIdentifier] = album
                    return
                }
                guard let story = storyChild as? PHCollectionList else { return }
                let storyChildren = PHCollection.fetchCollections(in: story, options: nil)
                storyChildren.enumerateObjects { collection, _, _ in
                    guard let album = collection as? PHAssetCollection else { return }
                    managed[album.localIdentifier] = album
                }
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

    private func findOrCreateRootFolder() async throws -> (PHCollectionList, Bool) {
        if let existing = findRootFolder() { return (existing, false) }
        var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: self.rootFolderName)
            placeholderID = req.placeholderForCreatedCollectionList.localIdentifier
        }
        if let placeholderID {
            let fetched = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [placeholderID], options: nil)
            if let first = fetched.firstObject { return (first, true) }
        }
        if let root = findRootFolder() { return (root, true) }
        throw PublicationFailure.verificationPending
    }

    private func findFolder(named title: String, in parent: PHCollectionList) -> PHCollectionList? {
        let children = PHCollection.fetchCollections(in: parent, options: nil)
        var match: PHCollectionList?
        children.enumerateObjects { col, _, stop in
            if let list = col as? PHCollectionList, list.localizedTitle == title {
                match = list
                stop.pointee = true
            }
        }
        return match
    }

    private func findOrCreateFolder(named title: String, in parent: PHCollectionList) async throws -> (PHCollectionList, Bool) {
        if let existing = findFolder(named: title, in: parent) { return (existing, false) }
        var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: title)
            let holder = req.placeholderForCreatedCollectionList
            placeholderID = holder.localIdentifier
            if let parentReq = PHCollectionListChangeRequest(for: parent) {
                parentReq.addChildCollections([holder] as NSArray)
            }
        }
        if let placeholderID {
            let fetched = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [placeholderID], options: nil)
            if let first = fetched.firstObject { return (first, true) }
        }
        if let folder = findFolder(named: title, in: parent) { return (folder, true) }
        throw PublicationFailure.verificationPending
    }

    private func findAlbum(named title: String, in parent: PHCollectionList) -> PHAssetCollection? {
        let children = PHCollection.fetchCollections(in: parent, options: nil)
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
        let date = request.storyStart ?? request.date ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: date)
    }

    /// `yyyy-MM Story name` so folders sort by timeline occurrence within the year.
    private func resolveStoryFolderTitle(for request: CuratedPublicationRequest) -> String {
        let raw = (request.storyTitle ?? Self.ungroupedStoryFolderName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = raw.isEmpty ? Self.ungroupedStoryFolderName : String(raw.prefix(200))
        let date = request.storyStart ?? request.date
        guard let date else { return name }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        let prefix = formatter.string(from: date)
        if name.hasPrefix(prefix) { return name }
        return "\(prefix) \(name)"
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

extension PhotoKitAlbumAdapter: CuratorResetPhotos {
    func assetCounts() async throws -> PhotoLibraryAssetCounts {
        let all = PHAsset.fetchAssets(with: nil)
        let favorites = PHFetchOptions()
        favorites.predicate = NSPredicate(format: "favorite == YES")
        favorites.includeHiddenAssets = true
        return PhotoLibraryAssetCounts(assets: all.count,
            favorites: PHAsset.fetchAssets(with: favorites).count)
    }

    func verifyOwnership(of containers: [ManagedPhotoContainer]) async throws {
        let knownIDs = Set(containers.map(\.id))
        for container in containers where containerExists(container) {
            guard isInRecordedHierarchy(container) else { throw PublicationFailure.destinationConflict }
            if container.kind != .album {
                let list = PHCollectionList.fetchCollectionLists(
                    withLocalIdentifiers: [container.id], options: nil).firstObject
                let children = list.map { PHCollection.fetchCollections(in: $0, options: nil) }
                var childIDs = Set<String>()
                children?.enumerateObjects { child, _, _ in childIDs.insert(child.localIdentifier) }
                guard containsOnlyManagedContainers(childIDs, managedIDs: knownIDs) else {
                    throw PublicationFailure.destinationConflict
                }
            }
        }
    }

    func deleteContainers(_ containers: [ManagedPhotoContainer]) async throws {
        let existing = containers.filter(containerExists)
        try await verifyOwnership(of: existing)
        let albums = existing.filter { $0.kind == .album }.compactMap {
            PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [$0.id], options: nil).firstObject
        }
        // Delete deepest folders first: story, then year, then root.
        let lists = existing.filter { $0.kind != .album }
            .sorted { lhs, rhs in
                let order: [ManagedPhotoContainer.Kind: Int] = [.story: 0, .year: 1, .root: 2]
                return (order[lhs.kind] ?? 9) < (order[rhs.kind] ?? 9)
            }
            .compactMap {
                PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [$0.id], options: nil).firstObject
            }
        guard !albums.isEmpty || !lists.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            if !albums.isEmpty { PHAssetCollectionChangeRequest.deleteAssetCollections(albums as NSArray) }
            if !lists.isEmpty { PHCollectionListChangeRequest.deleteCollectionLists(lists as NSArray) }
        }
    }

    func containersAreAbsent(_ containers: [ManagedPhotoContainer]) async throws -> Bool {
        containers.allSatisfy { !containerExists($0) }
    }

    private func containerExists(_ container: ManagedPhotoContainer) -> Bool {
        switch container.kind {
        case .album:
            return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [container.id], options: nil).count == 1
        case .root, .year, .story:
            return PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [container.id], options: nil).count == 1
        }
    }

    private func isInRecordedHierarchy(_ container: ManagedPhotoContainer) -> Bool {
        switch container.kind {
        case .root:
            let top = PHCollectionList.fetchTopLevelUserCollections(with: nil)
            var found = false
            top.enumerateObjects { collection, _, stop in
                if collection.localIdentifier == container.id { found = true; stop.pointee = true }
            }
            return found
        case .year, .story, .album:
            guard let parentID = container.parentID,
                  let parent = PHCollectionList.fetchCollectionLists(
                    withLocalIdentifiers: [parentID], options: nil).firstObject else { return false }
            let children = PHCollection.fetchCollections(in: parent, options: nil)
            var found = false
            children.enumerateObjects { collection, _, stop in
                if collection.localIdentifier == container.id { found = true; stop.pointee = true }
            }
            return found
        }
    }
}
