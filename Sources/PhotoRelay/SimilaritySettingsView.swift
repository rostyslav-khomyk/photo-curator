import SwiftUI
import Photos

struct SimilarityPair: Identifiable {
    let first: IndexedPhoto
    let second: IndexedPhoto
    let distance: Float
    var id: String { first.id + "|" + second.id }

    static func boundary(_ pairs: [Self], threshold: Float, similar: Bool) -> Self? {
        let eligible = pairs.filter { $0.distance.isFinite && $0.distance >= 0 && ($0.distance <= threshold) == similar }
        return similar ? eligible.max(by: { $0.distance < $1.distance }) : eligible.min(by: { $0.distance < $1.distance })
    }
}

struct SimilaritySettingsView: View {
    @ObservedObject var curator: CuratorController
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [SimilarityCategory: Float]
    @State private var category: SimilarityCategory = .photos
    @State private var similarIndex = 0
    @State private var differentIndex = 0
    @State private var enlarged: SimilarityPair?
    @State private var pairs: [SimilarityPair] = []
    @State private var loading = true
    @State private var failure: String?

    init(curator: CuratorController) {
        self.curator = curator
        _drafts = State(initialValue: curator.similarityThresholds)
    }

    private var threshold: Double { Double(drafts[category] ?? 0.01) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Similar Photos").font(.title2.bold())
            Picker("Photo type", selection: $category) {
                ForEach(SimilarityCategory.allCases) { Text($0.title).tag($0) }
            }
            Text("Screenshots have their own category. Documents, Receipts and Handwriting are not exposed by this PhotoKit SDK; they cannot yet be separated reliably.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Compare examples from the selected period. Move right to treat more photos as similar.")
            Slider(value: Binding(get: { threshold }, set: { drafts[category] = Float($0); similarIndex = 0; differentIndex = 0 }), in: 0...max(1, Double(pairs.map(\.distance).max() ?? 0), threshold)) {
                Text("Similarity distance cutoff")
            }
            HStack {
                Text("Stricter"); Spacer()
                Text("Distance cutoff: \(threshold, specifier: "%.3f")").monospacedDigit()
                Spacer(); Text("More inclusive")
            }.font(.caption)
            Text("Smaller distance means closer visual resemblance, not a similarity percentage. Only shots within 60 seconds are eligible. Favorites are always kept.")
                .font(.callout).foregroundStyle(.secondary)
            if loading {
                ProgressView("Comparing cached analysis locally...").frame(height: 250)
            } else if let failure {
                Text(failure).foregroundStyle(.red).frame(height: 250)
            } else if pairs.isEmpty {
                Text("No comparable pairs yet. Process a period with photos taken within a minute of each other, then reopen this dialog.")
                    .frame(height: 250)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    example(similar: true)
                    example(similar: false)
                }
                Text("\(pairs.count) sampled adjacent pairs. Examples nearest the cutoff change as you move it. This previews the pair rule, not the final keep/skip decision, which also considers ranking and other photos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Reset This Type") { drafts[category] = 0.01; similarIndex = 0; differentIndex = 0 }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    curator.applySimilarityThresholds(drafts); dismiss()
                }.keyboardShortcut(.defaultAction).disabled(loading || failure != nil || pairs.isEmpty)
            }
            Text("Applies to curator suggestions across your library. No deletions, album changes, downloads, or uploads.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 760)
        .sheet(item: $enlarged) { pair in
            SimilarityZoomView(pair: pair)
        }
        .task(id: category) {
            loading = true; failure = nil; pairs = []; similarIndex = 0; differentIndex = 0
            do {
                let result = try await curator.similarityPairs(category: category)
                try Task.checkCancellation()
                pairs = result
            }
            catch is CancellationError { return }
            catch { failure = error.localizedDescription }
            loading = false
        }
    }

    private func example(similar: Bool) -> some View {
        let eligible = pairs.filter { ($0.distance <= Float(threshold)) == similar }.sorted {
            similar ? $0.distance > $1.distance : $0.distance < $1.distance
        }
        let index = similar ? similarIndex : differentIndex
        return VStack(alignment: .leading, spacing: 8) {
            Label(similar ? "Treated as similar" : "Treated as different", systemImage: similar ? "square.stack" : "rectangle.on.rectangle.slash")
                .font(.headline)
            if !eligible.isEmpty {
                let pair = eligible[min(index, eligible.count - 1)]
                HStack(spacing: 6) {
                    SimilarityThumbnail(photo: pair.first).id(pair.first.id)
                    SimilarityThumbnail(photo: pair.second).id(pair.second.id)
                }
                Text("Distance: \(pair.distance, specifier: "%.3f")").font(.caption).monospacedDigit()
                HStack {
                    Button("Previous") { if similar { similarIndex -= 1 } else { differentIndex -= 1 } }.disabled(index == 0)
                    Text("\(index + 1)/\(eligible.count)").font(.caption)
                    Button("Next") { if similar { similarIndex += 1 } else { differentIndex += 1 } }.disabled(index + 1 >= eligible.count)
                    Button { enlarged = pair } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .help("Enlarge and zoom this pair").accessibilityLabel("Enlarge pair")
                }
                if pair.first.favorite || pair.second.favorite {
                    Label("Favorite protection still applies", systemImage: "heart.fill").font(.caption)
                }
            } else {
                Text(similar ? "No sampled pair is below this cutoff." : "No sampled pair is above this cutoff.")
                    .foregroundStyle(.secondary).frame(height: 180)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SimilarityThumbnail: View {
    let photo: IndexedPhoto
    var height: CGFloat = 170
    var squareCrop = false
    var requestedEdge = 1024
    var showsTimestamp = true
    var allowsNetworkAccess = false
    @State private var image: CGImage?
    @State private var failure: ThumbnailFailure?
    @State private var refreshCount = 0

    var body: some View {
        VStack(spacing: 5) {
            Rectangle().fill(.quaternary)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .overlay {
                if let image {
                    PhotoPreviewCanvas(image: image, crop: squareCrop)
                } else if let failure {
                    VStack(spacing: 6) {
                        Image(systemName: failure == .cloudOnly ? "icloud" : "photo.badge.exclamationmark")
                        Text(failureMessage(failure)).font(.caption).multilineTextAlignment(.center)
                    }.foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ProgressView()
                        if allowsNetworkAccess {
                            Text("Loading from Photos…").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                }.clipped()
            if showsTimestamp {
                Text(photo.created?.formatted(date: .omitted, time: .standard) ?? "Unknown time")
                    .font(.caption2)
            }
        }
        .task(id: "\(photo.id)-\(photo.analysisRevision)-\(requestedEdge)-\(refreshCount)") {
            image = nil
            failure = nil
            for attempt in 0..<2 {
                let loader = CuratorThumbnailLoader(provider: PhotoKitThumbnailProvider(
                    allowsNetworkAccess: allowsNetworkAccess))
                do {
                    image = try await loader.load(
                        assetID: photo.id,
                        timeout: allowsNetworkAccess ? 120 : 20,
                        edge: requestedEdge
                    )
                    break
                } catch {
                    guard !Task.isCancelled else { return }
                    let current = error as? ThumbnailFailure ?? .unavailable
                    if attempt == 0 && (current == .unavailable || current == .busy) {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        continue
                    }
                    failure = current
                    if current == .missing {
                        NotificationCenter.default.post(name: .photoRelayPhotosAccessChanged, object: nil)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .photoRelayPhotosAccessChanged)) { _ in
            if image == nil {
                refreshCount += 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if image == nil && failure != nil && PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized {
                refreshCount += 1
            }
        }
        .onDisappear {
            image = nil
            failure = nil
        }
    }

    private func failureMessage(_ failure: ThumbnailFailure) -> String {
        switch failure {
        case .cloudOnly: "Stored in iCloud"
        case .timedOut: "Preview timed out"
        case .missing: "No longer in Photos"
        case .permissionDenied: "Photos access required"
        case .busy: "Preview is busy"
        case .cancelled, .unavailable: "Preview unavailable"
        }
    }
}

struct PhotoPreviewCanvas: View {
    let image: CGImage
    let crop: Bool
    var body: some View {
        GeometryReader { geometry in
            Image(decorative: image, scale: 1).resizable()
                .aspectRatio(contentMode: crop ? .fill : .fit)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
    }
}

private struct SimilarityZoomView: View {
    let pair: SimilarityPair
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: Double = 1
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Compare Photos").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Text("Zoom")
                Slider(value: $zoom, in: 1...3).accessibilityLabel("Comparison zoom")
                Text("\(Int(zoom * 100))%").monospacedDigit()
                Button("Fit") { zoom = 1 }
            }
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 16) {
                    SimilarityThumbnail(photo: pair.first, height: 420 * zoom).frame(width: 400 * zoom)
                    SimilarityThumbnail(photo: pair.second, height: 420 * zoom).frame(width: 400 * zoom)
                }
            }.frame(height: 460)
            Text("Distance: \(pair.distance, specifier: "%.3f"). Local previews up to 1024 pixels; zoom does not download originals.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 860)
    }
}
