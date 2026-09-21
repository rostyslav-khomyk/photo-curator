import SwiftUI
import Vision

actor GroupingEvidenceSession {
    private var visuals: [String: CuratorVisionResult] = [:]
    private var text: [String: [PhotoTextLine]] = [:]
    private var database: CuratorStore?
    private var distances: [String: [String: Float]] = [:]
    private var distanceCount = 0
    private var scenes: [String: SemanticSceneEvidence] = [:]

    func classify(_ photo: IndexedPhoto, image: CGImage) throws {
        try Task.checkCancellation()
        guard image.width <= 1024, image.height <= 1024 else { throw NarrativeFailure.invalidMetadata }
        let request = VNClassifyImageRequest()
        request.revision = 2
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        try Task.checkCancellation()
        scenes[photo.id] = SemanticSceneEvidence.from(Dictionary(
            (request.results ?? []).map { ($0.identifier, $0.confidence) }, uniquingKeysWith: max))
    }

    func inspect(_ photo: IndexedPhoto, image: CGImage, lines: [PhotoTextLine]) throws {
        try Task.checkCancellation()
        guard image.width <= 1024, image.height <= 1024 else { throw NarrativeFailure.invalidMetadata }
        try classify(photo, image: image)
        text[photo.id] = lines
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = 1
        request.imageCropAndScaleOption = .scaleFit
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        guard let result = request.results?.first else { throw NarrativeFailure.invalidResponse }
        let data = try NSKeyedArchiver.archivedData(withRootObject: result, requiringSecureCoding: true)
        visuals[photo.id] = CuratorVisionResult(version: CuratorVisionAnalyzer.version,
            faces: .unavailable, aesthetics: .unavailable, featurePrint: .available(data))
        distances.removeAll()
        distanceCount = 0
    }

    func cachedVisual(_ photo: IndexedPhoto, root: URL, lines: [PhotoTextLine]) -> Bool {
        text[photo.id] = lines
        do {
            if database == nil { database = try CuratorStore(url: root.appendingPathComponent("index.sqlite3")) }
            if let data = try database?.analysisResult(asset: photo.id, revision: photo.analysisRevision,
                                                      analyzer: CuratorVisionAnalyzer.version),
               let result = try? JSONDecoder().decode(CuratorVisionResult.self, from: data),
               result.version == CuratorVisionAnalyzer.version,
               case .available = result.featurePrint {
                visuals[photo.id] = result
                return true
            }
        } catch { /* A cache miss must not prevent local inspection. */ }
        return false
    }

    func proposal(_ photos: [IndexedPhoto], cutoff: Float) throws -> GroupingProposal {
        try Task.checkCancellation()
        let value = EvidenceGrouping.propose(photos, text: text, cutoff: cutoff, scenes: scenes) { a, b in
            if let cached = distances[a]?[b] ?? distances[b]?[a] { return cached }
            guard let lhs = visuals[a], let rhs = visuals[b] else { return nil }
            guard let value = try? lhs.distance(to: rhs) else { return nil }
            if distanceCount < 8192 {
                distances[a, default: [:]][b] = value
                distanceCount += 1
            }
            return value
        }
        try Task.checkCancellation()
        return value
    }
}

struct GroupingSuggestionsView: View {
    let moment: PhotoMoment
    @Environment(\.dismiss) private var dismiss
    @State private var session = GroupingEvidenceSession()
    @State private var proposal: GroupingProposal?
    @State private var status = "Preparing local evidence..."
    @State private var ready = false
    @State private var cutoff: Float = EvidenceGrouping.defaultCutoff
    @State private var enlarged: IndexedPhoto?
    @State private var archive = GroupReviewArchive()
    @State private var selectedGroups = Set<String>()
    @State private var selectedPhotos = Set<String>()
    @State private var dirty = false
    @State private var editError: String?
    @State private var confirmDiscard = false

    private var reviewStore: GroupReviewStore {
        GroupReviewStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Relay/curator/group-review.json"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Suggested Groups").font(.title2.bold())
                Spacer()
                Button("Done") {
                    if dirty { confirmDiscard = true } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
            }
            Text("Review local groups: select groups to merge, or photos to move into a new group. Save Groups keeps your choices across rescans. No Photos albums, dates or sync selections change.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("Visual distance limit").fixedSize()
                Slider(value: $cutoff, in: 0...25, step: 0.5).disabled(!ready || dirty)
                Text(String(format: "%.1f", cutoff)).monospacedDigit().frame(width: 40)
                Button("Reset") { cutoff = EvidenceGrouping.defaultCutoff }.disabled(!ready || dirty)
            }
            Text("Specific shared scene clues allow up to 2 extra distance units; conflicting indoor/outdoor evidence keeps photos separate. Neither labels nor OCR verify a venue.")
                .font(.caption).foregroundStyle(.secondary)
            Text(status).font(.caption)
            HStack {
                Button("Merge Selected Groups") {
                    guard var value = proposal else { return }
                    value.groups = GroupReviewEditing.merge(value.groups, selected: selectedGroups)
                    proposal = value; selectedGroups = []; dirty = true
                }.disabled(selectedGroups.count < 2)
                Button("Split Selected Photos") {
                    guard var value = proposal else { return }
                    value.groups = GroupReviewEditing.split(value.groups, selected: selectedPhotos)
                    proposal = value; selectedPhotos = []; selectedGroups = []; dirty = true
                }.disabled(selectedPhotos.isEmpty)
                Spacer()
                Button("Save Groups") {
                    guard let value = proposal else { return }
                    do {
                        archive = try reviewStore.save(value.groups, visible: Set(moment.photos.map(\.id)), expectedRevision: archive.revision)
                        proposal = archive.applying(to: value)
                        dirty = false; selectedGroups = []; selectedPhotos = []; editError = nil
                        status = "Groups saved on this Mac. Only visible memberships changed; saved group names apply to the whole group."
                    } catch {
                        editError = "Could not save groups. Another review may have saved changes, or storage is unavailable. Your draft is kept; reopen before retrying a conflicting save."
                    }
                }.disabled(!ready || proposal == nil)
            }
            if let editError { Text(editError).font(.caption).foregroundStyle(.red) }
            if dirty { Text("Unsaved group edits. Save or close and discard before changing the automatic threshold.").font(.caption) }
            if let proposal {
                Text("\(proposal.groups.count) proposed groups · \(proposal.groups.filter { $0.photos.count == 1 }.count) single photos")
                    .font(.headline)
            }
            if cutoff > EvidenceGrouping.defaultCutoff {
                Text("Looser values can mix different landmarks. Location inference still uses the stricter default limit.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if proposal?.suspiciousTimes == true {
                Label("Unusually compressed timestamps: this could be a burst or imported dates. Capture chronology needs review; location inference is disabled for this set.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let proposal {
                        ForEach(Array(proposal.groups.enumerated()), id: \.element.id) { index, group in
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("Group \(index + 1) · \(group.photos.count) photos", isOn: Binding(
                                    get: { selectedGroups.contains(group.id) },
                                    set: { if $0 { selectedGroups.insert(group.id) } else { selectedGroups.remove(group.id) } }))
                                    .font(.headline)
                                if let saved = archive.groups.first(where: { $0.id == group.id }), saved.members.count > group.photos.count {
                                    Text("\(saved.members.count - group.photos.count) other members outside this review are preserved.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                TextField("Group name (optional)", text: Binding(
                                    get: { self.proposal?.groups.first(where: { $0.id == group.id })?.title ?? "" },
                                    set: { text in
                                        guard let position = self.proposal?.groups.firstIndex(where: { $0.id == group.id }) else { return }
                                        self.proposal?.groups[position].title = String(text.prefix(200)); dirty = true
                                    })).textFieldStyle(.roundedBorder)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240))], alignment: .leading) {
                                    ForEach(group.photos) { photo in
                                        VStack(alignment: .leading, spacing: 6) {
                                            Button { enlarged = photo } label: {
                                                SimilarityThumbnail(photo: photo, height: 130, squareCrop: false)
                                            }.buttonStyle(.plain).help("Inspect photo")
                                            Text(photo.created?.formatted() ?? "No date").font(.caption)
                                            Toggle("Select for split", isOn: Binding(
                                                get: { selectedPhotos.contains(photo.id) },
                                                set: { if $0 { selectedPhotos.insert(photo.id) } else { selectedPhotos.remove(photo.id) } }))
                                                .font(.caption)
                                            Text(group.explanations[photo.id] ?? "").font(.caption).foregroundStyle(.secondary)
                                            if EvidenceGrouping.validGPS(photo) {
                                                Text("Recorded GPS available; accuracy not indexed.").font(.caption)
                                            } else if let source = group.inferredLocationSources[photo.id],
                                                      let anchor = group.photos.first(where: { $0.id == source }) {
                                                Button("Possible shared location · inspect GPS source") { enlarged = anchor }
                                                    .font(.caption)
                                            } else {
                                                Text("Location unknown; no inference.").font(.caption)
                                            }
                                        }.padding(8)
                                    }
                                }
                            }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            Text("Groups can still be wrong: similar scenery is not proof of the same event. GPS inference uses direct source photos only, never inferred-to-inferred links.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20)
            .frame(minWidth: 600, idealWidth: 960, maxWidth: .infinity,
                   minHeight: 520, idealHeight: 720, maxHeight: .infinity)
            .background(ResizableReviewSheet())
            .sheet(item: $enlarged) { ReviewPhotoZoom(photo: $0) }
            .interactiveDismissDisabled(dirty)
            .confirmationDialog("Discard unsaved group edits?", isPresented: $confirmDiscard) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .task {
                do { archive = try reviewStore.load() }
                catch { editError = "Saved groups could not be read. They have not been replaced. Close this review and check storage before continuing."; return }
                let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Photo Relay/curator")
                let store = MomentTextEvidenceStore(directory: root.appendingPathComponent("text-evidence"))
                let loader = CuratorThumbnailLoader(provider: PhotoKitThumbnailProvider())
                var failed = 0
                var textFailed = 0
                for (index, photo) in moment.photos.enumerated() {
                    do {
                        try Task.checkCancellation()
                        status = "Inspecting \(index + 1) of \(moment.photos.count) local photos..."
                        var lines = await store.cached(photo)?.lines
                        if lines == nil {
                            do {
                                let image = try await loader.load(assetID: photo.id, timeout: 5, edge: 2048)
                                let recognized = try await store.recognize(image)
                                lines = try await store.save(recognized, for: photo).lines
                            } catch is CancellationError { throw CancellationError() }
                            catch { try Task.checkCancellation(); textFailed += 1 }
                        }
                        let image = try await loader.load(assetID: photo.id, timeout: 5)
                        if !(await session.cachedVisual(photo, root: root, lines: lines ?? [])) {
                            try await session.inspect(photo, image: image, lines: lines ?? [])
                        } else {
                            try await session.classify(photo, image: image)
                        }
                    } catch is CancellationError { return }
                    catch {
                        if Task.isCancelled { return }
                        failed += 1
                    }
                }
                status = "\(moment.photos.count) photos considered; \(failed) visual reads and \(textFailed) text reads unavailable or failed. Missing visual evidence stays separate."
                ready = true
            }
            .task(id: "\(ready)-\(cutoff)") {
                guard ready else { return }
                do {
                    let value = try await session.proposal(moment.photos, cutoff: cutoff)
                    try Task.checkCancellation()
                    guard !dirty else { return }
                    proposal = archive.applying(to: value)
                    selectedGroups = []; selectedPhotos = []
                }
                catch is CancellationError { return }
                catch { status = "Could not prepare groups. Close and try again." }
            }
    }
}
