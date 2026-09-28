import Foundation
import Photos

enum ExpectedLibraryEffect: Equatable, Sendable {
    case update
    case removal
}

struct LibraryChangeBatch: Equatable, Sendable {
    let updated: Set<String>
    let removed: Set<String>
    let requiresVerification: Bool
    let hasMore: Bool
    let changeToken: Data?

    static let empty = Self(updated: [], removed: [], requiresVerification: false,
                            hasMore: false, changeToken: nil)
}

struct LibraryChangeBuffer {
    private(set) var updated = Set<String>()
    private(set) var removed = Set<String>()
    private(set) var requiresVerification = false
    private var expected: [String: (operation: UUID, effect: ExpectedLibraryEffect, expires: Date)] = [:]

    mutating func expect(operation: UUID, assetIDs: Set<String>, effect: ExpectedLibraryEffect,
                         expires: Date = Date().addingTimeInterval(30)) {
        for id in assetIDs { expected[id] = (operation, effect, expires) }
    }

    mutating func cancel(operation: UUID) {
        expected = expected.filter { $0.value.operation != operation }
    }

    mutating func receive(updated newUpdates: Set<String>, removed newRemovals: Set<String>,
                          full: Bool, now: Date = Date()) {
        expected = expected.filter { $0.value.expires > now }
        if full { requiresVerification = true }

        let externalUpdates = newUpdates.filter { id in
            guard let item = expected[id], item.effect == .update else { return true }
            expected[id] = nil
            return false
        }
        let externalRemovals = newRemovals.filter { id in
            guard let item = expected[id], item.effect == .removal else { return true }
            expected[id] = nil
            return false
        }

        removed.subtract(externalUpdates)
        updated.formUnion(externalUpdates)
        updated.subtract(externalRemovals)
        removed.formUnion(externalRemovals)
    }

    mutating func drain(limit: Int) -> LibraryChangeBatch {
        let boundedLimit = max(1, limit)
        let removals = Set(removed.sorted().prefix(boundedLimit))
        removed.subtract(removals)
        let remaining = boundedLimit - removals.count
        let updates = Set(updated.sorted().prefix(remaining))
        updated.subtract(updates)
        let verification = requiresVerification
        requiresVerification = false
        return LibraryChangeBatch(updated: updates, removed: removals,
                                  requiresVerification: verification,
                                  hasMore: !updated.isEmpty || !removed.isEmpty || requiresVerification,
                                  changeToken: nil)
    }
}

private final class PhotoLibraryChangeSource: NSObject, PHPhotoLibraryChangeObserver {
    private let lock = NSLock()
    private var assets: PHFetchResult<PHAsset>
    private let changed: @Sendable (Set<String>, Set<String>, Bool) -> Void

    init(changed: @escaping @Sendable (Set<String>, Set<String>, Bool) -> Void) {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.includeHiddenAssets = false
        assets = PHAsset.fetchAssets(with: options)
        self.changed = changed
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        lock.lock()
        defer { lock.unlock() }
        guard let details = changeInstance.changeDetails(for: assets) else { return }
        assets = details.fetchResultAfterChanges
        guard details.hasIncrementalChanges else {
            changed([], [], true)
            return
        }
        let updated = Set((details.insertedObjects + details.changedObjects).map(\.localIdentifier))
        let removed = Set(details.removedObjects.map(\.localIdentifier))
        guard !updated.isEmpty || !removed.isEmpty else { return }
        changed(updated, removed, false)
    }
}

actor LibraryCoordinator {
    private var buffer = LibraryChangeBuffer()
    private var source: PhotoLibraryChangeSource?
    private var committedToken: PHPersistentChangeToken?
    private var pendingToken: Data?
    private let wake: @Sendable () -> Void

    init(wake: @escaping @Sendable () -> Void) { self.wake = wake }

    func start(since tokenData: Data?) {
        guard source == nil else { return }
        committedToken = tokenData.flatMap(PhotoLibraryChangeToken.decode)
        let listener = PhotoLibraryChangeSource { [weak self] updated, removed, full in
            Task { await self?.receive(updated: updated, removed: removed, full: full) }
        }
        source = listener
        PHPhotoLibrary.shared().register(listener)
        if committedToken == nil {
            pendingToken = PhotoLibraryChangeToken.capture()
            wake()
        } else {
            refreshPersistentChanges()
        }
    }

    func stop() {
        guard let source else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(source)
        self.source = nil
    }

    func expect(operation: UUID, assetIDs: Set<String>, effect: ExpectedLibraryEffect) {
        buffer.expect(operation: operation, assetIDs: assetIDs, effect: effect)
    }

    func cancelExpected(operation: UUID) { buffer.cancel(operation: operation) }

    func drain(limit: Int = 100) -> LibraryChangeBatch {
        let batch = buffer.drain(limit: limit)
        let token = !batch.hasMore && !batch.requiresVerification ? pendingToken : nil
        return LibraryChangeBatch(updated: batch.updated, removed: batch.removed,
                                  requiresVerification: batch.requiresVerification,
                                  hasMore: batch.hasMore, changeToken: token)
    }

    func commit(changeToken data: Data) {
        guard let token = PhotoLibraryChangeToken.decode(data) else { return }
        committedToken = token
        if pendingToken == data { pendingToken = nil }
    }

    func resetToCurrentToken() {
        committedToken = PHPhotoLibrary.shared().currentChangeToken
        pendingToken = nil
    }

    private func receive(updated: Set<String>, removed: Set<String>, full: Bool) {
        if committedToken != nil {
            refreshPersistentChanges()
        } else {
            buffer.receive(updated: updated, removed: removed, full: full)
            pendingToken = PhotoLibraryChangeToken.capture()
        }
        wake()
    }

    private func refreshPersistentChanges() {
        guard let committedToken else { return }
        let fetchToken = pendingToken.flatMap(PhotoLibraryChangeToken.decode) ?? committedToken
        do {
            let changes = try PHPhotoLibrary.shared().fetchPersistentChanges(since: fetchToken)
            var updated = Set<String>()
            var removed = Set<String>()
            var latest = fetchToken
            for change in changes {
                latest = change.changeToken
                let details = try change.changeDetails(for: .asset)
                updated.formUnion(details.insertedLocalIdentifiers)
                updated.formUnion(details.updatedLocalIdentifiers)
                removed.formUnion(details.deletedLocalIdentifiers)
            }
            buffer.receive(updated: updated, removed: removed, full: false)
            pendingToken = PhotoLibraryChangeToken.encode(latest)
        } catch {
            buffer.receive(updated: [], removed: [], full: true)
            pendingToken = nil
        }
    }
}
