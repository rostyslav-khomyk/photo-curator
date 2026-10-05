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

        // Photo Curator / Year / Story / Moment album, each placed by date rather than by name.
        let (rootFolder, createdRoot) = try await findOrCreateRootFolder()
        let (yearFolder, createdYear) = try await findOrCreateFolder(
            named: yearString, in: rootFolder, date: PhotosAlbumNaming.yearStart(yearString))
        let (storyFolder, createdStory) = try await findOrCreateFolder(
            named: storyFolderTitle, in: yearFolder, date: request.storyStart ?? request.date)

        let existingAlbum = findAlbum(named: albumTitle, in: storyFolder)
        let storySnapshot = children(of: storyFolder)
        let albumIndex = existingAlbum == nil ? insertionIndex(for: request.date, in: storyFolder) : 0

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
                self.insert(albumPlaceholder, into: storyFolder, snapshot: storySnapshot, at: albumIndex)
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

    private func findOrCreateFolder(named title: String, in parent: PHCollectionList,
                                    date: Date?) async throws -> (PHCollectionList, Bool) {
        if let existing = findFolder(named: title, in: parent) { return (existing, false) }
        let snapshot = children(of: parent)
        let index = insertionIndex(for: date, in: parent)
        var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: title)
            let holder = req.placeholderForCreatedCollectionList
            placeholderID = holder.localIdentifier
            self.insert(holder, into: parent, snapshot: snapshot, at: index)
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
        PhotosAlbumNaming.yearTitle(request.storyStart ?? request.date ?? Date())
    }

    private func resolveStoryFolderTitle(for request: CuratedPublicationRequest) -> String {
        PhotosAlbumNaming.storyFolderTitle(request.storyTitle)
    }

    private func resolveAlbumTitle(for request: CuratedPublicationRequest) -> String {
        PhotosAlbumNaming.albumTitle(request.title, date: request.date)
    }

    // MARK: - Chronological placement

    /// Earliest capture date under a container. Year folders sort by their title year.
    private func sortDate(of collection: PHCollection) -> Date? {
        if let album = collection as? PHAssetCollection {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            options.fetchLimit = 1
            return PHAsset.fetchAssets(in: album, options: options).firstObject?.creationDate
        }
        guard let list = collection as? PHCollectionList else { return nil }
        if let year = PhotosAlbumNaming.yearStart(list.localizedTitle) { return year }
        var earliest: Date?
        PHCollection.fetchCollections(in: list, options: nil).enumerateObjects { child, _, _ in
            guard let date = self.sortDate(of: child) else { return }
            earliest = earliest.map { min($0, date) } ?? date
        }
        return earliest
    }

    private func children(of parent: PHCollectionList) -> PHFetchResult<PHCollection> {
        PHCollection.fetchCollections(in: parent, options: nil)
    }

    private func insertionIndex(for date: Date?, in parent: PHCollectionList) -> Int {
        var dates: [Date?] = []
        children(of: parent).enumerateObjects { child, _, _ in dates.append(self.sortDate(of: child)) }
        return PhotosAlbumNaming.chronologicalIndex(for: date, among: dates)
    }

    /// Must run inside `performChanges`. Falls back to append when Photos refuses the ordered request.
    private func insert(_ placeholder: PHObjectPlaceholder, into parent: PHCollectionList,
                        snapshot: PHFetchResult<PHCollection>, at index: Int) {
        if let ordered = PHCollectionListChangeRequest(for: parent, childCollections: snapshot) {
            ordered.insertChildCollections([placeholder] as NSArray,
                                           at: IndexSet(integer: min(index, snapshot.count)))
        } else if let request = PHCollectionListChangeRequest(for: parent) {
            request.addChildCollections([placeholder] as NSArray)
        }
    }

    // MARK: - Legacy naming migration

    /// Renames `yyyy-MM Story` / `yyyy-MM-dd Moment` containers Photo Curator created and
    /// re-sorts managed folders by date. Containers the app cannot prove it created stay as they are.
    func migrateLegacyNames(managedIDs: Set<String>) async throws {
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard auth == .authorized || auth == .limited, let root = findRootFolder() else { return }
        var albumRenames: [(PHAssetCollection, String)] = []
        var folderRenames: [(PHCollectionList, String)] = []
        var managedParents: [PHCollectionList] = managedIDs.contains(root.localIdentifier) ? [root] : []
        children(of: root).enumerateObjects { yearChild, _, _ in
            guard let year = yearChild as? PHCollectionList else { return }
            if managedIDs.contains(year.localIdentifier) { managedParents.append(year) }
            var siblingNames: [String] = []
            self.children(of: year).enumerateObjects { child, _, _ in
                siblingNames.append(child.localizedTitle ?? "")
            }
            var taken = Set(siblingNames.map { $0.lowercased() })
            self.children(of: year).enumerateObjects { storyChild, _, _ in
                guard let story = storyChild as? PHCollectionList else { return }
                let managedStory = managedIDs.contains(story.localIdentifier)
                if managedStory { managedParents.append(story) }
                if managedStory, let legacy = PhotosAlbumNaming.legacyStoryFolder(story.localizedTitle) {
                    var name = PhotosAlbumNaming.storyFolderTitle(legacy.title)
                    if taken.contains(name.lowercased()) {
                        name = PhotosAlbumNaming.disambiguatedStoryTitle(name, start: legacy.month)
                    }
                    taken.insert(name.lowercased())
                    folderRenames.append((story, name))
                }
                self.children(of: story).enumerateObjects { albumChild, _, _ in
                    guard let album = albumChild as? PHAssetCollection,
                          managedIDs.contains(album.localIdentifier),
                          let legacy = PhotosAlbumNaming.legacyAlbum(album.localizedTitle) else { return }
                    albumRenames.append((album, PhotosAlbumNaming.albumTitle(legacy.title, date: legacy.date)))
                }
            }
        }
        if !albumRenames.isEmpty || !folderRenames.isEmpty {
            try await PHPhotoLibrary.shared().performChanges {
                for (album, title) in albumRenames {
                    PHAssetCollectionChangeRequest(for: album)?.title = title
                }
                for (folder, title) in folderRenames {
                    PHCollectionListChangeRequest(for: folder)?.title = title
                }
            }
        }
        for parent in managedParents {
            let snapshot = children(of: parent)
            var dates: [Date?] = []
            snapshot.enumerateObjects { child, _, _ in dates.append(self.sortDate(of: child)) }
            let moves = PhotosAlbumNaming.chronologicalMoves(dates)
            guard !moves.isEmpty else { continue }
            try await PHPhotoLibrary.shared().performChanges {
                guard let request = PHCollectionListChangeRequest(for: parent, childCollections: snapshot) else { return }
                for move in moves {
                    request.moveChildCollections(at: IndexSet(integer: move.from), to: move.to)
                }
            }
        }
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

/// Names for `Photo Curator / Year / Story / Moment`. Order comes from placement, not names.
/// Album lookup is by title, so every name here must be deterministic (fixed locale).
enum PhotosAlbumNaming {
    static let ungroupedStoryFolderName = PhotoKitAlbumAdapter.ungroupedStoryFolderName
    static let separator = " · "

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    static func yearTitle(_ date: Date) -> String {
        formatter("yyyy").string(from: date)
    }

    /// January 1 of a four-digit year folder title.
    static func yearStart(_ title: String?) -> Date? {
        guard let title, title.count == 4, let year = Int(title), (1800...3000).contains(year) else { return nil }
        return Calendar.current.date(from: DateComponents(year: year, month: 1, day: 1))
    }

    static func storyFolderTitle(_ storyTitle: String?) -> String {
        let raw = (storyTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? ungroupedStoryFolderName : String(raw.prefix(200))
    }

    /// Two Stories with one title in the same year get their start month: `Journey to Bucharest · Jul`.
    static func disambiguatedStoryTitle(_ title: String, start: Date) -> String {
        title + separator + formatter("MMM").string(from: start)
    }

    /// `Lake Garda evening · 16 Jul`. The year lives in the folder above.
    static func albumTitle(_ title: String, date: Date?) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let date else { return trimmed }
        let suffix = separator + formatter("d MMM").string(from: date)
        return trimmed.hasSuffix(suffix) ? trimmed : trimmed + suffix
    }

    /// `2022-07-16 Lake Garda evening` → title and day.
    static func legacyAlbum(_ name: String?) -> (title: String, date: Date)? {
        legacy(name, format: "yyyy-MM-dd", length: 10).map { ($0.rest, $0.date) }
    }

    /// `2022-07 Journey through Italy` → title and month.
    static func legacyStoryFolder(_ name: String?) -> (title: String, month: Date)? {
        legacy(name, format: "yyyy-MM", length: 7).map { ($0.rest, $0.date) }
    }

    private static func legacy(_ name: String?, format: String, length: Int) -> (rest: String, date: Date)? {
        guard let name, name.count > length + 1 else { return nil }
        let prefix = String(name.prefix(length))
        let remainder = name.dropFirst(length)
        guard remainder.first == " ", let date = formatter(format).date(from: prefix) else { return nil }
        let rest = remainder.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : (rest, date)
    }

    /// Insert before the first sibling that starts later. Undated siblings sort last.
    static func chronologicalIndex(for date: Date?, among siblings: [Date?]) -> Int {
        guard let date else { return siblings.count }
        return siblings.firstIndex { sibling in sibling.map { $0 > date } ?? true } ?? siblings.count
    }

    /// Sequential moves that stable-sort siblings by date, undated last.
    /// Each `to` is valid both before and after removing the moved item because `to <= from`.
    static func chronologicalMoves(_ dates: [Date?]) -> [(from: Int, to: Int)] {
        let target = dates.indices.sorted { lhs, rhs in
            switch (dates[lhs], dates[rhs]) {
            case let (l?, r?): return l != r ? l < r : lhs < rhs
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs < rhs
            }
        }
        var current = Array(dates.indices)
        var moves: [(from: Int, to: Int)] = []
        for (position, item) in target.enumerated() {
            guard let from = current.firstIndex(of: item), from != position else { continue }
            moves.append((from, position))
            current.remove(at: from)
            current.insert(item, at: position)
        }
        return moves
    }
}
