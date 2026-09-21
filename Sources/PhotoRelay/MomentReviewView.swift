import SwiftUI

enum ReviewDecision: String, Codable { case include, exclude }

@MainActor
final class MomentReviewDecisions: ObservableObject {
    @Published private(set) var values: [String: ReviewDecision]
    @Published private(set) var titles: [String: String]
    @Published private(set) var descriptions: [String: String]
    private let defaults: UserDefaults
    private let key = "curator.manualReview.v1"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        titles = defaults.dictionary(forKey: "curator.momentTitles.v1") as? [String: String] ?? [:]
        descriptions = defaults.dictionary(forKey: "curator.momentDescriptions.v1") as? [String: String] ?? [:]
        values = (defaults.dictionary(forKey: key) as? [String: String] ?? [:]).compactMapValues(ReviewDecision.init(rawValue:))
    }
    func set(_ decision: ReviewDecision?, for id: String) {
        values[id] = decision
        defaults.set(values.mapValues(\.rawValue), forKey: key)
    }
    func setTitle(_ title: String, for id: String, moment: PhotoMoment? = nil) {
        if let moment { MomentGroupingProtection.remember(moment, defaults: defaults) }
        titles = defaults.dictionary(forKey: "curator.momentTitles.v1") as? [String: String] ?? [:]
        let bounded = String(title.prefix(200))
        titles[id] = bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bounded
        defaults.set(titles, forKey: "curator.momentTitles.v1")
        releaseUnusedMembership(id)
    }
    func setDescription(_ text: String, for id: String, moment: PhotoMoment? = nil) {
        if let moment { MomentGroupingProtection.remember(moment, defaults: defaults) }
        descriptions = defaults.dictionary(forKey: "curator.momentDescriptions.v1") as? [String: String] ?? [:]
        let bounded = String(text.prefix(2000))
        descriptions[id] = bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bounded
        defaults.set(descriptions, forKey: "curator.momentDescriptions.v1")
        releaseUnusedMembership(id)
    }

    private func releaseUnusedMembership(_ id: String) {
        guard !MomentGroupingProtection.load(defaults).ids.contains(id) else { return }
        var saved = defaults.dictionary(forKey: MomentGroupingProtection.membershipKey) as? [String: [String]] ?? [:]
        saved.removeValue(forKey: id)
        defaults.set(saved, forKey: MomentGroupingProtection.membershipKey)
    }

    static func apply(_ decisions: [String: ReviewDecision], to selection: MomentSelection, photos: [IndexedPhoto]) -> MomentSelection {
        let included = photos.filter { decisions[$0.id] == .include }.map(\.id)
        return MomentSelection(selected: Array(Set(selection.selected.filter { decisions[$0] == nil } + included)).sorted(),
                               pending: selection.pending.filter { decisions[$0] == nil },
                               similar: selection.similar.filter { decisions[$0] == nil },
                               explanations: selection.explanations,
                               alternatives: selection.alternatives.filter { decisions[$0] == nil },
                               contextOnly: selection.contextOnly?.filter { decisions[$0] == nil })
    }
}

struct MomentReviewView: View {
    let moment: PhotoMoment
    @ObservedObject var decisions: MomentReviewDecisions
    var curator: CuratorController? = nil
    var advancedTools = false
    var window: NSWindow? = nil
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @AppStorage("curator.fontSizeScale") private var fontSizeScale: Double = 1.0
    @State private var thumbnailSize: Double = 220
    @State private var squareCrop = false
    @State private var category = "all"
    @State private var favoritesOnly = false
    @State private var enlarged: IndexedPhoto?
    @State private var narrative = false
    @State private var grouping = false
    @State private var showHelp = false
    @State private var activeExplanation: (id: String, text: String)? = nil
    @State private var place: ResolvedPlace? = nil
    @State private var isPinned: Bool = true
    @State private var publishing = false
    @State private var publishReceipt: CuratedAlbumReceipt? = nil
    @State private var publishError: String? = nil
    @State private var deletedPhotoIDs: Set<String> = []
    @State private var favoriteOverrides: [String: Bool] = [:]
    @State private var libraryEditError: String? = nil
    @State private var initialTitle: String?
    @State private var initialDescription: String?
    @State private var initialDecisions: [String: ReviewDecision] = [:]
    @State private var capturedInitialState = false
    @FocusState private var titleFieldFocused: Bool

    private var filtered: [IndexedPhoto] {
        moment.photos.filter {
            !deletedPhotoIDs.contains($0.id) &&
            (!favoritesOnly || favoriteOverrides[$0.id] ?? $0.favorite) &&
            (category == "all" || $0.similarityCategory?.rawValue == category)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review Moment").font(.system(size: 22 * fontSizeScale, weight: .bold))
                    Text(MomentPresentation.title(moment, custom: decisions.titles[moment.id], place: place))
                        .font(.system(size: 15 * fontSizeScale, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()

                if let win = window {
                    Button {
                        isPinned.toggle()
                        win.level = isPinned ? .floating : .normal
                    } label: {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .font(.title3)
                            .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isPinned ? "Window stays on top (click to unpin)" : "Pin window on top")
                }

                Button {
                    showHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("About curation and library safety")
                .popover(isPresented: $showHelp) {
                    ReviewSafetyHelpView()
                }

                Button("Done") {
                    closeReview()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                Button("Cancel Changes") {
                    restoreInitialState()
                    closeReview()
                }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                TextField("Moment title (optional)", text: Binding(
                    get: { decisions.titles[moment.id] ?? moment.reviewedGroupTitle ?? "" },
                    set: { decisions.setTitle($0, for: moment.id, moment: moment) }))
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFieldFocused)

                HStack(spacing: 6) {
                    Button {
                        narrative = true
                    } label: {
                        Label("Suggest Title & Story…", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .help("Suggest titles and stories using on-device intelligence")

                    if decisions.titles[moment.id] != nil {
                        Button("Reset") { decisions.setTitle("", for: moment.id) }
                            .buttonStyle(.bordered)
                            .help("Reset to original moment title")
                    }

                    if let curator {
                        let isPublished = moment.publishedAlbumID != nil || publishReceipt != nil
                        Button {
                            Task {
                                publishing = true
                                publishError = nil
                                do {
                                    let receipt = try await curator.publishToPhotos(moment: moment, decisions: decisions)
                                    publishReceipt = receipt
                                } catch {
                                    publishError = error.localizedDescription
                                }
                                publishing = false
                            }
                        } label: {
                            if publishing {
                                HStack(spacing: 4) {
                                    ProgressView().scaleEffect(0.6)
                                    Text("Saving…")
                                }
                            } else if isPublished {
                                Label("In Photos", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Label("Save Album in Photos", systemImage: "rectangle.stack.badge.plus")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(publishing)
                        .help(isPublished ? "Saved under Photo Curator folder in Apple Photos. Click to update." : "Create album in Apple Photos and assign curated originals without duplication")
                    }
                }
            }
            if let description = decisions.descriptions[moment.id] {
                Text(description).font(.system(size: 18 * fontSizeScale)).foregroundStyle(.secondary).lineLimit(3)
            } else {
                let pWord = moment.photos.count == 1 ? "photo" : "photos"
                let countText = "\(moment.photos.count) \(pWord)" + (moment.favorites > 0 ? " · \(moment.favorites) favorite" + (moment.favorites > 1 ? "s" : "") : "")
                HStack(spacing: 8) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 20 * fontSizeScale))
                        .foregroundStyle(.secondary)
                    Text(countText)
                        .font(.system(size: 22 * fontSizeScale, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.vertical, 3)
            }
            DisclosureGroup {
                Text(MomentGroupingInterpretation.describe(moment: moment, place: place))
                    .font(.system(size: 18 * fontSizeScale, weight: .regular))
                    .lineSpacing(6)
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } label: {
                Text("About this grouping")
                    .font(.system(size: 18 * fontSizeScale, weight: .bold))
            }
            HStack {
                Picker("Type", selection: $category) {
                    Text("All Images").tag("all")
                    ForEach(SimilarityCategory.allCases) { Text($0.title).tag($0.rawValue) }
                }.frame(width: 200).fixedSize(horizontal: true, vertical: false)
                Toggle("Favorites", isOn: $favoritesOnly).fixedSize()
                Spacer()
                if advancedTools { Button("Suggest Groups...") { grouping = true } }
            }
            HStack {
                Picker("Display", selection: $squareCrop) {
                    Text("Fit").tag(false)
                    Text("Square").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                    .help("Fit shows the entire photo. Square crops only the preview.")
                Spacer()
                Button { thumbnailSize = max(160, thumbnailSize - 40) } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Smaller thumbnails").disabled(thumbnailSize <= 160)
                Slider(value: $thumbnailSize, in: 160...360).frame(width: 160).accessibilityLabel("Thumbnail size")
                Button { thumbnailSize = min(360, thumbnailSize + 40) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Larger thumbnails").disabled(thumbnailSize >= 360)
            }
            let photoCountWord = moment.photos.count == 1 ? "photo" : "photos"
            Text("\(filtered.count) of \(moment.photos.count) \(photoCountWord)")
                .font(.system(size: 15 * fontSizeScale, weight: .medium))
                .foregroundStyle(.secondary)
            ScrollView {
                if filtered.isEmpty { Text("No images match these filters.").padding(30) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize))], spacing: 18) {
                    ForEach(filtered) { photo in
                        ReviewPhotoCard(
                            photo: photo,
                            thumbnailSize: thumbnailSize,
                            squareCrop: squareCrop,
                            statusText: status(photo.id),
                            explanation: moment.selection?.explanations[photo.id],
                            userChoice: decisions.values[photo.id],
                            isFavorite: favoriteOverrides[photo.id] ?? photo.favorite,
                            onEnlarge: { enlarged = photo },
                            onSelectDecision: { decisions.set($0, for: photo.id) },
                            onSetFavorite: { favorite in
                                guard let curator else { return }
                                try await curator.setFavorite(favorite, photoID: photo.id)
                                favoriteOverrides[photo.id] = favorite
                            },
                            onDelete: {
                                guard let curator else { return }
                                Task {
                                    do {
                                        try await curator.moveToRecentlyDeleted(photoID: photo.id)
                                        deletedPhotoIDs.insert(photo.id)
                                    } catch { libraryEditError = error.localizedDescription }
                                }
                            }
                        )
                    }
                }.padding(4)
            }
        }.padding(20)
            .frame(minWidth: 680, minHeight: 500)
            .task {
                captureInitialState()
                titleFieldFocused = true
                place = await CuratorGeocodingService.shared.place(for: moment)
            }
        .sheet(item: $enlarged) { photo in ReviewPhotoZoom(photo: photo) }
        .sheet(isPresented: $narrative) { MomentNarrativeSheet(moment: moment, decisions: decisions) }
        .sheet(isPresented: $grouping) { GroupingSuggestionsView(moment: moment) }
        .alert("Photos Album", isPresented: Binding(get: { publishError != nil }, set: { if !$0 { publishError = nil } })) {
            Button("OK") { publishError = nil }
        } message: { Text(publishError ?? "") }
        .alert("Could Not Change Photos", isPresented: Binding(
            get: { libraryEditError != nil }, set: { if !$0 { libraryEditError = nil } })) {
            Button("OK") { libraryEditError = nil }
        } message: { Text(libraryEditError ?? "") }
    }

    private func captureInitialState() {
        guard !capturedInitialState else { return }
        initialTitle = decisions.titles[moment.id]
        initialDescription = decisions.descriptions[moment.id]
        initialDecisions = Dictionary(uniqueKeysWithValues: moment.photos.compactMap { photo in
            decisions.values[photo.id].map { (photo.id, $0) }
        })
        capturedInitialState = true
    }

    private func restoreInitialState() {
        guard capturedInitialState else { return }
        decisions.setTitle(initialTitle ?? "", for: moment.id, moment: moment)
        decisions.setDescription(initialDescription ?? "", for: moment.id, moment: moment)
        for photo in moment.photos { decisions.set(initialDecisions[photo.id], for: photo.id) }
    }

    private func closeReview() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func status(_ id: String) -> String {
        if decisions.values[id] == .include { return "Included by you" }
        if decisions.values[id] == .exclude { return "Hidden from moment" }
        if moment.selection?.contextOnly?.contains(id) == true { return "Kept for story" }
        if moment.selection?.similar.contains(id) == true { return "Set aside (similar)" }
        if moment.selection?.alternatives.contains(id) == true { return "Alternative shot" }
        if moment.selection?.pending.contains(id) == true { return "Analyzing…" }
        return "Curator's Pick"
    }
}

struct ReviewPhotoCard: View {
    let photo: IndexedPhoto
    let thumbnailSize: Double
    let squareCrop: Bool
    let statusText: String
    let explanation: String?
    let userChoice: ReviewDecision?
    let isFavorite: Bool
    let onEnlarge: () -> Void
    let onSelectDecision: (ReviewDecision?) -> Void
    let onSetFavorite: (Bool) async throws -> Void
    let onDelete: () -> Void

    @State private var showingExplanation = false
    @State private var favoriteChanging = false
    @State private var favoriteError: String? = nil
    @AppStorage("curator.fontSizeScale") private var fontSizeScale: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onEnlarge) {
                SimilarityThumbnail(photo: photo, height: thumbnailSize - 20, squareCrop: squareCrop,
                                    allowsNetworkAccess: true)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .help("Open larger photo")
            .accessibilityLabel("Enlarge photo")

            HStack(spacing: 4) {
                Text(statusText)
                    .font(.system(size: 13 * fontSizeScale, weight: .medium))
                    .foregroundStyle(.secondary)
                if let explanation {
                    Button {
                        showingExplanation.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13 * fontSizeScale))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Curator's selection details")
                    .popover(isPresented: $showingExplanation) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Curator's Note")
                                .font(.system(size: 16 * fontSizeScale, weight: .bold))
                            Text(explanation)
                                .font(.system(size: 14 * fontSizeScale))
                                .lineSpacing(3)
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                            if userChoice != nil {
                                Divider()
                                Text("Your manual choice overrides this recommendation.")
                                    .font(.system(size: 13 * fontSizeScale))
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(14)
                        .frame(width: 300)
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    Task {
                        favoriteChanging = true
                        defer { favoriteChanging = false }
                        do {
                            try await onSetFavorite(!isFavorite)
                        } catch {
                            favoriteError = error.localizedDescription
                        }
                    }
                } label: {
                    Label(isFavorite ? "Favorite" : "Add Favorite",
                          systemImage: isFavorite ? "heart.fill" : "heart")
                }
                .buttonStyle(.bordered)
                .disabled(favoriteChanging)
                .help(isFavorite ? "Remove the Favorite flag in Apple Photos" : "Mark as Favorite in Apple Photos")

                Spacer()

                Button(role: .destructive, action: onDelete) {
                    Label("Delete…", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .help("Move the original to Recently Deleted in Apple Photos")
            }

            Picker("In Moment:", selection: Binding<String>(
                get: { userChoice?.rawValue ?? "automatic" },
                set: { onSelectDecision(ReviewDecision(rawValue: $0)) })) {
                    Text("Curator's Pick").tag("automatic")
                    Text("Always Include").tag("include")
                    Text("Hide from Moment").tag("exclude")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .alert("Could Not Change Favorite", isPresented: Binding(
            get: { favoriteError != nil }, set: { if !$0 { favoriteError = nil } })) {
            Button("OK") { favoriteError = nil }
        } message: { Text(favoriteError ?? "") }
    }
}

struct ReviewSafetyHelpView: View {
    @AppStorage("curator.fontSizeScale") private var fontSizeScale: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
                Text("Safe & Private Curation")
                    .font(.system(size: 17 * fontSizeScale, weight: .bold))
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.shield").font(.title3).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Explicit Changes Stay Under Your Control")
                            .font(.system(size: 14 * fontSizeScale, weight: .semibold))
                        Text("Moment choices stay in Photo Curator. Favorite updates Apple Photos immediately; Delete always asks first and moves the original to Recently Deleted, where Apple handles iCloud synchronization.")
                            .font(.system(size: 13 * fontSizeScale))
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "laptopcomputer").font(.title3).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved Automatically on This Mac")
                            .font(.system(size: 14 * fontSizeScale, weight: .semibold))
                        Text("Your titles and photo choices save instantly and stay on your computer.")
                            .font(.system(size: 13 * fontSizeScale))
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "slider.horizontal.3").font(.title3).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Choice Meanings")
                            .font(.system(size: 14 * fontSizeScale, weight: .semibold))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("• Curator's Pick: Balances variety, quality, and faces.")
                            Text("• Always Include: Guarantees this photo is in the moment.")
                            Text("• Hide from Moment: Removes it from this highlight without deleting your photo.")
                        }
                        .font(.system(size: 13 * fontSizeScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

struct ReviewPhotoZoom: View {
    let photo: IndexedPhoto
    @Environment(\.dismiss) private var dismiss
    @State private var zoom = 1.0
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Photo Preview").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Button("Fit") { zoom = 1 }
                Slider(value: $zoom, in: 1...4).accessibilityLabel("Photo zoom")
                Text("\(Int(zoom * 100))%").monospacedDigit()
            }
            ScrollView([.horizontal, .vertical]) {
                SimilarityThumbnail(photo: photo, height: 480 * zoom, requestedEdge: 4096,
                                    allowsNetworkAccess: true)
                    .frame(width: 780 * zoom)
            }.frame(height: 510)
            Text("Requests Photos' edited rendition up to 4096 pixels, then uses the original if the edit is unavailable. Photos may retrieve it from iCloud when needed.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 820)
    }
}

struct ResizableReviewSheet: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SheetView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class SheetView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.resizable)
            window.contentMinSize = NSSize(width: 640, height: 520)
            window.showsResizeIndicator = true
        }
    }
}
