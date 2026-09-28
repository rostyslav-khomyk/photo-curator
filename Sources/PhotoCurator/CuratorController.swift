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
    private let cacheURL: URL
    private var store: CuratorStore?
    private var fetch: PHFetchResult<PHAsset>?
    private var cursor = 0
    private var generation = ""
    private var fullScan = false
    private var scanOverrides = Set<String>()
    private var scanRemovals = Set<String>()
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
    /// Fingerprints already projected into Catalog v2 this process. Used to repair Moments whose
    /// automatic grouping finished but a caption-only refresh left `grouping_state` as preparing.
    private var projectedGroupingFingerprints = Set<String>()
    private var metadataGeneration = 0
    private var continuityPairs: [String: [MomentContinuityPair]] = [:]
    private var largeWindowCursor: [String: Int] = [:]
    private var largeWindowRemaining: [String: Int] = [:]
    private var largeWindowScanPending = false
    private lazy var derivedCache = try? DerivedCacheStore(url: cacheURL)
    private lazy var context = BackgroundMomentContext(root: url.deletingLastPathComponent().appendingPathComponent("background-context"),
        textDirectory: url.deletingLastPathComponent().appendingPathComponent("text-evidence"), cache: derivedCache)

    private var textStore: MomentTextEvidenceStore {
        MomentTextEvidenceStore(directory: url.deletingLastPathComponent().appendingPathComponent("text-evidence"), cache: derivedCache)
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
        if (try? database().verificationProgress()) != nil { return true }
        let current = PhotoLibraryFingerprint.current()
        guard let checkpoint = checkpointStore.load() else {
            // One-time migration for catalogs completed before checkpoints existed.
            // A later age-based verification still checks for same-count offline edits.
            guard indexedCount > 0, indexedCount == current.count else { return true }
            try? checkpointStore.save(PhotoLibraryCheckpoint(
                fingerprint: current, fullyVerifiedAt: now,
                persistentToken: PhotoLibraryChangeToken.capture()))
            return false
        }
        let required = checkpoint.requiresFullReconciliation(current: current, now: now)
        if !required, checkpoint.persistentToken == nil {
            try? checkpointStore.save(PhotoLibraryCheckpoint(
                fingerprint: checkpoint.fingerprint, fullyVerifiedAt: checkpoint.fullyVerifiedAt,
                persistentToken: PhotoLibraryChangeToken.capture()))
        }
        return required
    }

    func refreshCheckpointFingerprint() throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        try checkpointStore.updateFingerprint(.current())
    }

    func checkpointChangeToken() -> Data? { checkpointStore.load()?.persistentToken }

    func commitLibraryChangeToken(_ token: Data) throws {
        let previous = checkpointStore.load()
        try checkpointStore.save(PhotoLibraryCheckpoint(
            fingerprint: .current(),
            fullyVerifiedAt: previous?.fullyVerifiedAt ?? .distantPast,
            persistentToken: token))
    }

    func advanceVerificationScope(to token: Data) throws {
        let db = try database()
        guard let progress = try db.verificationProgress() else { return }
        try db.saveVerificationProgress(VerificationProgress(
            scope: "token:\(token.base64EncodedString())",
            generation: progress.generation, cursor: progress.cursor,
            total: progress.total, updated: Date()))
    }

    @discardableResult
    func reconcileEditedAsset(_ assetID: String) throws -> Bool {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = result.firstObject, !asset.isHidden else {
            try database().deletePhotos(ids: [assetID])
            if fullScan { scanRemovals.insert(assetID) }
            return true
        }
        let photo = IndexedPhoto.fromPhotoKit(asset)
        return try reconcilePhoto(photo)
    }

    @discardableResult
    func reconcilePhoto(_ photo: IndexedPhoto) throws -> Bool {
        let db = try database()
        if fullScan { scanOverrides.insert(photo.id) }
        let previous = try db.photo(id: photo.id)
        let changed = try db.updatePhoto(photo, generation: fullScan ? generation : nil)
        if let previous,
           previous.visualContentRevision == photo.visualContentRevision,
           previous.analysisRevision != photo.analysisRevision,
           try db.adoptAnalysisRevision(
            asset: photo.id,
            from: previous.analysisRevision,
            to: photo.analysisRevision,
            analyzer: CuratorVisionAnalyzer.version
           ) {
            return changed
        }
        // Idempotent enqueue also repairs a stale job when indexed metadata already matches.
        try db.enqueueAnalysis(asset: photo.id, revision: photo.analysisRevision,
                               analyzer: CuratorVisionAnalyzer.version,
                               priority: AdaptiveEvidenceScheduling.analysisPriority(photo))
        return changed
    }

    func currentAnalysisPhoto(_ job: AnalysisJob) throws -> IndexedPhoto? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [job.asset], options: nil).firstObject,
              !asset.isHidden else {
            _ = try reconcileEditedAsset(job.asset)
            return nil
        }
        let photo = IndexedPhoto.fromPhotoKit(asset)
        guard photo.analysisRevision == job.revision else {
            try reconcilePhoto(photo)
            return nil
        }
        return photo
    }

    func removeDeletedAsset(_ assetID: String) throws {
        if fullScan { scanRemovals.insert(assetID) }
        try database().deletePhotos(ids: [assetID])
    }
    func maintainStorage() throws {
        try database().maintain()
        try derivedCache?.maintain()
    }

    func indexedPhotoCount() throws -> Int { try database().counts().total }

    func nextAnalysisEligibilityDate() throws -> Date? { try database().nextAnalysisEligibilityDate() }

    func nextVerificationDate() -> Date? {
        checkpointStore.load()?.fullyVerifiedAt.addingTimeInterval(7 * 24 * 60 * 60)
    }

    func invalidateFullVerification() throws {
        fetch = nil
        cursor = 0
        fullScan = false
        try database().clearVerificationProgress()
    }

    func reanalysisPreview() throws -> CuratorReanalysisPreview {
        let photos = try database().counts().total
        let bytes = (try? derivedCache?.stats().fileBytes) ?? 0
        return CuratorReanalysisPreview(photos: photos, currentCacheBytes: bytes)
    }

    func reanalyzeEntireLibrary() throws -> Int {
        let count = try database().requeueAllAnalysis(analyzer: CuratorVisionAnalyzer.version)
        try derivedCache?.removeAll()
        try StorageMaintenance.removeLegacyDerivedEvidence(at: url.deletingLastPathComponent())
        textCandidates = []
        textCursor = 0
        textScope = nil
        textScanStarted = false
        captionGroups = nil
        captionScope = nil
        captionCursor = 0
        captionRemaining = 0
        captionSweepChanged = false
        projectedGroupingFingerprints.removeAll()
        continuityPairs.removeAll()
        largeWindowCursor.removeAll()
        largeWindowRemaining.removeAll()
        largeWindowScanPending = false
        metadataGeneration += 1
        return count
    }

    func prioritizeAnalysis(_ photos: [IndexedPhoto]) throws {
        let db = try database()
        for photo in photos {
            try db.enqueueAnalysis(asset: photo.id, revision: photo.analysisRevision,
                                   analyzer: CuratorVisionAnalyzer.version,
                                   priority: AdaptiveEvidenceScheduling.viewportPriority)
        }
    }

    private var automaticStore: AutomaticMomentStore {
        AutomaticMomentStore(root: url.deletingLastPathComponent().appendingPathComponent("automatic-moments"), cache: derivedCache)
    }

    private var continuityStore: MomentContinuityStore {
        MomentContinuityStore(root: url.deletingLastPathComponent().appendingPathComponent("event-continuity"), cache: derivedCache)
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
        let checkpoints = LargeMomentWindowStore(root: automaticStore.root, cache: derivedCache)
        let generation = metadataGeneration
        var labels: [String: [String]] = [:], text: [String: [PhotoTextLine]] = [:]
        var results: [String: CuratorVisionResult] = [:]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var digest = SHA256()
        for photo in window.moment.photos {
            try Task.checkCancellation()
            // Vision is required per window photo. Labels/OCR refine when present; missing text
            // must not block large Moments on "Preparing grouping…" for hours.
            guard let data = try database().analysisResult(asset: photo.id, revision: photo.analysisRevision, analyzer: CuratorVisionAnalyzer.version),
                  let result = try? JSONDecoder().decode(CuratorVisionResult.self, from: data),
                  result.version == CuratorVisionAnalyzer.version else {
                try Task.checkCancellation()
                guard generation == metadataGeneration,
                      try GroupReviewStore(url: url.deletingLastPathComponent().appendingPathComponent("group-review.json")).load().revision == reviewRevision else { return false }
                let existed = try checkpoints.completed(window)
                try checkpoints.invalidate(window)
                return existed
            }
            let clues = await context.cachedLabels(photo) ?? []
            let ocr = await textStore.cached(photo)
            labels[photo.id] = clues
            text[photo.id] = ocr?.lines ?? []
            results[photo.id] = result
            digest.update(data: try encoder.encode(photo.id))
            digest.update(data: try encoder.encode(result))
            digest.update(data: try encoder.encode(clues.sorted()))
            digest.update(data: try encoder.encode(ocr?.lines ?? []))
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
            // Vision is required. Labels/OCR refine splits when present; missing text must not
            // leave Moments stuck on "Preparing grouping…" while the analysis queue is long.
            guard let data = try db.analysisResult(asset: photo.id, revision: photo.analysisRevision, analyzer: CuratorVisionAnalyzer.version),
                  let result = try? JSONDecoder().decode(CuratorVisionResult.self, from: data),
                  result.version == CuratorVisionAnalyzer.version else { return false }
            results[photo.id] = result
            labels[photo.id] = await context.cachedLabels(photo) ?? []
            text[photo.id] = await textStore.cached(photo)?.lines ?? []
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

    func journeyTransportSupport(_ photos: [IndexedPhoto]) async throws -> JourneyLocalTransportSupport {
        var support = JourneyLocalTransportSupport()
        for photo in photos where photo.similarityCategory != .screenshots {
            try Task.checkCancellation()
            guard let labels = await context.cachedLabels(photo),
                  let text = await textStore.cached(photo) else { continue }
            support.inspect(labels: labels, lines: text.lines)
        }
        return support
    }

    func prepareText(_ photo: IndexedPhoto, image: CGImage) async throws {
        let store = textStore
        if await store.cached(photo) == nil {
            let lines: [PhotoTextLine]
            do {
                lines = try await store.recognize(image)
            } catch is CancellationError {
                throw CancellationError()
            } catch TextRecognitionFailure.timedOut, TextRecognitionFailure.unavailable {
                // Cache empty OCR so pathological frames do not re-pause the overnight queue.
                lines = []
            } catch {
                lines = []
            }
            _ = try await store.save(lines, for: photo)
        }
        do {
            try await context.capture(photo, image: image)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Label capture is optional evidence; failures must not pause Moment preparation.
        }
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
            let preparedChildren = try continuityStore.apply(children, protected: protection.ids)
            // Project grouping into the catalog before captions. Caption-only refresh loads the
            // prior catalog row and can leave Moments stuck on "Preparing grouping…".
            let groupingSettled = preparedChildren.contains {
                $0.groupingState == .ready || $0.groupingState == .conservative || $0.groupingState == .reviewed
            }
            let fingerprint = (try? AutomaticMomentSegmentation.fingerprint(moment)) ?? moment.id
            if groupingSettled {
                let needsProjection = projectedGroupingFingerprints.insert(fingerprint).inserted
                if grouped || needsProjection {
                    captionSweepChanged = true
                    return .changed
                }
            } else if grouped {
                captionSweepChanged = true
                return .changed
            }
            for prepared in preparedChildren {
                if prepared.groupingKind == .unresolved { continue }
                if try await context.prepare(prepared, model: model) {
                    captionSweepChanged = true
                    // Finish this collection's children before moving back through history.
                    return .presentationChanged(prepared.id)
                }
            }
            captionCursor += 1
            captionRemaining -= 1
        }
        return captionRemaining == 0 && !captionSweepChanged ? .caughtUp : .scanning
    }

    func nextTextCandidate(range: DateInterval?) async throws -> IndexedPhoto? {
        if !textScanStarted || textScope != range {
            let photos = try database().photos(in: range ?? DateInterval(start: .distantPast, end: .distantFuture))
            // Thin-attribute photos first; metadata-rich GPS captures are refinement only.
            textCandidates = photos.sorted {
                let left = AdaptiveEvidenceScheduling.analysisPriority($0)
                let right = AdaptiveEvidenceScheduling.analysisPriority($1)
                if left != right { return left > right }
                return ($0.created ?? .distantPast) > ($1.created ?? .distantPast)
            }
            textCursor = 0
            textScope = range
            textScanStarted = true
        }
        let store = textStore
        while textCursor < textCandidates.count {
            try Task.checkCancellation()
            let photo = textCandidates[textCursor]
            textCursor += 1
            // Screenshots are not Journey evidence; skip expensive OCR/labels.
            if photo.similarityCategory == .screenshots {
                continue
            }
            // GPS-rich captures already curate from metadata; do not burn the soak
            // OCR lane on them while attribute-thin photos still need evidence.
            if AdaptiveEvidenceScheduling.isMetadataRichRefinement(photo) {
                continue
            }
            if await store.cached(photo) == nil { return photo }
            if !(await context.hasLabels(photo)) { return photo }
        }
        return nil
    }

    init(url: URL, cacheURL: URL? = nil) {
        self.url = url
        self.cacheURL = cacheURL ?? url.deletingLastPathComponent().appendingPathComponent("analysis-cache.sqlite3")
    }

    private func database() throws -> CuratorStore {
        if let store { return store }
        let opened = try CuratorStore(url: url)
        store = opened
        return opened
    }

    func batch(range: DateInterval?, restart: Bool, limit: Int = 300) throws -> CuratorBatch {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw NSError(domain: "PhotoCurator.Curator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Full Photos access is required to index the library. The existing index was kept."])
        }
        if restart || fetch == nil {
            metadataGeneration += 1
            textScanStarted = false
            captionGroups = nil
            scanOverrides.removeAll(keepingCapacity: true)
            scanRemovals.removeAll(keepingCapacity: true)
            let options = PHFetchOptions()
            var predicates = [NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)]
            if let range {
                predicates.append(NSPredicate(format: "creationDate >= %@ AND creationDate < %@", range.start as NSDate, range.end as NSDate))
            }
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.includeHiddenAssets = false
            fetch = PHAsset.fetchAssets(with: options)
            fullScan = range == nil
            cursor = 0
            generation = UUID().uuidString
            if fullScan {
                let scope = verificationScope(fetch: fetch!)
                let db = try database()
                if let saved = try db.verificationProgress(),
                   verificationScopeMatches(saved.scope, fetch: fetch!),
                   saved.total == fetch!.count, saved.cursor <= saved.total {
                    cursor = saved.cursor
                    generation = saved.generation
                } else {
                    try db.saveVerificationProgress(VerificationProgress(
                        scope: scope, generation: generation, cursor: 0,
                        total: fetch!.count, updated: Date()))
                }
            }
        }
        guard let fetch else { return CuratorBatch(scanned: 0, total: 0, finished: true) }
        let end = min(cursor + max(25, min(limit, 2_000)), fetch.count)
        let photos = (cursor..<end).compactMap { index -> IndexedPhoto? in
            let asset = fetch.object(at: index)
            guard !scanOverrides.contains(asset.localIdentifier),
                  !scanRemovals.contains(asset.localIdentifier) else { return nil }
            return IndexedPhoto.fromPhotoKit(asset)
        }
        let db = try database()
        let previousByID: [String: IndexedPhoto] = Dictionary(uniqueKeysWithValues: try photos.compactMap { photo in
            try db.photo(id: photo.id).map { (photo.id, $0) }
        })
        try db.save(photos, generation: generation)
        captionGroups = nil
        metadataGeneration += 1
        for photo in photos {
            if let previous = previousByID[photo.id],
               previous.visualContentRevision == photo.visualContentRevision,
               previous.analysisRevision != photo.analysisRevision,
               try db.adoptAnalysisRevision(
                asset: photo.id,
                from: previous.analysisRevision,
                to: photo.analysisRevision,
                analyzer: CuratorVisionAnalyzer.version
               ) {
                continue
            }
            try db.enqueueAnalysis(asset: photo.id, revision: photo.analysisRevision,
                                   analyzer: CuratorVisionAnalyzer.version,
                                   priority: AdaptiveEvidenceScheduling.analysisPriority(photo))
        }
        cursor = end
        if fullScan {
            try db.saveVerificationProgress(VerificationProgress(
                scope: verificationScope(fetch: fetch), generation: generation,
                cursor: cursor, total: fetch.count, updated: Date()))
        }
        let done = cursor == fetch.count
        // A suddenly empty/unavailable library must not erase a previous index.
        if done && fullScan && fetch.count > 0 {
            try db.finishFullScan(generation: generation)
            try checkpointStore.save(PhotoLibraryCheckpoint(
                fingerprint: .current(), fullyVerifiedAt: Date(),
                persistentToken: PhotoLibraryChangeToken.capture()))
            try db.clearVerificationProgress()
        }
        return CuratorBatch(scanned: cursor, total: fetch.count, finished: done)
    }

    private func verificationScope(fetch: PHFetchResult<PHAsset>) -> String {
        if let token = PhotoLibraryChangeToken.capture() {
            return "token:\(token.base64EncodedString())"
        }
        var digest = SHA256()
        digest.update(data: Data("count:\(fetch.count)".utf8))
        let sampleCount = min(12, fetch.count)
        for index in 0..<sampleCount {
            let asset = fetch.object(at: index)
            digest.update(data: Data("|\(asset.localIdentifier)|\(asset.modificationDate?.timeIntervalSince1970 ?? -1)|\(asset.pixelWidth)x\(asset.pixelHeight)".utf8))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func verificationScopeMatches(_ saved: String, fetch: PHFetchResult<PHAsset>) -> Bool {
        if saved.hasPrefix("token:"),
           let data = Data(base64Encoded: String(saved.dropFirst("token:".count))) {
            return PhotoLibraryChangeToken.matchesCurrent(data)
        }
        return saved == verificationScope(fetch: fetch)
    }

    func savedMoments() throws -> [PhotoMoment] {
        try MomentsCatalog.load(from: url.deletingLastPathComponent().appendingPathComponent("moments-catalog.json"))?.moments ?? []
    }

    func catalogMigrationInput() throws -> CatalogV2MigrationInput {
        try CatalogV2Migrator.loadInput(root: url.deletingLastPathComponent())
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
                  protection: MomentGroupingProtection = .init(), preparedPrefix: [PhotoMoment] = []) async throws ->
        (moments: [PhotoMoment], catalogMoments: [PhotoMoment], total: Int, undated: Int,
         available: Int, activeIDs: Set<String>) {
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
        let prepared = Dictionary(uniqueKeysWithValues: moments.map { ($0.id, $0) })
        let catalogMoments = grouped.map { prepared[$0.id] ?? $0 }
        return (moments, catalogMoments, counts.total, counts.undated, grouped.count, Set(grouped.map(\.id)))
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

    /// Re-applies automatic grouping for one Moment so caption sync cannot downgrade `preparing`.
    func withLiveGrouping(_ moment: PhotoMoment, protection: MomentGroupingProtection) throws -> PhotoMoment {
        let applied = try continuityStore.apply(
            automaticStore.apply(moment, protected: protection.ids),
            protected: protection.ids)
        guard let match = applied.first(where: { $0.id == moment.id }) ?? applied.first else { return moment }
        var output = moment
        output.groupingState = match.groupingState
        output.groupingReason = match.groupingReason
        output.groupingKind = match.groupingKind
        output.groupingSource = match.groupingSource
        output.continuityReason = match.continuityReason
        return output
    }

    func claim(range: DateInterval?) throws -> AnalysisJob? { try database().claimAnalysis(range: range) }

    @discardableResult
    func refreshAdaptiveAnalysisPriorities() throws -> Int {
        try database().refreshAdaptiveAnalysisPriorities()
    }
    func similarityPairs(range: DateInterval, category: SimilarityCategory) throws -> [SimilarityPair] {
        let db = try database()
        var pairs: [SimilarityPair] = []
        // Bounded deterministic sample spread across the indexed library, within moments.
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
        try await worker.similarityPairs(
            range: DateInterval(start: .distantPast, end: .distantFuture), category: category)
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
    @Published private(set) var momentSummaries: [MomentSummary] = []
    @Published private(set) var storySummaries: [StorySummary] = []
    @Published private(set) var libraryOverview: [LibraryOverviewPeriod] = []
    @Published private(set) var availableMoments = 0
    @Published private(set) var overviewLoading = false
    private let momentLimit = 200
    @Published private(set) var scanned = 0
    @Published private(set) var scanTotal = 0
    @Published private(set) var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var errorMessage: String?
    @Published private(set) var syncBusy = false
    @Published private(set) var diagnosticRunning = false
    @Published private(set) var maintenanceBusy = false
    @Published private(set) var diagnosticReport = "Tests up to 12 recent photos. No downloads, uploads, or album changes."
    private var diagnosticTask: Task<Void, Never>?
    private var syncSubscription: AnyCancellable?

    private let worker: CuratorWorker
    private let catalog: CatalogV2Store?
    private lazy var publicationCoordinator: PublicationCoordinator? = catalog.map {
        PublicationCoordinator(store: $0, adapter: PhotoKitAlbumAdapter.shared)
    }
    private let scheduler = CurationScheduler()
    private lazy var library = LibraryCoordinator { [scheduler] in
        Task { await scheduler.wake(.libraryChanged) }
    }
    private var schedulerTask: Task<Void, Never>?
    private var policySubscriptions = Set<AnyCancellable>()
    private var batchRunning = false
    private var restartRequested = false
    private var backgroundNeedsScan = false
    private var revision = 0
    private var lastOverview = Date.distantPast
    private var metadataReady = false
    private var startupStateLoaded = false
    private var nextReconciliationAnalysisStep = 4
    private var analysisTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var viewportPrioritySignatures = Set<String>()
    private(set) var analyzedThisSession = 0
    private(set) var deferredThisSession = 0
    private lazy var analysisLoader = CuratorThumbnailLoader(provider: PhotoKitThumbnailProvider())
    private let analyzer = CuratorVisionAnalyzer()
    private var contextStep = 0
    private var lastWaitLog = Date.distantPast
    private var systemSleeping = false
    private var maintenancePaused = false

    @Published var autoPublishEnabled: Bool
    private var publishingMomentIDs: Set<String> = []
    private var failedAutoPublishMomentIDs: Set<String> = []
    private var isPublishingInBackground = false

    private func logWait(_ code: Int) {
        guard Date().timeIntervalSince(lastWaitLog) >= 60 else { return }
        lastWaitLog = Date()
        CuratorTelemetry.shared.record(.waiting, counts: ["reason": code])
    }

    private func startScheduler() {
        schedulerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let events = await scheduler.next()
                guard !events.isEmpty, !Task.isCancelled else { return }
                await scheduleWork(for: events)
            }
        }
    }

    private func wakeScheduler(_ event: CurationScheduler.Event) {
        Task { await scheduler.wake(event) }
    }

    private func observePolicyChanges() {
        let center = NotificationCenter.default
        [Notification.Name("NSProcessInfoPowerStateDidChange"),
         Notification.Name("NSProcessInfoThermalStateDidChange"),
         NSApplication.didBecomeActiveNotification,
         .photoCuratorPhotosAccessChanged].forEach { name in
            center.publisher(for: name).sink { [weak self] _ in
                self?.wakeScheduler(.policyChanged)
            }.store(in: &policySubscriptions)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        [NSWorkspace.didWakeNotification, NSWorkspace.willSleepNotification].forEach { name in
            workspace.publisher(for: name).sink { [weak self] note in
                guard let self else { return }
                self.systemSleeping = note.name == NSWorkspace.willSleepNotification
                if self.systemSleeping { self.analysisTask?.cancel() }
                self.wakeScheduler(.policyChanged)
            }.store(in: &policySubscriptions)
        }
    }

    init(model: PhotoCuratorViewModel) {
        enabled = UserDefaults.standard.bool(forKey: "curatorEnabled")
        if let operation = try? CuratorResetJournal.production().load(), operation.phase != .completed {
            enabled = false
            maintenancePaused = true
            activity = "Resuming the requested Photo Curator reset…"
        }
        autoPublishEnabled = CuratorPolicy.automaticPublicationEnabled()
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Curator/curator/index.sqlite3")
        worker = CuratorWorker(url: url, cacheURL: DerivedCacheStore.productionURL())
        catalog = try? CatalogV2Store(url: url.deletingLastPathComponent()
            .appendingPathComponent(CatalogV2Migrator.catalogName))
        CuratorTelemetry.shared.record(.launch, counts: ["enabled": enabled ? 1 : 0])
        Task.detached(priority: .utility) {
            StorageMaintenance.run()
            StorageMaintenance.migrateLegacyEvidence()
        }
        Task {
            guard !maintenancePaused else { return }
            if let catalog {
                do {
                    let input = try await worker.catalogMigrationInput()
                    _ = try await catalog.migrate(input)
                    try await catalog.prepareWorkspace(input)
                    let rescored = try await worker.refreshAdaptiveAnalysisPriorities()
                    CuratorTelemetry.shared.record(.catalog, counts: ["adaptiveRescored": rescored])
                    let storiesEmpty = try await catalog.storySummaries().isEmpty
                    let membershipMissing = try await catalog.needsStoryProjection()
                    if storiesEmpty || membershipMissing {
                        try await catalog.rebuildStories()
                    }
                    if let publicationCoordinator {
                        let recoveries = await publicationCoordinator.recoverPending()
                        for result in recoveries.values {
                            if case .failure(let error) = result,
                               error as? PublicationFailure != .verificationPending {
                                CuratorTelemetry.shared.record(.failure,
                                    counts: ["code": (error as NSError).code])
                            }
                        }
                    }
                    await reloadMomentSummaries(googleUploadedAssetIDs: model.uploadedGoogleAssetIDs)
                } catch {
                    CuratorTelemetry.shared.record(.failure, counts: ["code": (error as NSError).code])
                }
            }
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
                if needsReconciliation { self.nextReconciliationAnalysisStep = self.contextStep }
                self.startupStateLoaded = true
                self.wakeScheduler(.startup)
                Task {
                    if let date = await self.worker.nextVerificationDate() {
                        await self.scheduler.wake(.verificationDue, at: date)
                    }
                }
            }
        }
        syncSubscription = model.$isWorking.sink { [weak self] busy in
            self?.syncBusy = busy
            if busy { self?.analysisTask?.cancel() }
            self?.wakeScheduler(.policyChanged)
        }
        startScheduler()
        observePolicyChanges()
        if !maintenancePaused { Task { await refreshOverview(reusingVisibleMoments: true, projectCompleteCatalog: true) } }
        if maintenancePaused {
            Task { await resumeInterruptedResetIfNeeded() }
        }
    }

    func setAutoPublishEnabled(_ value: Bool) {
        autoPublishEnabled = value
        UserDefaults.standard.set(value, forKey: "curatorAutoPublish")
        wakeScheduler(.policyChanged)
    }

    func journeyPlaceNamingChanged() {
        wakeScheduler(.policyChanged)
    }

    func nuclearResetPreview() async throws -> CuratorResetPreview {
        guard !syncBusy else {
            throw NSError(domain: "PhotoCurator.Reset", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Wait for the current Google operation to finish before resetting."])
        }
        guard let catalog else { throw PublicationFailure.catalogUnavailable }
        let containers = try await catalog.managedPhotoContainers()
        let publications = try await catalog.publicationCount()
        let local = CuratorLocalDataReset.production()
        let bytes = await Task.detached(priority: .utility) { local.reclaimableBytes() }.value
        let library = try await PhotoKitAlbumAdapter.shared.assetCounts()
        return CuratorResetPreview(containers: containers, publishedAlbums: publications,
            reclaimableBytes: bytes, library: library)
    }

    func entireLibraryReanalysisPreview() async throws -> CuratorReanalysisPreview {
        guard !syncBusy, !maintenanceBusy else { throw PublicationFailure.conflictingOperation }
        return try await worker.reanalysisPreview()
    }

    func buildLatestCurationCandidate() async throws -> CurationRebuildPreview {
        guard !maintenanceBusy, !syncBusy, let catalog else {
            throw PublicationFailure.conflictingOperation
        }
        maintenanceBusy = true
        maintenancePaused = true
        activity = "Building a shadow curation from existing evidence…"
        analysisTask?.cancel()
        metadataTask?.cancel()
        let analysis = analysisTask
        let metadata = metadataTask
        await analysis?.value
        await metadata?.value
        var candidateID: String?
        do {
            let protection = MomentGroupingProtection.load(.standard)
            let activeMoments = try await worker.preparedCatalog(protection: protection)
            let saved = try await catalog.activeGeneration()?.metrics
            let activeMetrics = HolisticLibraryMetrics.measure(activeMoments,
                falseJoins: saved?.falseJoinCount, falseSplits: saved?.falseSplitCount)
            let active = try await catalog.snapshotActiveGeneration(algorithmVersion: "shipping-v1",
                evidenceVersion: CuratorVisionAnalyzer.version, metrics: activeMetrics)
            let candidateMoments = HolisticCurationGenerator.refiningRoutineSingletons(activeMoments,
                places: MeaningfulPlacesStore.snapshot(), protectedMomentIDs: protection.ids)
            let candidateMetrics = HolisticLibraryMetrics.measure(candidateMoments)
            let generation = try await catalog.beginCandidateGeneration(
                algorithmVersion: HolisticCurationGenerator.algorithmVersion,
                evidenceVersion: CuratorVisionAnalyzer.version, sourceGenerationID: active.id)
            candidateID = generation.id
            try await catalog.stageCandidateGeneration(id: generation.id, moments: candidateMoments,
                metrics: candidateMetrics)
            let comparison = CurationGenerationComparison.compare(active: activeMetrics,
                candidate: candidateMetrics)
            maintenancePaused = false
            maintenanceBusy = false
            activity = "Shadow curation ready for comparison. Active Moments were not changed."
            wakeScheduler(.policyChanged)
            return CurationRebuildPreview(generationID: generation.id, comparison: comparison)
        } catch {
            if let candidateID { try? await catalog.failGeneration(id: candidateID, reason: error.localizedDescription) }
            maintenancePaused = false
            maintenanceBusy = false
            wakeScheduler(.policyChanged)
            throw error
        }
    }

    func reanalyzeEntireLibrary(_ preview: CuratorReanalysisPreview) async throws {
        guard !maintenanceBusy, !syncBusy else { throw PublicationFailure.conflictingOperation }
        guard try await worker.reanalysisPreview().photos == preview.photos else {
            throw NSError(domain: "PhotoCurator.Reanalysis", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The indexed library changed after this estimate was prepared. Review the updated estimate and confirm again."])
        }
        maintenanceBusy = true
        maintenancePaused = true
        activity = "Preparing a fresh local analysis…"
        analysisTask?.cancel()
        metadataTask?.cancel()
        let analysis = analysisTask
        let metadata = metadataTask
        await analysis?.value
        await metadata?.value
        do {
            let queued = try await worker.reanalyzeEntireLibrary()
            analyzedThisSession = 0
            deferredThisSession = 0
            contextStep = 0
            revision += 1
            metadataReady = indexedCount > 0
            maintenancePaused = false
            maintenanceBusy = false
            activity = "Fresh local analysis queued for \(queued.formatted()) photos."
            wakeScheduler(.userRequested)
        } catch {
            maintenancePaused = false
            maintenanceBusy = false
            wakeScheduler(.policyChanged)
            throw error
        }
    }

    func performNuclearReset(_ preview: CuratorResetPreview) async throws {
        guard !maintenanceBusy, !syncBusy else { throw PublicationFailure.conflictingOperation }
        let current = try await nuclearResetPreview()
        guard current.containers == preview.containers,
              current.publishedAlbums == preview.publishedAlbums,
              current.library == preview.library else {
            throw NSError(domain: "PhotoCurator.Reset", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The library changed after the reset summary was prepared. Review the updated summary and confirm again."])
        }
        maintenanceBusy = true
        maintenancePaused = true
        activity = "Pausing Photo Curator safely…"
        analysisTask?.cancel()
        metadataTask?.cancel()
        diagnosticTask?.cancel()
        // Local workers may be inside an uncooperative Vision request. The catalog is
        // erased only after relaunch, so reset must not wait for those tasks to unwind.
        await library.stop()

        do {
            let local = CuratorLocalDataReset.production()
            let coordinator = CuratorResetCoordinator(photos: PhotoKitAlbumAdapter.shared,
                localData: local, journal: .production())
            _ = try await coordinator.begin(containers: preview.containers,
                reclaimableBytes: preview.reclaimableBytes)
            let operation = try await coordinator.resumeThroughPhotos()
            guard operation.phase == .erasingLocalData else {
                throw PublicationFailure.verificationPending
            }
            activity = "Reset verified. Photo Curator will reopen to rebuild from zero."
            await scheduler.stop()
            schedulerTask?.cancel()
            // Sheet must dismiss before quit; caller closes UI then relaunches.
        } catch {
            maintenancePaused = false
            maintenanceBusy = false
            wakeScheduler(.policyChanged)
            throw error
        }
    }

    /// Ends the modal reset sheet path: dismiss UI first, then call this.
    @MainActor
    func quitAndRelaunchAfterReset() {
        PhotoCuratorRelaunch.quitAndRelaunch()
    }

    private func resumeInterruptedResetIfNeeded() async {
        guard let operation = try? CuratorResetJournal.production().load(), operation.phase != .completed else {
            maintenancePaused = false
            return
        }
        guard operation.phase == .requested || operation.phase == .deletingContainers ||
                operation.phase == .verifyingPhotos else {
            maintenanceBusy = false
            errorMessage = "Photo Curator could not recreate its local catalog. Your Photos library was left intact; reopen Settings after resolving the storage error."
            return
        }
        maintenanceBusy = true
        do {
            let local = CuratorLocalDataReset.production()
            let coordinator = CuratorResetCoordinator(photos: PhotoKitAlbumAdapter.shared,
                localData: local, journal: .production())
            let updated = try await coordinator.resumeThroughPhotos()
            if updated.phase == .erasingLocalData || updated.phase == .recreatingCatalog {
                activity = "Reset verified. Photo Curator will reopen to rebuild from zero."
                await scheduler.stop()
                schedulerTask?.cancel()
                PhotoCuratorRelaunch.quitAndRelaunch()
            }
        } catch {
            maintenanceBusy = false
            errorMessage = "Photo Curator could not resume the reset: \(error.localizedDescription)"
        }
    }

    func setFavorite(_ favorite: Bool, photoID: String) async throws {
        guard !maintenancePaused else { throw PublicationFailure.conflictingOperation }
        let operation = UUID()
        await library.expect(operation: operation, assetIDs: [photoID], effect: .update)
        do {
            try await PhotoKitAssetEditor.shared.setFavorite(favorite, assetID: photoID)
        } catch {
            await library.cancelExpected(operation: operation)
            throw error
        }
        try await worker.reconcileEditedAsset(photoID)
        try? await worker.refreshCheckpointFingerprint()
        await refreshOverview()
        wakeScheduler(.workCompleted)
    }

    func moveToRecentlyDeleted(photoID: String) async throws {
        guard !maintenancePaused else { throw PublicationFailure.conflictingOperation }
        let operation = UUID()
        await library.expect(operation: operation, assetIDs: [photoID], effect: .removal)
        do {
            try await PhotoKitAssetEditor.shared.moveToRecentlyDeleted(assetID: photoID)
        } catch {
            await library.cancelExpected(operation: operation)
            throw error
        }
        try await worker.removeDeletedAsset(photoID)
        try? await worker.refreshCheckpointFingerprint()
        await refreshOverview()
        wakeScheduler(.workCompleted)
    }

    func mergeMoments(_ source: [PhotoMoment], title: String, decisions: MomentReviewDecisions,
                      expectedRevision: Int) async throws {
        guard !maintenancePaused else { throw PublicationFailure.conflictingOperation }
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
                    if needsReconciliation { self.nextReconciliationAnalysisStep = self.contextStep }
                    self.revision += 1
                    self.wakeScheduler(.userRequested)
                }
            }
        } else {
            enabled = false
            CuratorTelemetry.shared.record(.paused)
            analysisTask?.cancel()
            metadataTask?.cancel()
            UserDefaults.standard.set(false, forKey: "curatorEnabled")
            activity = "Background curation is paused. Your index is kept."
        }
    }

    func stopDiagnostic() { diagnosticTask?.cancel() }

    func runDiagnostic() {
        guard !diagnosticRunning, !batchRunning, !syncBusy else { return }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            diagnosticReport = "Allow Photo Curator access in System Settings > Privacy & Security > Photos. Full Disk Access is not needed."
            return
        }
        diagnosticRunning = true
        diagnosticReport = "Checking local photos..."
        diagnosticTask = Task {
            defer {
                diagnosticRunning = false
                diagnosticTask = nil
                wakeScheduler(.workCompleted)
            }
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
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

    func refreshOverview(reusingVisibleMoments: Bool = false, projectCompleteCatalog: Bool = false) async {
        guard !overviewLoading else { return }
        let interval = CuratorPerformance.begin("Moment overview")
        defer { CuratorPerformance.end("Moment overview", interval) }
        overviewLoading = true
        defer { overviewLoading = false }
        let range = DateInterval(start: .distantPast, end: .distantFuture)
        do {
            // A permission prompt must not change or persist selection state.
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
            if let catalog {
                let projectionIsIncomplete = momentSummaries.count != overview.available
                try await catalog.synchronize(
                    moments: projectCompleteCatalog || projectionIsIncomplete
                        ? overview.catalogMoments : overview.moments,
                    activeMomentIDs: overview.activeIDs)
                await reloadMomentSummaries()
            }
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
        } catch let error as DecodingError {
            // Legacy payloads or corrupt derived caches must not block Moments with a modal.
            CuratorTelemetry.shared.record(.failure, counts: ["code": (error as NSError).code])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadMomentSummaries(googleUploadedAssetIDs: Set<String> = [],
                               reviewDecisions: [String: ReviewDecision] = [:]) async {
        guard let catalog else { return }
        let interval = CuratorPerformance.begin("Moment summary query")
        defer { CuratorPerformance.end("Moment summary query", interval) }
        do {
            let previousStories = storySummaries
            momentSummaries = try await catalog.summaries(googleUploadedAssetIDs: googleUploadedAssetIDs,
                                                          reviewDecisions: reviewDecisions)
            if try await catalog.needsStoryProjection() {
                try await catalog.rebuildStories()
            }
            let nextStories = try await catalog.storySummaries()
            // Keep prior Journey membership if a mid-rebuild read returns empty shells.
            if nextStories.contains(where: { !$0.momentIDs.isEmpty })
                || previousStories.allSatisfy({ $0.momentIDs.isEmpty }) {
                storySummaries = nextStories
            }
            libraryOverview = HolisticLibraryOverview.periods(momentSummaries)
            availableMoments = momentSummaries.count
        } catch is CancellationError {
            return
        } catch let error as DecodingError {
            CuratorTelemetry.shared.record(.failure, counts: ["code": (error as NSError).code])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func momentDetail(_ id: String) async -> PhotoMoment? {
        let interval = CuratorPerformance.begin("Moment detail query")
        defer { CuratorPerformance.end("Moment detail query", interval) }
        if let catalog {
            do {
                if let detail = try await catalog.detail(momentID: id) { return detail }
            } catch {
                errorMessage = "Could not open this Moment (\(error.localizedDescription))."
                return nil
            }
        }
        return moments.first(where: { $0.id == id })
    }

    func momentDetails(_ ids: Set<String>) async -> [PhotoMoment] {
        var result: [PhotoMoment] = []
        for id in ids {
            if let detail = await momentDetail(id) { result.append(detail) }
        }
        return result.sorted { $0.start > $1.start }
    }

    func prioritizeVisibleMoment(_ moment: PhotoMoment, photos: [IndexedPhoto]) async {
        guard enabled, !photos.isEmpty else { return }
        let revisions = photos.map { "\($0.id):\($0.analysisRevision)" }.joined(separator: "|")
        let signature = "\(moment.id)|\(revisions)"
        guard viewportPrioritySignatures.insert(signature).inserted else { return }
        do {
            try await worker.prioritizeAnalysis(photos)
            wakeScheduler(.userRequested)
        } catch {
            viewportPrioritySignatures.remove(signature)
            CuratorTelemetry.shared.record(.failure, counts: ["code": (error as NSError).code])
        }
    }

    private func refreshVisibleMoment(_ id: String) async {
        guard let original = await momentDetail(id) else { return }
        let thresholds = similarityThresholds
        let balanced = balancedSelection
        do {
            var updated = try await worker.refreshedPresentation(original, thresholds: thresholds,
                                                                 balanced: balanced)
            updated = try await worker.withLiveGrouping(updated,
                protection: MomentGroupingProtection.load(.standard))
            guard similarityThresholds == thresholds, balancedSelection == balanced else { return }
            if let index = moments.firstIndex(where: { $0.id == id }) { moments[index] = updated }
            try await catalog?.synchronize(moments: [updated])
            await reloadMomentSummaries()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func authorize(_ action: @MainActor @escaping @Sendable () -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized { action(); return }
        guard status == .notDetermined else {
            errorMessage = "Allow full Photos access in System Settings > Privacy & Security > Photos before indexing."
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            Task { @MainActor in
                if status == .authorized {
                    NotificationCenter.default.post(name: .photoCuratorPhotosAccessChanged, object: nil)
                    action()
                }
                else { self.errorMessage = "Photos access was not granted. No scanning has started." }
            }
        }
    }

    private func scheduleWork(for events: Set<CurationScheduler.Event>) async {
        guard !maintenancePaused else { return }
        guard !diagnosticRunning else { return }
        guard startupStateLoaded else { return }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            activity = "Waiting for full Photos access. Open Moments to enable it."
            logWait(1)
            return
        }
        await library.start(since: await worker.checkpointChangeToken())
        guard !batchRunning else { return }

        let changes = await library.drain(limit: 100)
        if changes != .empty {
            CuratorTelemetry.shared.record(.libraryChange, counts: [
                "updated": changes.updated.count, "removed": changes.removed.count,
                "full": changes.requiresVerification ? 1 : 0
            ])
            do {
                if changes.requiresVerification {
                    try await worker.invalidateFullVerification()
                    backgroundNeedsScan = true
                    restartRequested = true
                    nextReconciliationAnalysisStep = contextStep
                }
                for id in changes.removed { try await worker.removeDeletedAsset(id) }
                var metadataChanged = !changes.removed.isEmpty
                for id in changes.updated {
                    if try await worker.reconcileEditedAsset(id) { metadataChanged = true }
                }
                if metadataChanged {
                    try await worker.refreshCheckpointFingerprint()
                    await refreshOverview()
                }
                if let token = changes.changeToken {
                    try await worker.advanceVerificationScope(to: token)
                    try await worker.commitLibraryChangeToken(token)
                    await library.commit(changeToken: token)
                }
            } catch {
                backgroundNeedsScan = true
                restartRequested = true
                nextReconciliationAnalysisStep = contextStep
            }
            if changes.hasMore { wakeScheduler(.libraryChanged) }
        }

        if events.contains(.verificationDue) {
            let indexed = (try? await worker.indexedPhotoCount()) ?? 0
            if await worker.startupRequiresFullReconciliation(indexedCount: indexed) {
                backgroundNeedsScan = true
                restartRequested = true
                nextReconciliationAnalysisStep = contextStep
            } else if let date = await worker.nextVerificationDate() {
                await scheduler.wake(.verificationDue, at: date)
            }
        }

        guard enabled else { return }
        if systemSleeping {
            activity = "Paused while your Mac is asleep."
            return
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
        if CuratorPolicy.shouldRunMetadata(metadataReady: metadataReady,
                                           reconciliationNeeded: backgroundNeedsScan,
                                           reconciliationDue: reconciliationDue) {
            let currentRevision = revision
            let restart = restartRequested
            restartRequested = false
            batchRunning = true
            metadataTask = Task {
                let interval = CuratorPerformance.begin("Metadata batch")
                defer { CuratorPerformance.end("Metadata batch", interval) }
                defer {
                    batchRunning = false
                    metadataTask = nil
                    wakeScheduler(.workCompleted)
                }
                do {
                    let result = try await worker.batch(range: nil, restart: restart, limit: 100)
                    guard currentRevision == revision else { return }
                    scanned = result.scanned
                    scanTotal = result.total
                    CuratorTelemetry.shared.record(.metadata, counts: ["scanned": result.scanned, "total": result.total])
                    activity = "Checking library changes: \(result.scanned.formatted()) of \(result.total.formatted())"
                    if result.finished {
                        metadataReady = true
                        backgroundNeedsScan = false
                        activity = "Metadata ready. Preparing local visual analysis."
                        if let date = await worker.nextVerificationDate() {
                            await library.resetToCurrentToken()
                            await scheduler.wake(.verificationDue, at: date)
                        }
                    } else {
                        nextReconciliationAnalysisStep = contextStep + 4
                    }
                    if result.finished { await refreshOverview(projectCompleteCatalog: true) }
                } catch {
                    activity = "Curator paused: \(error.localizedDescription)"
                    enabled = false
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
            let mayPublish = CuratorPolicy.mayRunAutomaticPublication(idleSeconds: idle)
            runAnalysisStep(allowAutomaticPublication: mayPublish)
            return
        }
        activity = "Metadata is up to date. Watching for changes in Photos."
    }

    /// Vision OCR / text reader failures should never halt overnight Moment preparation.
    private func softEvidenceFailure(_ error: Error) -> Bool {
        let ns = error as NSError
        let domain = ns.domain.lowercased()
        return domain.contains("textrecognition")
            || domain.contains("crimagereader")
            || domain.contains("vision")
            || ns.localizedDescription.localizedCaseInsensitiveContains("TextRecognition")
            || ns.localizedDescription.localizedCaseInsensitiveContains("CRImageReader")
    }

    private func runAnalysisStep(allowAutomaticPublication: Bool) {
        let token = revision
        let analysisActivity = "Analyzing photos and refining Moments…"
        if activity != analysisActivity {
            activity = analysisActivity
        }
        batchRunning = true
        analysisTask = Task(priority: .utility) {
            let interval = CuratorPerformance.begin("Analysis step")
            defer { CuratorPerformance.end("Analysis step", interval) }
            var caughtUp = false
            var failedBeforeClaim = false
            defer {
                batchRunning = false
                analysisTask = nil
                if CuratorPolicy.shouldContinueAnalysis(caughtUp: caughtUp, failedBeforeClaim: failedBeforeClaim) {
                    if token == revision { wakeScheduler(.workCompleted) }
                }
            }
            var claimed: AnalysisJob?
            do {
                contextStep += 1
                if contextStep % 8 == 0 {
                    let step = try await worker.prepareMoments(range: nil, protection: MomentGroupingProtection.load(.standard))
                    try Task.checkCancellation()
                    guard token == revision else { return }
                    if case .presentationChanged(let id) = step {
                        await refreshVisibleMoment(id)
                        return
                    }
                    if step == .changed {
                        await refreshOverview(projectCompleteCatalog: true)
                        return
                    }
                }
                if allowAutomaticPublication && autoPublishEnabled && contextStep % 10 == 0 {
                    if await autoPublishNextReadyMoment() {
                        return
                    }
                }
                // Cheap Journey naming before OCR: every 15th step is also a multiple of 5,
                // so geocode must run first or OCR starved it for the whole soak.
                if contextStep % 15 == 0 {
                    let journeyNames = UserDefaults.standard.object(forKey: "curatorJourneyPlaceNames") == nil
                        || UserDefaults.standard.bool(forKey: "curatorJourneyPlaceNames")
                    if journeyNames, let catalog {
                        let enrichment = try await catalog.enrichJourneyStops()
                        CuratorTelemetry.shared.record(.catalog, counts: [
                            "journeyLookups": enrichment.attempted,
                            "journeyUpdates": enrichment.updated
                        ])
                        if enrichment.updated > 0 {
                            storySummaries = try await catalog.storySummaries()
                            return
                        }
                        if enrichment.hasMore {
                            await scheduler.wake(.retryDue, at: Date().addingTimeInterval(5))
                        }
                    }
                }
                // Interleave OCR/label capture while Vision jobs remain, otherwise Moments wait
                // hours for an empty analysis queue before any text evidence arrives.
                // Candidates are thin-attributes-first and skip GPS-rich refinement.
                if contextStep % 5 == 0, let photo = try await worker.nextTextCandidate(range: nil) {
                    let image = try await analysisLoader.load(assetID: photo.id, timeout: 8)
                    try Task.checkCancellation()
                    guard token == revision else { return }
                    try await worker.prepareText(photo, image: image)
                    return
                }
                guard let job = try await worker.claim(range: nil) else {
                    guard token == revision else { return }
                    if let photo = try await worker.nextTextCandidate(range: nil) {
                        let image = try await analysisLoader.load(assetID: photo.id, timeout: 8)
                        try Task.checkCancellation()
                        guard token == revision else { return }
                        try await worker.prepareText(photo, image: image)
                        return
                    }
                    let step = try await worker.prepareMoments(range: nil, protection: MomentGroupingProtection.load(.standard))
                    try Task.checkCancellation()
                    guard token == revision else { return }
                    if step != .caughtUp {
                        if case .presentationChanged(let id) = step { await refreshVisibleMoment(id) }
                        else if step == .changed { await refreshOverview(projectCompleteCatalog: true) }
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
                    await refreshOverview(reusingVisibleMoments: true, projectCompleteCatalog: true)
                    if let catalog {
                        let transport = try await catalog.enrichJourneyTransport { [worker] photos in
                            try await worker.journeyTransportSupport(photos)
                        }
                        if transport.updated { storySummaries = try await catalog.storySummaries() }
                        if transport.hasMore {
                            await scheduler.wake(.retryDue, at: Date().addingTimeInterval(5))
                        } else if transport.attempted {
                            await scheduler.wake(.retryDue, at: Date().addingTimeInterval(3600))
                        }
                    }
                    let journeyNames = UserDefaults.standard.object(forKey: "curatorJourneyPlaceNames") == nil
                        || UserDefaults.standard.bool(forKey: "curatorJourneyPlaceNames")
                    if journeyNames, let catalog {
                        let enrichment = try await catalog.enrichJourneyStops()
                        if enrichment.updated > 0 {
                            storySummaries = try await catalog.storySummaries()
                        }
                        CuratorTelemetry.shared.record(.catalog, counts: [
                            "journeyLookups": enrichment.attempted,
                            "journeyUpdates": enrichment.updated
                        ])
                        if enrichment.hasMore {
                            await scheduler.wake(.retryDue, at: Date().addingTimeInterval(5))
                        } else if enrichment.attempted > 0 {
                            await scheduler.wake(.retryDue, at: Date().addingTimeInterval(3600))
                        }
                    }
                    if let retry = try await worker.nextAnalysisEligibilityDate() {
                        await scheduler.wake(.retryDue, at: retry)
                    }
                    if autoPublishEnabled && !allowAutomaticPublication {
                        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                            eventType: CGEventType(rawValue: UInt32.max)!)
                        if idle.isFinite {
                            await scheduler.wake(.policyChanged,
                                at: Date().addingTimeInterval(max(1, 120 - idle)))
                        }
                    }
                    if backgroundNeedsScan {
                        nextReconciliationAnalysisStep = contextStep
                        wakeScheduler(.workCompleted)
                    }
                    return
                }
                claimed = job
                try Task.checkCancellation()
                guard try await worker.currentAnalysisPhoto(job) != nil else { return }
                let image = try await analysisLoader.load(assetID: job.asset, timeout: 8)
                let result = try await analyzer.analyze(image)
                try Task.checkCancellation()
                guard token == revision else { try await worker.release(job); return }
                // An edit since enqueue must never be saved under an old fingerprint.
                guard let photo = try await worker.currentAnalysisPhoto(job) else { return }
                try await worker.prepareText(photo, image: image)
                try Task.checkCancellation()
                guard token == revision else { try await worker.release(job); return }
                guard try await worker.currentAnalysisPhoto(job) != nil else { return }
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
                    } else if error is TextRecognitionFailure
                                || softEvidenceFailure(error) {
                        // OCR/label evidence gaps are expected; never pause the soak queue on them.
                        deferredThisSession += 1
                        CuratorTelemetry.shared.record(.failure, counts: ["code": (error as NSError).code])
                    } else {
                        failedBeforeClaim = true
                        CuratorTelemetry.shared.record(.failure, counts: ["code": (error as NSError).code])
                        activity = "Moment preparation paused: \(error.localizedDescription)"
                        await scheduler.wake(.retryDue, at: Date().addingTimeInterval(60))
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
        } catch PublicationFailure.verificationPending {
            activity = "Photos is confirming the album for \(title)…"
            await scheduler.wake(.retryDue, at: Date().addingTimeInterval(2))
            return true
        } catch {
            failedAutoPublishMomentIDs.insert(candidate.id)
            CuratorTelemetry.shared.record(.failure, counts: ["code": (error as NSError).code])
            return false
        }
    }

    func publishToPhotos(moment: PhotoMoment, decisions: MomentReviewDecisions) async throws -> CuratedAlbumReceipt {
        guard !maintenancePaused else { throw PublicationFailure.conflictingOperation }
        let interval = CuratorPerformance.begin("Photos publication")
        defer { CuratorPerformance.end("Photos publication", interval) }
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

        guard let publicationCoordinator else { throw PublicationFailure.catalogUnavailable }
        let storyFolder = try await catalog?.storyContaining(momentID: moment.id)
        let request = CuratedPublicationRequest(
            operationID: UUID(),
            momentID: moment.id,
            title: title,
            description: story,
            keyAssetID: keyAssetID,
            date: moment.start,
            storyTitle: storyFolder?.title,
            storyStart: storyFolder?.start,
            assetIDs: assetIDs
        )

        let receipt = try await publicationCoordinator.publish(request)

        let publishedDate = Date()
        await reloadMomentSummaries()
        if let idx = moments.firstIndex(where: { $0.id == moment.id }) {
            moments[idx].publishedAlbumID = receipt.albumID
            moments[idx].publishedDate = publishedDate
        }
        return receipt
    }
}
