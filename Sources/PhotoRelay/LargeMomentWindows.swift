import Foundation
import CryptoKit

/// Internal work units only. Their identifiers must never become catalog Moment IDs.
enum LargeMomentWindows {
    struct Window {
        let moment: PhotoMoment
        let ownedIDs: [String]
    }

    static func make(_ parent: PhotoMoment, size: Int = 256) throws -> [Window] {
        guard size >= 4, size <= 508, !parent.photos.isEmpty,
              Set(parent.photos.map(\.id)).count == parent.photos.count,
              parent.photos.allSatisfy({ !$0.id.isEmpty }) else {
            throw PublicationFailure.invalidRequest
        }
        let photos = parent.photos.sorted {
            $0.created == $1.created ? $0.id < $1.id : ($0.created ?? .distantPast) < ($1.created ?? .distantPast)
        }
        let generation = try AutomaticMomentSegmentation.fingerprint(parent)
        return stride(from: 0, to: photos.count, by: size).map { start in
            let end = min(start + size, photos.count)
            // Two neighbors on either side preserve four-photo boundary evidence.
            let members = Array(photos[max(0, start - 2)..<min(photos.count, end + 2)])
            let key = "large-window-v1|\(parent.id)|\(generation)|\(size)|\(start)"
            let id = "internal-" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            return Window(moment: PhotoMoment(id: id, start: members.first?.created ?? parent.start,
                                              end: members.last?.created ?? parent.end, photos: members),
                          ownedIDs: photos[start..<end].map(\.id))
        }
    }
}

/// Reuses validated, atomic records in a separate namespace, never the catalog store.
struct LargeMomentWindowStore {
    let root: URL
    let cache: DerivedCacheStore?

    init(root: URL, cache: DerivedCacheStore? = nil) {
        self.root = root
        self.cache = cache ?? (try? DerivedCacheStore(url: DerivedCacheStore.adjacentToLegacyDirectory(root)))
    }

    private var records: AutomaticMomentStore {
        AutomaticMomentStore(root: root.appendingPathComponent("internal-windows"), cache: cache,
                             namespace: .largeMomentWindows)
    }

    func save(_ record: AutomaticMomentRecord, for window: LargeMomentWindows.Window) throws {
        try records.save(record, for: window.moment)
    }

    func load(_ window: LargeMomentWindows.Window) throws -> AutomaticMomentRecord? {
        guard try completed(window) else { return nil }
        return try records.load(window.moment.id)
    }

    func invalidate(_ window: LargeMomentWindows.Window) throws {
        try records.discard(window.moment.id)
    }

    func project(_ parent: PhotoMoment) throws -> PhotoMoment {
        let windows = try LargeMomentWindows.make(parent)
        var finished = 0
        for window in windows {
            if try load(window)?.evidenceFingerprint != nil { finished += 1 }
        }
        var output = parent
        output.groupingState = finished == windows.count ? .conservative : .preparing
        output.groupingReason = (parent.continuityReason.map { $0 + " " } ?? "")
            + "Local evidence checked in \(finished) of \(windows.count) internal sections. "
            + "All \(parent.photos.count) photos remain in one collection. Internal scene findings do not establish a single venue or event."
        return output
    }

    func completed(_ window: LargeMomentWindows.Window) throws -> Bool {
        guard let record = try records.load(window.moment.id) else { return false }
        return record.fingerprint == (try AutomaticMomentSegmentation.fingerprint(window.moment))
            && Set(record.segments.flatMap(\.members)) == Set(window.moment.photos.map(\.id))
    }

    func next(in windows: [LargeMomentWindows.Window]) throws -> LargeMomentWindows.Window? {
        for window in windows {
            try Task.checkCancellation()
            if try !completed(window) { return window }
        }
        return nil
    }
}
