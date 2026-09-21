import AppKit
import Combine
import CoreGraphics
import Photos
import ServiceManagement
import CryptoKit

struct CuratorBatch {
    let scanned: Int
    let total: Int
    let finished: Bool
}

enum MomentPreparationStep: Equatable {
    case changed
    case presentationChanged(String)
    case scanning
    case caughtUp
}

actor CuratorWorker {
    private let url: URL
    private var store: CuratorStore?
    private var fetch: PHFetchResult<PHAsset>?
    private var cursor = 0
    private var generation = ""
    private var fullScan = false
    private var textCandidates: [IndexedPhoto] = []
    private var textCursor = 0
    private var textScope: DateInterval?
    private var textScanStarted = false
    private var captionGroups: [PhotoMoment]?
    private var captionScope: DateInterval?
    private var captionCursor = 0
    private var captionReviewRevision = -1
    private var captionProtection = MomentGroupingProtection()
    private var captionRemaining = 0
    private var captionSweepChanged = false
    private var metadataGeneration = 0
    private var continuityPairs: [String: [MomentContinuityPair]] = [:]
    private var largeWindowCursor: [String: Int] = [:]
    private var largeWindowRemaining: [String: Int] = [:]
    private var largeWindowScanPending = false
    private lazy var context = BackgroundMomentContext(root: url.deletingLastPathComponent().appendingPathComponent("background-context"),
        textDirectory: url.deletingLastPathComponent().appendingPathComponent("text-evidence"))

    private var textStore: MomentTextEvidenceStore {
        MomentTextEvidenceStore(directory: url.deletingLastPathComponent().appendingPathComponent("text-evidence"))
    }

    private var checkpointStore: PhotoLibraryCheckpointStore {
        PhotoLibraryCheckpointStore(url: url.deletingLastPathComponent().appendingPathComponent("photo-library-checkpoint.json"))
    }

    func startupRequiresFullReconciliation(indexedCount: Int, now: Date = Date()) -> Bool {
        // Authorization can be transiently unavailable immediately after an ad-hoc
        // development rebuild. Keep a populated index and probe once access settles.
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            return indexedCount == 0
        }
        let current = PhotoLibraryFingerprint.current()
        guard let checkpoint = checkpointStore.load() else {
            // One-time migration for catalogs completed before checkpoints existed.
            // A later age-based verification still checks for same-count offline edits.
            guard indexedCount > 0, indexedCount == current.count else { return true }
            try? checkpointStore.save(PhotoLibraryCheckpoint(fingerprint: current, fullyVerifiedAt: now))
            return false
        }
        return checkpoint.requiresFullReconciliation(current: current, now: now)
    }

    func refreshCheckpointFingerprint() throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        try checkpointStore.updateFingerprint(.current())
    }

    @discardableResult
    func reconcileEditedAsset(_ assetID: String) throws -> Bool {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = result.firstObject, !asset.isHidden else {
            try database().deletePhotos(ids: [assetID])
            return true
        }
        let photo = IndexedPhoto(id: asset.localIdentifier, created: asset.creationDate,
            modified: asset.modificationDate, latitude: asset.location?.coordinate.latitude,
            longitude: asset.location?.coordinate.longitude, favorite: asset.isFavorite,
            width: asset.pixelWidth, height: asset.pixelHeight,
            similarityCategory: asset.mediaSubtypes.contains(.photoScreenshot) ? .screenshots : .photos)
        return try database().updatePhoto(photo)
    }

    func removeDeletedAsset(_ assetID: String) throws { try database().deletePhotos(ids: [assetID]) }
    func maintainStorage() throws { try database().maintain() }

    func indexedPhotoCount() throws -> Int { try database().counts().total }

    func prioritizeAnalysis(_ photos: [IndexedPhoto]) throws {
        let db = try database()
        for photo in photos {
            try db.enqueueAnalysis(asset: photo.id, revision: photo.analysisRevision,
                                   analyzer: CuratorVisionAnalyzer.version, priority: 100)
        }
    }

    private var automaticStore: AutomaticMomentStore {
        AutomaticMomentStore(root: url.deletingLastPathComponent().appendingPathComponent("automatic-moments"))
    }

    private var continuityStore: MomentContinuityStore {
        MomentContinuityStore(root: url.deletingLastPathComponent().appendingPathComponent("event-continuity"))
    }

    private func continuityProtection(_ moments: [PhotoMoment], protection: MomentGroupingProtection) throws -> Set<String> {
        var ids = protection.ids
        if !ids.isEmpty {
            for moment in moments {
                if try automaticStore.load(moment.id)?.segments.contains(where: { protection.ids.contains($0.id) }) == true {
                    ids.insert(moment.id)
                }
            }
        }
        return ids
    }

    private func prepareContinuity(_ pair: MomentContinuityPair, reviewRevision: Int) async throws -> Bool {
        let generation = metadataGeneration
        var labels: [String: [String]] = [:], text: [String: [PhotoTextLine]] = [:], results: [String: CuratorVisionResult] = [:]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var digest = SHA256()
        for photo in pair.photos.sorted(by: { $0.id < $1.id }) {
            try Task.checkCancellation()
            guard let data = try database().analysisResult(asset: photo.id, revision: photo.analysisRevision, analyzer: CuratorVisionAnalyzer.version),
                  let result = try? JSONDecoder().decode(CuratorVisionResult.self, from: data), result.version == CuratorVisionAnalyzer.version,
                  let clues = await context.cachedLabels(photo), let ocr = await textStore.cached(photo) else { return false }
            labels[photo.id] = clues; text[photo.id] = ocr.lines; results[photo.id] = result
            digest.update(data: try encoder.encode(photo.id))
            digest.update(data: try encoder.encode(result))
            digest.update(data: try encoder.encode(clues.sorted()))
            digest.update(data: try encoder.encode(ocr))
        }
        let signature = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let previous = try continuityStore.load(pair)
        guard previous?.evidenceFingerprint != signature else { return false }
        let record = try MomentContinuity.propose(pair, labels: labels, text: text, results: results, evidenceFingerprint: signature) { a, b in
            guard let lhs = results[a], let rhs = results[b] else { return nil }
            return try? lhs.distance(to: rhs)
        }
        try Task.checkCancellation()
        guard generation == metadataGeneration,
              try GroupReviewStore(url: url.deletingLastPathComponent().appendingPathComponent("group-review.json")).load().revision == reviewRevision else { return false }
        try continuityStore.save(record, pair: pair)
        return (previous?.joins ?? false) != record.joins || (record.joins && previous?.evidenceFingerprint != signature)
    }

    private func baseMoments(protection: MomentGroupingProtection, reviews: GroupReviewArchive) throws -> [PhotoMoment] {
        MomentCatalogGrouping.build(try database().photos(in: DateInterval(start: .distantPast, end: .distantFuture)),
                                   reviews: reviews, protection: protection)
    }

    /// Shared catalog projection for the UI and headless tests. Never calls PhotoKit.
    func preparedCatalog(protection: MomentGroupingProtection) throws -> [PhotoMoment] {
        let reviews = try GroupReviewStore(url: url.deletingLastPathComponent().appendingPathComponent("group-review.json")).load()
        let base = try baseMoments(protection: protection, reviews: reviews)
        return try continuityStore.apply(base, protected: continuityProtection(base, protection: protection))
            .flatMap {
                try continuityStore.apply(automaticStore.apply($0, protected: protection.ids), protected: protection.ids)
            }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start > $1.start }
    }

    private func prepareLargeMoment(_ moment: PhotoMoment, reviewRevision: Int) async throws -> Bool {
        let windows = try LargeMomentWindows.make(moment)
        let key = windows[0].moment.id
        let index = (largeWindowCursor[key] ?? 0) % windows.count
        let window = windows[index]
        largeWindowCursor[key] = (index + 1) % windows.count
        let remaining = largeWindowRemaining[key, default: windows.count]
        largeWindowRemaining[key] = (remaining == 0 ? windows.count : remaining) - 1
        largeWindowScanPending = largeWindowRemaining[key, default: 0] > 0
        let checkpoints = LargeMomentWindowStore(root: automaticStore.root)
        let generation = metadataGeneration
        var labels: [String: [String]] = [:], text: [String: [PhotoTextLine]] = [:]
        var results: [String: CuratorVisionResult] = [:]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var digest = SHA256()
        for photo in window.moment.photos {
            try Task.checkCancellation()
            guard let data = try database().analysisResult(asset: photo.id, revision: photo.analysisRevision, analyzer: CuratorVisionAnalyzer.version),
                  let result = try? JSONDecoder().decode(CuratorVisionResult.self, from: data),
                  result.version == CuratorVisionAnalyzer.version,
                  let clues = await context.cachedLabels(photo), let ocr = await textStore.cached(photo) else {
                try Task.checkCancellation()
                guard generation == metadataGeneration,
                      try GroupReviewStore(url: url.deletingLastPathComponent().appendingPathComponent("group-review.json")).load().revision == reviewRevision else { return false }
                let existed = try checkpoints.completed(window)
                try checkpoints.invalidate(window)
                return existed
            }
            labels[photo.id] = clues; text[photo.id] = ocr.lines; results[photo.id] = result
            digest.update(data: try encoder.encode(photo.id))
            digest.update(data: try encoder.encode(result))
            digest.update(data: try encoder.encode(clues.sorted()))
            digest.update(data: try encoder.encode(ocr))
        }
        let signature = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard try checkpoints.load(window)?.evidenceFingerprint != signature else { return false }
        var record = try AutomaticMomentSegmentation.propose(window.moment, labels: labels, text: text) { a, b in
            guard let lhs = results[a], let rhs = results[b] else { return nil }
            return try? lhs.distance(to: rhs)
        }
        record.evidenceFingerprint = signature
        try Task.checkCancellation()
        guard generation == metadataGeneration,
              try GroupReviewStore(url: url.deletingLastPathComponent().appendingPathComponent("group-review.json")).load().revision == reviewRevision else { return false }
        try checkpoints.save(record, for: window)
        return true
    }

    private func prepareGrouping(_ moment: PhotoMoment, protection: MomentGroupingProtection, reviewRevision: Int) async throws -> Bool {
        largeWindowScanPending = false
        guard moment.groupingState != .reviewed, !protection.ids.contains(moment.id),
              !moment.photos.isEmpty else { return false }
        if moment.photos.count > 512 {
            if try automaticStore.load(moment.id)?.segments.contains(where: { protection.ids.contains($0.id) }) == true { return false }
            return try await prepareLargeMoment(moment, reviewRevision: reviewRevision)
        }
        let fingerprint = try AutomaticMomentSegmentation.fingerprint(moment)
        if let previous = try automaticStore.load(moment.id),
           previous.fingerprint == fingerprint || previous.segments.contains(where: { protection.ids.contains($0.id) }) {
            return false
        }
        let generation = metadataGeneration
        let db = try database()
        var labels: [String: [String]] = [:]
        var text: [String: [PhotoTextLine]] = [:]
        var results: [String: CuratorVisionResult] = [:]
        for photo in moment.photos {
            try Task.checkCancellation()
            guard let data = try db.analysisResult(asset: photo.id, revision: photo.analysisRevision, analyzer: CuratorVisionAnalyzer.version),
                  let result = try? JSONDecoder().decode(CuratorVisionResult.self, from: data),
                  result.version == CuratorVisionAnalyzer.version,
                  let clues = await context.cachedLabels(photo),
                  let ocr = await textStore.cached(photo) else { return false }
            results[photo.id] = result
            labels[photo.id] = clues
            text[photo.id] = ocr.lines
        }
        try Task.checkCancellation()
        guard generation == metadataGeneration else { return false }
        let record = try AutomaticMomentSegmentation.propose(moment, labels: labels, text: text) { a, b in
            guard let lhs = results[a], let rhs = results[b] else { return nil }
            return try? lhs.distance(to: rhs)
        }
        try automaticStore.save(record, for: moment)
        return true
    }

    func prepareText(_ photo: IndexedPhoto, image: CGImage) async throws {
        let store = textStore
        if await store.cached(photo) == nil {
            let lines = try await store.recognize(image)
            _ = try await store.save(lines, for: photo)
        }
        try await context.capture(photo, image: image)
    }

    func prepareMoments(range: DateInterval?, protection: MomentGroupingProtection,
                        model: LocalNarrativeModel = AppleLocalNarrativeModel()) async throws -> MomentPreparationStep {
        let reviews = try GroupReviewStore(url: url.deletingLastPathComponent().appendingPathComponent("group-review.json")).load()
        if captionGroups == nil || captionScope != range || captionReviewRevision != reviews.revision || captionProtection != protection {
            // Full scope first, then prioritize intersecting groups without clipping membership.
            let base = try baseMoments(protection: protection, reviews: reviews)
            let protected = try continuityProtection(base, protection: protection)
            continuityPairs = [:]
            for pair in MomentContinuity.pairs(base, protected: protected) {
                for id in [pair.earlier.id, pair.later.id, pair.id] { continuityPairs[id, default: []].append(pair) }
            }
            let all = try continuityStore.apply(base, protected: protected)
            captionGroups = range.map { interval in all.filter { $0.photos.contains { photo in
                photo.created.map { $0 >= interval.start && $0 < interval.end } ?? false
            } } } ?? all
            captionScope = range
            captionReviewRevision = reviews.revision
            captionCursor = 0
            captionRemaining = captionGroups?.count ?? 0
            captionSweepChanged = false
            captionProtection = protection
        }
        guard let groups = captionGroups, !groups.isEmpty else { return .caughtUp }
        if captionRemaining == 0 { captionRemaining = groups.count; captionSweepChanged = false }
        // Bounded sweep across the entire index, independent of the displayed page.
        for _ in 0..<min(4, captionRemaining) {
            try Task.checkCancellation()
            let moment = groups[captionCursor % groups.count]
            for pair in continuityPairs[moment.id] ?? [] {
                if try await prepareContinuity(pair, reviewRevision: reviews.revision) {
                    captionGroups = nil
                    return .changed
                }
            }
            let grouped = try await prepareGrouping(moment, protection: protection, reviewRevision: reviews.revision)
            if largeWindowScanPending { captionSweepChanged = true }
            let children = try automaticStore.apply(moment, protected: protection.ids)
            // Reconcile adjacent scene sections within the same parent visit, using the
            // same evidence gates as cross-gap continuity, never similarity alone.
            for pair in MomentContinuity.pairs(children, protected: protection.ids) {
                if try await prepareContinuity(pair, reviewRevision: reviews.revision) {
                    captionSweepChanged = true
                    return .changed
                }
            }
            for prepared in try continuityStore.apply(children, protected: protection.ids) {
                if prepared.groupingKind == .unresolved { continue }
                if try await context.prepare(prepared, model: model) {
                    captionSweepChanged = true
                    // Finish this collection's children before moving back through history.
                    return .presentationChanged(prepared.id)
                }
            }
            captionCursor += 1
            captionRemaining -= 1
            if grouped { captionSweepChanged = true; return .changed }
        }
        return captionRemaining == 0 && !captionSweepChanged ? .caughtUp : .scanning
    }

    func nextTextCandidate(range: DateInterval?) async throws -> IndexedPhoto? {
        if !textScanStarted || textScope != range {
            textCandidates = try database().photos(in: range ?? DateInterval(start: .distantPast, end: .distantFuture)).reversed()
            textCursor = 0
            textScope = range
            textScanStarted = true
        }
        let store = textStore
        while textCursor < textCandidates.count {
            try Task.checkCancellation()
            let photo = textCandidates[textCursor]
            textCursor += 1
            if await store.cached(photo) == nil { return photo }
            if !(await context.hasLabels(photo)) { return photo }
        }
        return nil
    }

    init(url: URL) { self.url = url }

    private func database() throws -> CuratorStore {
        if let store { return store }
        let opened = try CuratorStore(url: url)
        store = opened
        return opened
    }

    func batch(range: DateInterval?, restart: Bool, limit: Int = 300) throws -> CuratorBatch {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw NSError(domain: "PhotoRelay.Curator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Full Photos access is required to index the library. The existing index was kept."])
        }
        if restart || fetch == nil {
            metadataGeneration += 1
            textScanStarted = false
            captionGroups = nil
            let options = PHFetchOptions()
            var predicates = [NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)]
            if let range {
                predicates.append(NSPredicate(format: "creationDate >= %@ AND creationDate < %@", range.start as NSDate, range.end as NSDate))
            }
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.includeHiddenAssets = false
            fetch = PHAsset.fetchAssets(with: options)
            cursor = 0
            generation = UUID().uuidString
            fullScan = range == nil
        }
        guard let fetch else { return CuratorBatch(scanned: 0, total: 0, finished: true) }
        let end = min(cursor + max(25, min(limit, 2_000)), fetch.count)
        let photos = (cursor..<end).map { index -> IndexedPhoto in
            let asset = fetch.object(at: index)
            return IndexedPhoto(id: asset.localIdentifier, created: asset.creationDate,
                                modified: asset.modificationDate, latitude: asset.location?.coordinate.latitude,
                                longitude: asset.location?.coordinate.longitude, favorite: asset.isFavorite,
                                width: asset.pixelWidth, height: asset.pixelHeight,
                                similarityCategory: asset.mediaSubtypes.contains(.photoScreenshot) ? .screenshots : .photos)
        }
        let db = try database()
        try db.save(photos, generation: generation)
        captionGroups = nil
        metadataGeneration += 1
        for photo in photos {
            try db.enqueueAnalysis(asset: photo.id, revision: photo.analysisRevision, analyzer: CuratorVisionAnalyzer.version)
        }
        cursor = end
        let done = cursor == fetch.count
        // A suddenly empty/unavailable library must not erase a previous index.
        if done && fullScan && fetch.count > 0 {
            try db.finishFullScan(generation: generation)
            try checkpointStore.save(PhotoLibraryCheckpoint(fingerprint: .current(), fullyVerifiedAt: Date()))
        }
        return CuratorBatch(scanned: cursor, total: fetch.count, finished: done)
    }

    func savedMoments() throws -> [PhotoMoment] {
        try MomentsCatalog.load(from: url.deletingLastPathComponent().appendingPathComponent("moments-catalog.json"))?.moments ?? []
    }

    func markPublished(momentID: String, albumID: String, date: Date) throws {
        let catalogURL = url.deletingLastPathComponent().appendingPathComponent("moments-catalog.json")
        guard var catalog = try MomentsCatalog.load(from: catalogURL) else {
            throw PublicationFailure.invalidRequest
        }
        guard catalog.markPublished(momentID: momentID, albumID: albumID, date: date) else {
            throw PublicationFailure.invalidRequest
        }
        try catalog.save(to: catalogURL)
    }

    /// Uses only existing evidence caches; shared by presentation and isolated evaluation.
    func prepareDisplaySelection(_ moment: PhotoMoment, results: [String: CuratorVisionResult],
                                 thresholds: [SimilarityCategory: Float] = [:], balanced: Bool = true) async throws -> PhotoMoment {
        var output = moment
        var roles: [String: PhotoDisplayEvidence] = [:]
        var sceneLabels: [String: [String]] = [:]
        for photo in moment.photos {
            try Task.checkCancellation()
            let labels = await context.cachedLabels(photo) ?? []
            sceneLabels[photo.id] = labels
            let text = await textStore.cached(photo)
            if let role = MomentDisplayEligibility.classify(photo, labels: labels, lines: text?.lines ?? [], result: results[photo.id]) {
                roles[photo.id] = role
            }
        }
        output.displayEvidence = roles
        // Context-only shots cannot displace display candidates during similarity selection.
        let candidates = MomentDisplayEligibility.automaticCandidates(in: output)
        var selection = MomentDisplayEligibility.annotate(
            MomentSelector.select(candidates, results: results, thresholds: thresholds), moment: output)
        if balanced {
            selection = BalancedMomentSelector.select(selection, photos: moment.photos, results: results)
            selection = ScenerySelection.select(selection, photos: moment.photos, labels: sceneLabels, results: results)
            selection = RepresentativeSelector.select(selection, photos: moment.photos, results: results)
        }
        output.selection = selection
        return output
    }

    func overview(range: DateInterval, thresholds: [SimilarityCategory: Float], balanced: Bool, limit: Int = 200,
                  protection: MomentGroupingProtection = .init(), preparedPrefix: [PhotoMoment] = []) async throws -> (moments: [PhotoMoment], total: Int, undated: Int, available: Int) {
        let db = try database()
        let counts = try db.counts()
        let grouped = try preparedCatalog(protection: protection)
        var moments = Array(grouped.prefix(limit))
        let reusableCount = zip(moments, preparedPrefix).prefix { candidate, prepared in
            candidate.id == prepared.id && candidate.photos.count == prepared.photos.count &&
                zip(candidate.photos, prepared.photos).allSatisfy {
                    $0.id == $1.id && $0.analysisRevision == $1.analysisRevision
                }
        }.count
        let reused = Array(preparedPrefix.prefix(reusableCount))
        moments.removeFirst(reusableCount)
        let previouslySaved = (try? savedMoments()) ?? []
        let publishedMap = Dictionary(previouslySaved.compactMap { m -> (String, (String, Date?))? in
            guard let albumID = m.publishedAlbumID else { return nil }
            return (m.id, (albumID, m.publishedDate))
        }, uniquingKeysWith: { first, _ in first })
        // Classify only the visible page, not the entire historical library on each refresh.
        let pageRange = DateInterval(start: moments.map(\.start).min() ?? Date(),
                                     end: (moments.map(\.end).max() ?? Date()).addingTimeInterval(1))
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized {
            let allPagePhotos = moments.flatMap(\.photos)
            let classified = PhotoKitSimilarityCategories.classify(allPagePhotos, range: pageRange)
            let byID = Dictionary(uniqueKeysWithValues: classified.map { ($0.id, $0) })
            let liveAssetIDs = Set(byID.keys)
            let missingIDs = Set(allPagePhotos.map(\.id)).subtracting(liveAssetIDs)
            if !missingIDs.isEmpty {
                try? db.deletePhotos(ids: missingIDs)
            }
            moments = moments.compactMap { (m: PhotoMoment) -> PhotoMoment? in
                let livePhotos = m.photos.compactMap { byID[$0.id] }
                guard !livePhotos.isEmpty else { return nil }
                let start = livePhotos.first?.created ?? m.start
                let end = livePhotos.last?.created ?? m.end
                return PhotoMoment(id: m.id, start: start, end: end, photos: livePhotos,
                    selection: m.selection, narrative: m.narrative, contextSource: m.contextSource,
                    reviewedGroupTitle: m.reviewedGroupTitle, groupingSource: m.groupingSource,
                    groupingReason: m.groupingReason, groupingState: m.groupingState, groupingKind: m.groupingKind,
                    displayEvidence: m.displayEvidence, continuityReason: m.continuityReason,
                    publishedAlbumID: m.publishedAlbumID ?? publishedMap[m.id]?.0,
                    publishedDate: m.publishedDate ?? publishedMap[m.id]?.1)
            }
        } else {
            moments = moments.map { PhotoMoment(id: $0.id, start: $0.start, end: $0.end,
                photos: $0.photos, reviewedGroupTitle: $0.reviewedGroupTitle,
                groupingSource: $0.groupingSource, groupingReason: $0.groupingReason, groupingState: $0.groupingState,
                groupingKind: $0.groupingKind, continuityReason: $0.continuityReason,
                publishedAlbumID: $0.publishedAlbumID ?? publishedMap[$0.id]?.0,
                publishedDate: $0.publishedDate ?? publishedMap[$0.id]?.1) }
        }
        for index in moments.indices {
            if moments[index].groupingKind != .unresolved, let caption = await context.cached(moments[index]) {
                moments[index].narrative = caption.narrative
                moments[index].contextSource = caption.narrative.provenance.first
            }
            var results: [String: CuratorVisionResult] = [:]
            for photo in moments[index].photos {
                if let data = try db.analysisResult(asset: photo.id, revision: photo.analysisRevision, analyzer: CuratorVisionAnalyzer.version),
                   let value = try? JSONDecoder().decode(CuratorVisionResult.self, from: data) {
                    results[photo.id] = value
                }
            }
            moments[index] = try await prepareDisplaySelection(moments[index], results: results, thresholds: thresholds, balanced: balanced)
        }
        moments = reused + moments
        try MomentsCatalog(updated: Date(), moments: moments).save(to: url.deletingLastPathComponent().appendingPathComponent("moments-catalog.json"))
        return (moments, counts.total, counts.undated, grouped.count)
    }

    /// Refreshes cached narrative and selection for one already-projected card.
    /// It deliberately does not rebuild grouping or enumerate the library.
    func refreshedPresentation(_ moment: PhotoMoment, thresholds: [SimilarityCategory: Float],
                               balanced: Bool) async throws -> PhotoMoment {
        let db = try database()
        var updated = moment
        if moment.groupingKind != .unresolved, let caption = await context.cached(moment) {
            updated.narrative = caption.narrative
            updated.contextSource = caption.narrative.provenance.first
        }
        var results: [String: CuratorVisionResult] = [:]
        for photo in moment.photos {
            if let data = try db.analysisResult(asset: photo.id, revision: photo.analysisRevision,
                                                analyzer: CuratorVisionAnalyzer.version),
               let value = try? JSONDecoder().decode(CuratorVisionResult.self, from: data) {
                results[photo.id] = value
            }
        }
        return try await prepareDisplaySelection(updated, results: results, thresholds: thresholds, balanced: balanced)
    }

    func claim(range: DateInterval?) throws -> AnalysisJob? { try database().claimAnalysis(range: range) }
    func similarityPairs(range: DateInterval, category: SimilarityCategory) throws -> [SimilarityPair] {
        let db = try database()
        var pairs: [SimilarityPair] = []
        // Bounded deterministic sample, spread over the selected period, within moments.
        let groups = MomentGrouping.group(PhotoKitSimilarityCategories.classify(try db.photos(in: range), range: range))
        let candidates = groups.flatMap { moment -> [(IndexedPhoto, IndexedPhoto)] in
            let photos = moment.photos.filter { $0.similarityCategory == category }.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
            return zip(photos, photos.dropFirst()).filter {
                guard let a = $0.0.created, let b = $0.1.created else { return false }
                return abs(a.timeIntervalSince(b)) <= 60
            }
        }
        let stride = max(1, Int(ceil(Double(candidates.count) / 512)))
        var results: [String: CuratorVisionResult] = [:]
        for index in Swift.stride(from: 0, to: candidates.count, by: stride) {
            try Task.checkCancellation()
            let (a, b) = candidates[index]
            for photo in [a, b] where results[photo.id] == nil {
                if let data = try db.analysisResult(asset: photo.id, revision: photo.analysisRevision, analyzer: CuratorVisionAnalyzer.version) {
                    results[photo.id] = try? JSONDecoder().decode(CuratorVisionResult.self, from: data)
                }
            }
            if let lhs = results[a.id], let rhs = results[b.id], let value = try? lhs.distance(to: rhs), value >= 0 {
                pairs.append(SimilarityPair(first: a, second: b, distance: value))
            }
        }
        return pairs.sorted { $0.distance < $1.distance }
    }
    func finish(_ job: AnalysisJob, result: CuratorVisionResult) throws {
        try database().finishAnalysis(job, result: JSONEncoder().encode(result))
    }
    func retryLater(_ job: AnalysisJob) throws {
        try database().deferAnalysis(job, until: Date().addingTimeInterval(3600))
    }
    func release(_ job: AnalysisJob) throws { try database().releaseAnalysis(job) }
}

private final class CuratorLibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let lock = NSLock()
    private var assets: PHFetchResult<PHAsset>
    let changed: (_ changedOrInserted: Set<String>, _ removed: Set<String>, _ requiresFullScan: Bool) -> Void

    init(changed: @escaping (Set<String>, Set<String>, Bool) -> Void) {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.includeHiddenAssets = false
        assets = PHAsset.fetchAssets(with: options)
        self.changed = changed
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        lock.lock()
        defer { lock.unlock() }
        guard let details = changeInstance.changeDetails(for: assets) else {
            // Album/folder membership and title changes do not affect the image index.
            return
        }
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

@MainActor
final class CuratorController: ObservableObject {
    @Published private(set) var similarityThresholds = SimilarityCategory.savedThresholds()
    @Published private(set) var balancedSelection = (UserDefaults.standard.object(forKey: "curator.balancedSelection.v1") as? Bool) ?? true
    func setBalancedSelection(_ enabled: Bool) {
        balancedSelection = enabled
        UserDefaults.standard.set(enabled, forKey: "curator.balancedSelection.v1")
        Task { await refreshOverview() }
    }

    func similarityPairs(category: SimilarityCategory) async throws -> [SimilarityPair] {
        guard let range = selectedRange else { return [] }
        return try await worker.similarityPairs(range: range, category: category)
    }

    func applySimilarityThresholds(_ values: [SimilarityCategory: Float]) {
        guard values.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return }
        similarityThresholds = values
        for (category, value) in values { UserDefaults.standard.set(value, forKey: category.preferenceKey) }
        Task { await refreshOverview() }
    }
    @Published private(set) var enabled: Bool
    @Published private(set) var activity = "Background curation is off."
    @Published private(set) var indexedCount = 0
    @Published private(set) var undatedCount = 0
    @Published private(set) var moments: [PhotoMoment] = []
    @Published private(set) var availableMoments = 0
    @Published private(set) var overviewLoading = false
    private var momentLimit = max(200, UserDefaults.standard.integer(forKey: "curator.momentLimit.v1"))

    func loadMoreMoments() async {
        guard momentLimit < availableMoments else { return }
        while overviewLoading {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
        }
        momentLimit += 200
        UserDefaults.standard.set(momentLimit, forKey: "curator.momentLimit.v1")
        await refreshOverview(reusingVisibleMoments: true)
    }
    @Published private(set) var scanned = 0
    @Published private(set) var scanTotal = 0
    @Published private(set) var foregroundActive = false
    @Published private(set) var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var errorMessage: String?
    @Published var period: CuratorPeriod = .lastMonth
    @Published var customStart = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @Published var customEnd = Date()
    @Published private(set) var syncBusy = false
    @Published private(set) var diagnosticRunning = false
    @Published private(set) var diagnosticReport = "Tests up to 12 photos in the selected period. No downloads, uploads, or album changes."
    private var diagnosticTask: Task<Void, Never>?
    private var syncSubscription: AnyCancellable?

    private let worker: CuratorWorker
    private var timer: Timer?
    private var observer: CuratorLibraryObserver?
    private var batchRunning = false
    private var restartRequested = false
    private var backgroundNeedsScan = false
    private var foregroundRange: DateInterval?
    private var revision = 0
    private var lastOverview = Date.distantPast
    private var metadataReady = false
    private var startupStateLoaded = false
    private var nextReconciliationAnalysisStep = 4
    private var checkpointProbeRunning = false
    private var lastCheckpointProbe = Date.distantPast
    private var analysisTask: Task<Void, Never>?
    private var viewportPrioritySignatures = Set<String>()
    private(set) var analyzedThisSession = 0
    private(set) var deferredThisSession = 0
    private lazy var analysisLoader = CuratorThumbnailLoader(provider: PhotoKitThumbnailProvider())
    private let analyzer = CuratorVisionAnalyzer()
    private var contextStep = 0
    private var lastWaitLog = Date.distantPast

    @Published var autoPublishEnabled: Bool
    private var publishingMomentIDs: Set<String> = []
    private var failedAutoPublishMomentIDs: Set<String> = []
    private var isPublishingInBackground = false
    private var publicationChangeInProgress = false
    private var ignorePublicationChangesUntil = Date.distantPast

    private func logWait(_ code: Int) {
        guard Date().timeIntervalSince(lastWaitLog) >= 60 else { return }
        lastWaitLog = Date()
        CuratorTelemetry.shared.record(.waiting, counts: ["reason": code])
    }

    var selectedRange: DateInterval? {
        period.interval(now: Date(), customStart: customStart, customEnd: customEnd)
    }

    init(model: PhotoRelayViewModel) {
        if !UserDefaults.standard.bool(forKey: "curatorPilotLifted") {
            UserDefaults.standard.removeObject(forKey: "curatorPilotStart")
            UserDefaults.standard.removeObject(forKey: "curatorPilotEnd")
            UserDefaults.standard.removeObject(forKey: "curatorPrioritizePilotOnLaunch")
            UserDefaults.standard.set(true, forKey: "curatorPilotLifted")
        }
        enabled = UserDefaults.standard.bool(forKey: "curatorEnabled")
        autoPublishEnabled = UserDefaults.standard.object(forKey: "curatorAutoPublish") as? Bool ?? true
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Relay/curator/index.sqlite3")
        worker = CuratorWorker(url: url)
        if let pilot = CuratorPilot.range() {
            customStart = pilot.start
            customEnd = pilot.end.addingTimeInterval(-1)
            period = .custom
        }
        CuratorTelemetry.shared.record(.launch, counts: ["enabled": enabled ? 1 : 0, "boundedPilot": CuratorPilot.range() == nil ? 0 : 1])
        StorageMaintenance.run()
        Task {
            try? await worker.maintainStorage()
            let indexed = (try? await worker.indexedPhotoCount()) ?? 0
            let checkpointRequiresReconciliation = await worker.startupRequiresFullReconciliation(indexedCount: indexed)
            let needsReconciliation = indexed == 0 || checkpointRequiresReconciliation
            await MainActor.run { [weak self] in
                guard let self else { return }
                // A populated catalog is immediately useful. Reconcile PhotoKit in
                // bounded maintenance slices instead of blocking all title work.
                self.metadataReady = indexed > 0
                self.backgroundNeedsScan = needsReconciliation
                self.restartRequested = needsReconciliation
                self.lastCheckpointProbe = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
                    ? Date() : .distantPast
                self.startupStateLoaded = true
                self.tick()
            }
        }
        syncSubscription = model.$isWorking.sink { [weak self] busy in
            self?.syncBusy = busy
            if busy { self?.analysisTask?.cancel() }
        }
        timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        Task { await refreshOverview(reusingVisibleMoments: true) }
        if UserDefaults.standard.bool(forKey: "curatorPrioritizePilotOnLaunch") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.processRangeNow()
            }
        }
    }

    func setAutoPublishEnabled(_ value: Bool) {
        autoPublishEnabled = value
        UserDefaults.standard.set(value, forKey: "curatorAutoPublish")
    }

    func setFavorite(_ favorite: Bool, photoID: String) async throws {
        publicationChangeInProgress = true
        defer {
            publicationChangeInProgress = false
            ignorePublicationChangesUntil = Date().addingTimeInterval(3)
        }
        try await PhotoKitAssetEditor.shared.setFavorite(favorite, assetID: photoID)
        try await worker.reconcileEditedAsset(photoID)
        try? await worker.refreshCheckpointFingerprint()
        await refreshOverview()
    }

    func moveToRecentlyDeleted(photoID: String) async throws {
        publicationChangeInProgress = true
        defer {
            publicationChangeInProgress = false
            ignorePublicationChangesUntil = Date().addingTimeInterval(3)
        }
        try await PhotoKitAssetEditor.shared.moveToRecentlyDeleted(assetID: photoID)
        try await worker.removeDeletedAsset(photoID)
        try? await worker.refreshCheckpointFingerprint()
        await refreshOverview()
    }

    func mergeMoments(_ source: [PhotoMoment], title: String, decisions: MomentReviewDecisions,
                      expectedRevision: Int) async throws {
        let sourceText = Dictionary(uniqueKeysWithValues: source.map { moment in
            (moment.id, {
                let value = MomentPresentation.narrative(moment, customTitle: decisions.titles[moment.id],
                    customDescription: decisions.descriptions[moment.id])
                return value.headline + "\n" + (value.story ?? "")
            }())
        })
        let saved = try MomentMergeDraft.store.merge(source, title: title, sourceText: sourceText,
                                                      expectedRevision: expectedRevision)
        let photos = source.flatMap(\.photos).sorted {
            ($0.created ?? .distantPast, $0.id) < ($1.created ?? .distantPast, $1.id)
        }
        let selected = source.flatMap { moment -> [String] in
            guard let selection = moment.selection else { return moment.photos.map(\.id) }
            return MomentReviewDecisions.apply(decisions.values, to: selection, photos: moment.photos).selected
        }
        let merged = PhotoMoment(id: saved.id, start: source.map(\.start).min()!, end: source.map(\.end).max()!,
            photos: photos, selection: MomentSelection(selected: Array(Set(selected)).sorted(), pending: [], similar: [],
                explanations: [:], alternatives: [], contextOnly: []), reviewedGroupTitle: title,
            groupingSource: "manual", groupingReason: "Merged by you", groupingState: .reviewed)

        let oldAlbumIDs = Set(source.compactMap(\.publishedAlbumID))
        if !oldAlbumIDs.isEmpty {
            let receipt = try await publishToPhotos(moment: merged, decisions: decisions)
            try await PhotoKitAlbumAdapter.shared.deleteManagedAlbums(withIDs: oldAlbumIDs, keeping: receipt.albumID)
        }
        await refreshOverview()
    }

    func setEnabled(_ value: Bool) {
        if value {
            authorize { [weak self] in
                guard let self else { return }
                self.enabled = true
                CuratorTelemetry.shared.record(.enabled)
                UserDefaults.standard.set(true, forKey: "curatorEnabled")
                Task {
                    let indexed = (try? await self.worker.indexedPhotoCount()) ?? 0
                    let checkpointRequiresReconciliation = await self.worker.startupRequiresFullReconciliation(indexedCount: indexed)
                    let needsReconciliation = indexed == 0 || checkpointRequiresReconciliation
                    self.metadataReady = indexed > 0
                    self.backgroundNeedsScan = needsReconciliation
                    self.restartRequested = needsReconciliation
                    self.revision += 1
                    self.tick()
                }
            }
        } else {
            enabled = false
            CuratorTelemetry.shared.record(.paused)
            if !foregroundActive { analysisTask?.cancel() }
            UserDefaults.standard.set(false, forKey: "curatorEnabled")
            if !foregroundActive { activity = "Background curation is paused. Your index is kept." }
        }
    }

    func processRangeNow() {
        guard !diagnosticRunning else { return }
        guard let range = selectedRange, !foregroundActive else { return }
        authorize { [weak self] in
            guard let self else { return }
            self.foregroundRange = range
            self.analysisTask?.cancel()
            self.metadataReady = false
            self.foregroundActive = true
            self.restartRequested = true
            self.revision += 1
            self.activity = "Preparing this date range…"
            self.tick()
        }
    }

    func stopForeground() {
        analysisTask?.cancel()
        metadataReady = false
        foregroundActive = false
        foregroundRange = nil
        restartRequested = true
        backgroundNeedsScan = true
        revision += 1
        activity = "Range scan stopped. Indexed metadata was kept."
    }

    func stopDiagnostic() { diagnosticTask?.cancel() }

    func runDiagnostic() {
        guard !diagnosticRunning, !foregroundActive, !batchRunning, !syncBusy,
              let range = selectedRange else { return }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            diagnosticReport = "Allow Photo Curator access in System Settings > Privacy & Security > Photos. Full Disk Access is not needed."
            return
        }
        diagnosticRunning = true
        diagnosticReport = "Checking local photos..."
        diagnosticTask = Task {
            defer { diagnosticRunning = false; diagnosticTask = nil }
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@ AND creationDate < %@", PHAssetMediaType.image.rawValue, range.start as NSDate, range.end as NSDate)
            options.includeHiddenAssets = false
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = 12
            let assets = PHAsset.fetchAssets(with: options)
            let loader = CuratorThumbnailLoader(provider: PhotoKitThumbnailProvider())
            let analyzer = CuratorVisionAnalyzer()
            let start = Date()
            var loaded = 0, skipped = 0, locations = 0, faces = 0, scores = 0, prints = 0
            var outcome = "Complete"
            for index in 0..<assets.count {
                let process = ProcessInfo.processInfo
                if Task.isCancelled { outcome = "Stopped"; break }
                if syncBusy || process.isLowPowerModeEnabled || process.thermalState == .serious || process.thermalState == .critical {
                    outcome = "Stopped for sync or power/thermal conditions"; break
                }
                if Date().timeIntervalSince(start) > 120 { outcome = "Time limit reached"; break }
                let asset = assets.object(at: index)
                if asset.location != nil { locations += 1 }
                do {
                    let image = try await loader.load(assetID: asset.localIdentifier, timeout: 8)
                    let result = try await analyzer.analyze(image)
                    loaded += 1
                    if case .available = result.faces { faces += 1 }
                    if case .available = result.aesthetics { scores += 1 }
                    if case .available = result.featurePrint { prints += 1 }
                } catch {
                    if Task.isCancelled { outcome = "Stopped"; break }
                    skipped += 1
                }
                diagnosticReport = "Checked \(index + 1) of \(assets.count) photos..."
            }
            diagnosticReport = "\(outcome): \(loaded) analyzed, \(skipped) unavailable or failed; \(locations) inspected with GPS. Successful requests: faces \(faces), aesthetics \(scores), similarity \(prints). \(Int(Date().timeIntervalSince(start))) seconds. No library changes."
        }
    }

    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if enabled && !loginEnabled {
                errorMessage = "Allow Photo Curator in System Settings > General > Login Items."
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshOverview(reusingVisibleMoments: Bool = false) async {
        guard !overviewLoading else { return }
        overviewLoading = true
        defer { overviewLoading = false }
        let range = DateInterval(start: .distantPast, end: .distantFuture)
        do {
            if moments.isEmpty { moments = try await worker.savedMoments() }
            // Keep the saved projection until PhotoKit can supply its public categories.
            // Otherwise a permission prompt temporarily changes and persists selections.
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
            MomentGroupingProtection.captureLegacy(moments, defaults: .standard)
            var protection = MomentGroupingProtection.load(.standard)
            if !protection.ids.subtracting(protection.members.keys).isEmpty {
                // Migrate named groups outside the visible page too, before automatic work.
                let all = try await worker.preparedCatalog(protection: protection)
                MomentGroupingProtection.captureLegacy(all, defaults: .standard)
                protection = MomentGroupingProtection.load(.standard)
            }
            let thresholds = similarityThresholds
            let balanced = balancedSelection
            let overview = try await worker.overview(range: range, thresholds: thresholds, balanced: balanced,
                limit: momentLimit, protection: protection,
                preparedPrefix: reusingVisibleMoments ? moments : [])
            guard similarityThresholds == thresholds, balancedSelection == balanced,
                  protection == MomentGroupingProtection.load(.standard) else { return }
            MomentGroupingProtection.captureLegacy(overview.moments, defaults: .standard)
            moments = overview.moments
            availableMoments = overview.available
            indexedCount = overview.total
            undatedCount = overview.undated
            CuratorTelemetry.shared.record(.catalog, counts: ["indexed": overview.total, "moments": overview.available,
                "visible": moments.count,
                "singletons": moments.filter { $0.photos.count == 1 }.count,
                "selected": moments.reduce(0) { $0 + ($1.selection?.selected.count ?? 0) },
                "pending": moments.reduce(0) { $0 + ($1.selection?.pending.count ?? 0) }])
            lastOverview = Date()
        } catch is CancellationError {
            return
        } catch PublicationFailure.conflictingOperation {
            // Another serialized catalog update won. The next worker tick will use it.
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prioritizeVisibleMoment(_ moment: PhotoMoment, photos: [IndexedPhoto]) async {
        guard enabled, !photos.isEmpty else { return }
        let revisions = photos.map { "\($0.id):\($0.analysisRevision)" }.joined(separator: "|")
        let signature = "\(moment.id)|\(revisions)"
        guard viewportPrioritySignatures.insert(signature).inserted else { return }
        do {
            try await worker.prioritizeAnalysis(photos)
            tick()
        } catch {
            viewportPrioritySignatures.remove(signature)
            CuratorTelemetry.shared.record(.failure, counts: ["code": (error as NSError).code])
        }
    }

    private func refreshVisibleMoment(_ id: String) async {
        guard let index = moments.firstIndex(where: { $0.id == id }) else { return }
        let thresholds = similarityThresholds
        let balanced = balancedSelection
        do {
            let updated = try await worker.refreshedPresentation(moments[index], thresholds: thresholds,
                                                                 balanced: balanced)
            guard similarityThresholds == thresholds, balancedSelection == balanced,
                  moments.indices.contains(index), moments[index].id == id else { return }
            moments[index] = updated
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func authorize(_ action: @escaping () -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized { action(); return }
        guard status == .notDetermined else {
            errorMessage = "Allow full Photos access in System Settings > Privacy & Security > Photos before indexing."
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            Task { @MainActor in
                if status == .authorized {
                    NotificationCenter.default.post(name: .photoRelayPhotosAccessChanged, object: nil)
                    action()
                }
                else { self.errorMessage = "Photos access was not granted. No scanning has started." }
            }
        }
    }

    private func tick() {
        guard !diagnosticRunning else { return }
        guard startupStateLoaded else { return }
        guard !batchRunning, enabled || foregroundActive else { return }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            activity = "Waiting for full Photos access. Open Moments to enable it."
            logWait(1)
            return
        }
        if observer == nil {
            let listener = CuratorLibraryObserver { [weak self] updated, removed, requiresFullScan in
                Task { @MainActor in
                    guard let self else { return }
                    // Creating our managed folders/albums emits PhotoKit changes. Cancelling
                    // here would interrupt the publication that caused the notification.
                    if self.publicationChangeInProgress || Date() < self.ignorePublicationChangesUntil {
                        return
                    }
                    CuratorTelemetry.shared.record(.libraryChange, counts: [
                        "updated": updated.count, "removed": removed.count,
                        "full": requiresFullScan ? 1 : 0
                    ])
                    if requiresFullScan {
                        self.backgroundNeedsScan = true
                        self.restartRequested = true
                        self.metadataReady = false
                        self.analysisTask?.cancel()
                        self.revision += 1
                    } else {
                        do {
                            for id in removed { try await self.worker.removeDeletedAsset(id) }
                            var metadataChanged = !removed.isEmpty
                            for id in updated {
                                if try await self.worker.reconcileEditedAsset(id) { metadataChanged = true }
                            }
                            if metadataChanged {
                                try await self.worker.refreshCheckpointFingerprint()
                                await self.refreshOverview()
                            }
                        } catch {
                            self.backgroundNeedsScan = true
                            self.restartRequested = true
                            self.metadataReady = false
                        }
                    }
                }
            }
            observer = listener
            PHPhotoLibrary.shared().register(listener)
        }
        if !foregroundActive, !checkpointProbeRunning,
           Date().timeIntervalSince(lastCheckpointProbe) >= 60 * 60 {
            checkpointProbeRunning = true
            lastCheckpointProbe = Date()
            Task {
                let indexed = (try? await worker.indexedPhotoCount()) ?? 0
                let needed = await worker.startupRequiresFullReconciliation(indexedCount: indexed)
                checkpointProbeRunning = false
                if needed, !backgroundNeedsScan {
                    backgroundNeedsScan = true
                    restartRequested = true
                    revision += 1
                }
            }
        }
        let process = ProcessInfo.processInfo
        if syncBusy {
            activity = "Waiting for your export or Google sync to finish."
            logWait(2)
            return
        }
        if process.isLowPowerModeEnabled {
            activity = "Paused while Low Power Mode is on."
            logWait(3)
            return
        }
        if process.thermalState == .serious || process.thermalState == .critical {
            activity = "Paused while your Mac is running hot."
            logWait(4)
            return
        }

        // Fast metadata sync: unblocked by idle timer so library updates and deletions reflect immediately.
        let reconciliationDue = contextStep >= nextReconciliationAnalysisStep
        if CuratorPolicy.shouldRunMetadata(foreground: foregroundActive, metadataReady: metadataReady,
                                           reconciliationNeeded: backgroundNeedsScan,
                                           reconciliationDue: reconciliationDue) {
            let currentRevision = revision
            let wasForeground = foregroundActive
            let range = CuratorPilot.scope(wasForeground ? foregroundRange : nil)
            let restart = restartRequested
            restartRequested = false
            batchRunning = true
            Task {
                defer { batchRunning = false }
                do {
                    // Keep foreground review responsive; accelerate metadata-only reconciliation
                    // when the app is unattended. Vision work remains idle-gated separately.
                    let metadataBatchSize = wasForeground ? 500 : (NSApp.isActive ? 100 : 1_000)
                    let result = try await worker.batch(range: range, restart: restart, limit: metadataBatchSize)
                    guard currentRevision == revision else { return }
                    scanned = result.scanned
                    scanTotal = result.total
                    CuratorTelemetry.shared.record(.metadata, counts: ["scanned": result.scanned, "total": result.total])
                    activity = "Checking library changes: \(result.scanned.formatted()) of \(result.total.formatted())"
                    if result.finished {
                        metadataReady = true
                        if !wasForeground { backgroundNeedsScan = false }
                        activity = "Metadata ready. Preparing local visual analysis."
                    } else if !wasForeground {
                        nextReconciliationAnalysisStep = contextStep + 4
                    }
                    if result.finished { await refreshOverview() }
                } catch {
                    activity = "Curator paused: \(error.localizedDescription)"
                    enabled = false
                    foregroundActive = false
                    restartRequested = true
                    UserDefaults.standard.set(false, forKey: "curatorEnabled")
                    errorMessage = error.localizedDescription
                }
            }
            return
        }

        // Local title evidence runs at utility priority even while the Mac is active. Only
        // automatic Photos publication waits for idle, because that is externally visible.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        if metadataReady {
            let mayPublish = CuratorPolicy.mayRunAutomaticPublication(idleSeconds: idle, foreground: foregroundActive)
            runAnalysisStep(allowAutomaticPublication: mayPublish)
            return
        }
        activity = "Metadata is up to date. Watching for changes in Photos."
    }

    private func runAnalysisStep(allowAutomaticPublication: Bool) {
        let token = revision
        let range = CuratorPilot.scope(foregroundActive ? foregroundRange : nil)
        let analysisActivity = "Analyzing photos and refining Moments…"
        if activity != analysisActivity {
            activity = analysisActivity
        }
        batchRunning = true
        analysisTask = Task(priority: .utility) {
            var caughtUp = false
            var failedBeforeClaim = false
            defer {
                batchRunning = false
                analysisTask = nil
                if CuratorPolicy.shouldContinueAnalysis(caughtUp: caughtUp, failedBeforeClaim: failedBeforeClaim) {
                    Task { @MainActor [weak self] in
                        await Task.yield()
                        guard let self, token == self.revision else { return }
                        self.tick()
                    }
                }
            }
            var claimed: AnalysisJob?
            do {
                contextStep += 1
                if contextStep % 8 == 0 {
                    let step = try await worker.prepareMoments(range: range, protection: MomentGroupingProtection.load(.standard))
                    try Task.checkCancellation()
                    guard token == revision else { return }
                    if case .presentationChanged(let id) = step {
                        await refreshVisibleMoment(id)
                        return
                    }
                    if step == .changed {
                        await refreshOverview()
                        return
                    }
                }
                if allowAutomaticPublication && autoPublishEnabled && contextStep % 10 == 0 {
                    if await autoPublishNextReadyMoment() {
                        return
                    }
                }
                guard let job = try await worker.claim(range: range) else {
                    guard token == revision else { return }
                    if let photo = try await worker.nextTextCandidate(range: range) {
                        let image = try await analysisLoader.load(assetID: photo.id, timeout: 8)
                        try Task.checkCancellation()
                        guard token == revision else { return }
                        try await worker.prepareText(photo, image: image)
                        return
                    }
                    let step = try await worker.prepareMoments(range: range, protection: MomentGroupingProtection.load(.standard))
                    try Task.checkCancellation()
                    guard token == revision else { return }
                    if step != .caughtUp {
                        if case .presentationChanged(let id) = step { await refreshVisibleMoment(id) }
                        else if step == .changed { await refreshOverview() }
                        return
                    }
                    if allowAutomaticPublication && autoPublishEnabled {
                        if await autoPublishNextReadyMoment() {
                            return
                        }
                    }
                    activity = "Available local evidence processed. Incomplete collections keep conservative grouping."
                    caughtUp = true
                    CuratorTelemetry.shared.record(.caughtUp, counts: ["saved": analyzedThisSession, "deferred": deferredThisSession])
                    await refreshOverview(reusingVisibleMoments: true)
                    if foregroundActive {
                        foregroundActive = false
                        foregroundRange = nil
                        metadataReady = false
                        restartRequested = true
                        backgroundNeedsScan = true
                    }
                    return
                }
                claimed = job
                try Task.checkCancellation()
                let image = try await analysisLoader.load(assetID: job.asset, timeout: 8)
                let result = try await analyzer.analyze(image)
                try Task.checkCancellation()
                guard token == revision else { try await worker.release(job); return }
                // An edit since enqueue must never be saved under an old fingerprint.
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [job.asset], options: nil).firstObject,
                      !asset.isHidden,
                      "\(asset.modificationDate?.timeIntervalSince1970.description ?? "unknown")-\(asset.pixelWidth)x\(asset.pixelHeight)" == job.revision else {
                    try await worker.retryLater(job)
                    return
                }
                let photo = IndexedPhoto(id: asset.localIdentifier, created: asset.creationDate,
                    modified: asset.modificationDate, latitude: asset.location?.coordinate.latitude,
                    longitude: asset.location?.coordinate.longitude, favorite: asset.isFavorite,
                    width: asset.pixelWidth, height: asset.pixelHeight,
                    similarityCategory: asset.mediaSubtypes.contains(.photoScreenshot) ? .screenshots : .photos)
                try await worker.prepareText(photo, image: image)
                try Task.checkCancellation()
                guard token == revision else { try await worker.release(job); return }
                if case .failed = result.aesthetics { try await worker.retryLater(job); deferredThisSession += 1 }
                else if case .failed = result.faces { try await worker.retryLater(job); deferredThisSession += 1 }
                else if case .failed = result.featurePrint { try await worker.retryLater(job); deferredThisSession += 1 }
                else { try await worker.finish(job, result: result); analyzedThisSession += 1 }
                CuratorTelemetry.shared.record(.analysis, counts: ["saved": analyzedThisSession, "deferred": deferredThisSession])
            } catch {
                if claimed == nil && !Task.isCancelled {
                    if let thumbnailFailure = error as? ThumbnailFailure,
                       thumbnailFailure == .unavailable || thumbnailFailure == .cloudOnly || thumbnailFailure == .timedOut {
                        deferredThisSession += 1
                    } else {
                        failedBeforeClaim = true
                        CuratorTelemetry.shared.record(.failure, counts: ["code": (error as NSError).code])
                        activity = "Moment preparation paused: \(error.localizedDescription)"
                    }
                }
                if let job = claimed {
                    do {
                        if Task.isCancelled { try await worker.release(job) }
                        else { try await worker.retryLater(job); deferredThisSession += 1 }
                    } catch { errorMessage = "Could not save analysis progress. Retry after reopening Photo Curator." }
                }
            }
        }
    }

    func liftPilotRestrictions() {
        UserDefaults.standard.removeObject(forKey: "curatorPilotStart")
        UserDefaults.standard.removeObject(forKey: "curatorPilotEnd")
        UserDefaults.standard.removeObject(forKey: "curatorPrioritizePilotOnLaunch")
        backgroundNeedsScan = true
        restartRequested = true
        metadataReady = false
        revision += 1
    }

    @discardableResult
    func autoPublishNextReadyMoment() async -> Bool {
        guard autoPublishEnabled, !isPublishingInBackground else { return false }
        let decisions = MomentReviewDecisions(defaults: .standard)
        guard let candidate = moments.first(where: {
            MomentDisplayEligibility.isAutoPublishEligible($0, decisions: decisions.values,
                userAuthored: decisions.titles[$0.id] != nil || decisions.descriptions[$0.id] != nil) &&
            !publishingMomentIDs.contains($0.id) &&
            !failedAutoPublishMomentIDs.contains($0.id)
        }) else { return false }

        isPublishingInBackground = true
        publishingMomentIDs.insert(candidate.id)
        defer {
            publishingMomentIDs.remove(candidate.id)
            isPublishingInBackground = false
        }

        let place = await CuratorGeocodingService.shared.place(for: candidate)
        let narrative = MomentPresentation.narrative(candidate, customTitle: decisions.titles[candidate.id],
            customDescription: decisions.descriptions[candidate.id], place: place)
        let title = narrative.headline
        activity = "Saving album in Photos for \(title)…"
        do {
            let receipt = try await publishToPhotos(moment: candidate, decisions: decisions)
            activity = "Saved album to Photos: \(title) (\(receipt.assetIDs.count) photos)"
            CuratorTelemetry.shared.record(.publication, counts: ["photos": receipt.assetIDs.count])
            await refreshOverview(reusingVisibleMoments: true)
            return true
        } catch {
            failedAutoPublishMomentIDs.insert(candidate.id)
            CuratorTelemetry.shared.record(.failure, counts: ["code": (error as NSError).code])
            return false
        }
    }

    func publishToPhotos(moment: PhotoMoment, decisions: MomentReviewDecisions) async throws -> CuratedAlbumReceipt {
        publicationChangeInProgress = true
        defer {
            publicationChangeInProgress = false
            ignorePublicationChangesUntil = Date().addingTimeInterval(3)
        }
        let place = await CuratorGeocodingService.shared.place(for: moment)
        let narrative = MomentPresentation.narrative(moment, customTitle: decisions.titles[moment.id],
            customDescription: decisions.descriptions[moment.id], place: place)
        let title = narrative.headline
        let story = narrative.story

        let selection = moment.selection.map { MomentReviewDecisions.apply(decisions.values, to: $0, photos: moment.photos) }
        let assetIDs = selection?.selected ?? moment.photos.map(\.id)
        guard !assetIDs.isEmpty else { throw PublicationFailure.invalidRequest }

        let cover = MomentDisplayEligibility.cover(moment, decisions: decisions.values, selected: assetIDs)
        let keyAssetID = cover?.id ?? assetIDs.first

        let catalogURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Relay/curator/moments-catalog.json")
        let journalDir = catalogURL.deletingLastPathComponent().appendingPathComponent("journals")
        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        let journalURL = journalDir.appendingPathComponent("publish-\(moment.id).json")

        let publication = try CuratedPublication(journal: journalURL)
        var request = CuratedPublicationRequest(
            operationID: UUID(),
            momentID: moment.id,
            title: title,
            description: story,
            keyAssetID: keyAssetID,
            date: moment.start,
            assetIDs: assetIDs
        )

        // A previous interruption must resume the immutable request already in the journal;
        // generating a new operation UUID would make every recovery conflict permanently.
        if let existing = await publication.snapshot(), existing.request.momentID == moment.id {
            request = existing.request
        }

        let receipt = try await publication.publish(request, adapter: PhotoKitAlbumAdapter.shared,
            retryAfterConfirmedAbsence: true)

        let publishedDate = Date()
        try await worker.markPublished(momentID: moment.id, albumID: receipt.albumID, date: publishedDate)
        if let idx = moments.firstIndex(where: { $0.id == moment.id }) {
            moments[idx].publishedAlbumID = receipt.albumID
            moments[idx].publishedDate = publishedDate
        }
        return receipt
    }
}
