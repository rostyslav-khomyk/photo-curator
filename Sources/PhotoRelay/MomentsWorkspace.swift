import SwiftUI
import AppKit
import Photos

struct CuratorView: View {
    @ObservedObject var curator: CuratorController
    @ObservedObject var model: PhotoRelayViewModel
    @StateObject private var decisions = MomentReviewDecisions()
    @State private var reviewing: PhotoMoment?
    @State private var prioritizing = false
    @State private var selecting = false
    @State private var selection = MomentMultiSelection()
    @State private var mergeDraft: MomentMergeDraft?
    @State private var showWorkspaceHelp = false
    @State private var googleExportMoments: [PhotoMoment] = []
    @State private var showingGoogleExport = false
    @State private var places: [String: ResolvedPlace] = [:]
    @State private var placeResolutionTask: Task<Void, Never>?
    @State private var activeMomentID: String?
    @AppStorage("curator.hidePublishedMoments.v1") private var hidePublishedMoments = false
    @AppStorage("curator.hideGoogleUploadedMoments.v1") private var hideGoogleUploadedMoments = false
    @AppStorage("curator.lastActiveMomentID.v1") private var savedActiveMomentID = ""
    @AppStorage("curator.scrollAnchorMomentID.v1") private var savedScrollAnchorMomentID = ""
    @State private var restoredScrollPosition = false
    @State private var scrollRestoreID: String?
    @ObservedObject private var meaningfulPlaces = MeaningfulPlacesStore.shared

    private var visibleMoments: [PhotoMoment] {
        curator.moments.filter { moment in
            (!hidePublishedMoments || moment.publishedAlbumID == nil)
                && (!hideGoogleUploadedMoments || !momentWasUploaded(moment))
        }
    }

    private var displayedIDs: [String] {
        visibleMoments.map(\.id)
    }

    private func contextOnly(_ moment: PhotoMoment) -> Bool {
        MomentDisplayEligibility.isSupportingCollection(moment, decisions: decisions.values,
            userAuthored: decisions.titles[moment.id] != nil || decisions.descriptions[moment.id] != nil)
    }

    private func cards(_ moments: [PhotoMoment]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 380), spacing: 20)], spacing: 24) {
            ForEach(moments) { moment in
                Button {
                    if selecting {
                        selection.click(moment.id, ordered: displayedIDs, range: NSEvent.modifierFlags.contains(.shift))
                    } else {
                        activeMomentID = moment.id
                        MomentReviewWindowManager.shared.open(moment: moment, decisions: decisions, curator: curator) {
                            Task {
                                await curator.refreshOverview()
                                schedulePlaceResolution()
                            }
                        }
                    }
                } label: {
                    MomentCoverCard(moment: moment, decisions: decisions, place: places[moment.id],
                                    uploadedToGoogle: momentWasUploaded(moment),
                                    loadPreview: restoredScrollPosition)
                        .overlay(alignment: .topTrailing) {
                            if selecting {
                                Image(systemName: selection.ids.contains(moment.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title2).foregroundStyle(selection.ids.contains(moment.id) ? Color.accentColor : .secondary)
                                    .padding(8).background(.regularMaterial, in: Circle()).padding(8)
                            }
                        }
                        .overlay {
                            if activeMomentID == moment.id {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.accentColor, lineWidth: 2)
                            }
                        }
                }.buttonStyle(.plain)
                    .id(moment.id)
                    .task(id: moment.id) {
                        let applied = moment.selection.map {
                            MomentReviewDecisions.apply(decisions.values, to: $0, photos: moment.photos)
                        }
                        let priority = MomentDisplayEligibility.viewportPriorityPhotos(
                            moment, decisions: decisions.values, selected: applied?.selected ?? [])
                        await curator.prioritizeVisibleMoment(moment, photos: priority)
                    }
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: MomentViewportPreferenceKey.self,
                                               value: [moment.id: geometry.frame(in: .named("moments-scroll")).minY])
                    })
                    .accessibilityValue(selecting ? (selection.ids.contains(moment.id) ? "Selected" : "Not selected") : "")
                    .accessibilityLabel("Open Moment, \(MomentPresentation.title(moment, custom: decisions.titles[moment.id], place: places[moment.id]))")
            }
        }.padding(.horizontal, 24).padding(.bottom, 24)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Moments").font(.largeTitle.bold())
                    Text("Your library, rediscovered. Curated privately on your Mac.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if let pilot = CuratorPilot.range() {
                            Text("Curating \(pilot.start.formatted(.dateTime.month().year()))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button {
                            showWorkspaceHelp = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("About Moments and privacy")
                        .popover(isPresented: $showWorkspaceHelp) {
                            MomentsWorkspaceHelpView()
                        }
                    }
                }
                Spacer()
            }.padding(24)
            if selecting {
                Text("\(selection.ids.count) selected. Click to toggle; Shift-click selects a range.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }
            if meaningfulPlaces.places.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse").foregroundStyle(.tint)
                    Text("Give your library a stronger sense of place. Add Home, Work, or another familiar location so local shoots receive more personal captions.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Places…") {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 12)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    if visibleMoments.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: hidePublishedMoments ? "line.3.horizontal.decrease.circle" : "photo.stack")
                                .font(.system(size: 42)).foregroundStyle(.secondary)
                            Text(curator.overviewLoading ? "Loading your collections…" : (hidePublishedMoments ? "All loaded Moments are already in Photos" : "Your Moments are taking shape"))
                                .font(.title2)
                            Text((hidePublishedMoments || hideGoogleUploadedMoments) ? "Adjust the Moment filters to see hidden collections." : "Photo Curator prepares collections in the background. Moments remain available while their titles are still being refined.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                                .frame(maxWidth: 480)
                            if curator.overviewLoading { ProgressView().controlSize(.small) }
                        }.frame(maxWidth: .infinity).padding(60)
                    } else {
                        cards(visibleMoments)
                        if curator.availableMoments > curator.moments.count {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Loading more Moments…").foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 24)
                            .task(id: curator.moments.count) { await curator.loadMoreMoments() }
                        }
                    }
                }
                .coordinateSpace(name: "moments-scroll")
                .onPreferenceChange(MomentViewportPreferenceKey.self) { positions in
                    guard restoredScrollPosition,
                          let nearest = positions.filter({ $0.value >= 0 }).min(by: { $0.value < $1.value }) else { return }
                    savedScrollAnchorMomentID = nearest.key
                }
                .onChange(of: activeMomentID) { id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: scrollRestoreID) { id in
                    guard let id else { return }
                    proxy.scrollTo(id, anchor: .top)
                    restoredScrollPosition = true
                    scrollRestoreID = nil
                }
            }
            Divider()
            HStack {
                if curator.foregroundActive { ProgressView().controlSize(.small) }
                Text(curator.activity).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if curator.foregroundActive { Button("Stop Priority Work") { curator.stopForeground() } }
            }.padding(14).background(.bar)
        }
        .task {
            await curator.refreshOverview(reusingVisibleMoments: true)
            if activeMomentID == nil {
                activeMomentID = displayedIDs.contains(savedActiveMomentID) ? savedActiveMomentID : displayedIDs.first
            }
            if !savedScrollAnchorMomentID.isEmpty, displayedIDs.contains(savedScrollAnchorMomentID) {
                scrollRestoreID = savedScrollAnchorMomentID
            } else {
                restoredScrollPosition = true
            }
            schedulePlaceResolution()
        }
        .onChange(of: displayedIDs) { ids in
            if activeMomentID.flatMap({ ids.contains($0) }) != true { activeMomentID = ids.first }
            if !restoredScrollPosition, !savedScrollAnchorMomentID.isEmpty,
               ids.contains(savedScrollAnchorMomentID) {
                scrollRestoreID = savedScrollAnchorMomentID
            }
        }
        .onChange(of: activeMomentID) { id in
            if let id { savedActiveMomentID = id }
        }
        .background(MomentGridKeyHandler { event in handleGridKey(event) })
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Toggle("Hide Moments Already in Photos", isOn: $hidePublishedMoments)
                    Toggle("Hide Moments Uploaded to Google", isOn: $hideGoogleUploadedMoments)
                } label: {
                    Label("Filter Moments", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Filter the Moments workspace")

                Button {
                    selecting.toggle()
                    selection = MomentMultiSelection()
                } label: {
                    Label(selecting ? "Finish Selecting" : "Select Moments",
                          systemImage: selecting ? "checkmark.circle" : "checkmark.circle.badge.plus")
                }
                .help(selecting ? "Finish selecting Moments" : "Select Moments")

                Button {
                    googleExportMoments = curator.moments.filter { selection.ids.contains($0.id) }
                    showingGoogleExport = true
                } label: {
                    Label("Save to Google Photos", systemImage: "icloud.and.arrow.up")
                }
                .disabled(model.isWorking)
                .help(selection.ids.isEmpty
                      ? "Save Favorites from your Photos library to Google Photos"
                      : "Review selected Moment highlights or Favorites for Google Photos")

                Button {
                    let chosen = curator.moments.filter { selection.ids.contains($0.id) }
                    guard chosen.count == selection.ids.count else {
                        curator.errorMessage = "Collections changed. Please select them again."; return
                    }
                    do {
                        mergeDraft = MomentMergeDraft(moments: chosen, revision: try MomentMergeDraft.store.load().revision)
                    } catch { curator.errorMessage = "Could not open the saved grouping record. No changes were made." }
                } label: {
                    Label("Merge Moments", systemImage: "rectangle.stack.badge.plus")
                }
                .disabled(selection.ids.count < 2)
                .help("Merge the selected Moments")

                Button { prioritizing = true } label: {
                    Label("Prioritize a Time Range", systemImage: "calendar.badge.clock")
                }
                .help("Prepare a time range sooner")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("PhotoRelayGroupReviewChanged"))) { _ in
            Task {
                await curator.refreshOverview()
                schedulePlaceResolution()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .photoRelayPhotosAccessChanged)) { _ in
            Task {
                await curator.refreshOverview()
                schedulePlaceResolution()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .meaningfulPlacesChanged)) { _ in
            schedulePlaceResolution()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized {
                Task {
                    await curator.refreshOverview()
                    schedulePlaceResolution()
                }
            }
        }
        .sheet(item: $mergeDraft) { draft in
            MomentMergeView(draft: draft, decisions: decisions, curator: curator) {
                selection = MomentMultiSelection(); selecting = false
                Task {
                    await curator.refreshOverview()
                    schedulePlaceResolution()
                }
            }
        }
        .sheet(isPresented: $showingGoogleExport) {
            MomentGoogleExportView(moments: googleExportMoments, decisions: decisions, model: model) {
                showingGoogleExport = false
                googleExportMoments = []
            }
        }
        .sheet(isPresented: $prioritizing) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Prepare a period sooner").font(.title2.bold())
                Text("This changes processing priority, not the Moments shown in your library.")
                    .foregroundStyle(.secondary)
                Picker("Time range", selection: $curator.period) {
                    ForEach(CuratorPeriod.allCases) { Text($0.title).tag($0) }
                }
                if curator.period == .custom {
                    DatePicker("From", selection: $curator.customStart, displayedComponents: .date)
                    DatePicker("Through", selection: $curator.customEnd, displayedComponents: .date)
                }
                HStack {
                    Button("Cancel") { prioritizing = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Prioritize") { curator.processRangeNow(); prioritizing = false }
                        .buttonStyle(.borderedProminent)
                        .disabled(curator.selectedRange == nil || curator.foregroundActive || curator.syncBusy)
                }
            }.padding(24).frame(width: 430)
        }
        .alert("Moments", isPresented: Binding(get: { curator.errorMessage != nil }, set: { if !$0 { curator.errorMessage = nil } })) {
            Button("OK") { curator.errorMessage = nil }
        } message: { Text(curator.errorMessage ?? "") }
    }

    private func handleGridKey(_ event: NSEvent) -> Bool {
        guard mergeDraft == nil, !showingGoogleExport, googleExportMoments.isEmpty, !prioritizing,
              !displayedIDs.isEmpty else { return false }
        if event.window?.firstResponder is NSTextView { return false }

        let current = activeMomentID.flatMap { displayedIDs.firstIndex(of: $0) } ?? 0
        let columns = max(1, Int((event.window?.contentView?.bounds.width ?? 900) / 270))
        let next: Int?
        switch event.keyCode {
        case 123: next = max(0, current - 1)
        case 124: next = min(displayedIDs.count - 1, current + 1)
        case 125: next = min(displayedIDs.count - 1, current + columns)
        case 126: next = max(0, current - columns)
        case 53:
            guard selecting else { return false }
            selecting = false
            selection = MomentMultiSelection()
            return true
        case 49:
            let id = displayedIDs[current]
            if !selecting { selecting = true }
            selection.click(id, ordered: displayedIDs, range: false)
            activeMomentID = id
            return true
        case 36, 76:
            if selecting, selection.ids.count >= 2 { openMergeDraft(); return true }
            guard let moment = curator.moments.first(where: { $0.id == displayedIDs[current] }) else { return true }
            MomentReviewWindowManager.shared.open(moment: moment, decisions: decisions, curator: curator) {
                Task { await curator.refreshOverview(); schedulePlaceResolution() }
            }
            return true
        default: return false
        }
        if let next { activeMomentID = displayedIDs[next]; return true }
        return false
    }

    private func openMergeDraft() {
        let chosen = curator.moments.filter { selection.ids.contains($0.id) }
        guard chosen.count == selection.ids.count else {
            curator.errorMessage = "Collections changed. Please select them again."
            return
        }
        do {
            mergeDraft = MomentMergeDraft(moments: chosen, revision: try MomentMergeDraft.store.load().revision)
        } catch {
            curator.errorMessage = "Could not open the saved grouping record. No changes were made."
        }
    }

    private func momentWasUploaded(_ moment: PhotoMoment) -> Bool {
        let assetIDs: [String]
        if let selection = moment.selection {
            assetIDs = MomentReviewDecisions.apply(decisions.values, to: selection,
                                                   photos: moment.photos).selected
        } else {
            assetIDs = moment.photos.map(\.id)
        }
        return model.momentWasUploaded(assetIDs)
    }

    private func schedulePlaceResolution() {
        placeResolutionTask?.cancel()
        let snapshot = curator.moments
        placeResolutionTask = Task { await resolvePlaces(snapshot) }
    }

    private func resolvePlaces(_ moments: [PhotoMoment]) async {
        let calendar = Calendar.current
        var gpsByDay: [Date: [IndexedPhoto]] = [:]
        for photo in moments.lazy.flatMap(\.photos) where photo.latitude != nil && photo.longitude != nil {
            guard let created = photo.created else { continue }
            gpsByDay[calendar.startOfDay(for: created), default: []].append(photo)
        }
        for key in gpsByDay.keys {
            gpsByDay[key]?.sort { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
        }

        for moment in moments {
            guard !Task.isCancelled else { return }
            if let resolved = await CuratorGeocodingService.shared.place(for: moment) {
                guard !Task.isCancelled else { return }
                places[moment.id] = resolved
            } else if let created = moment.photos.first?.created,
                      let extrapolated = CuratorLocationExtrapolator.extrapolate(
                        moment: moment,
                        allDayPhotos: gpsByDay[calendar.startOfDay(for: created)] ?? [],
                        calendar: calendar) {
                guard !Task.isCancelled else { return }
                places[moment.id] = await CuratorGeocodingService.shared.place(for: extrapolated.latitude, longitude: extrapolated.longitude)
            }
        }
    }
}

struct MomentCoverCard: View {
    let moment: PhotoMoment
    @ObservedObject var decisions: MomentReviewDecisions
    var place: ResolvedPlace? = nil
    var uploadedToGoogle = false
    var loadPreview = true
    @AppStorage("curator.fontSizeScale") private var fontSizeScale: Double = 1.0

    var body: some View {
        let selection = moment.selection.map { MomentReviewDecisions.apply(decisions.values, to: $0, photos: moment.photos) }
        let title = MomentPresentation.title(moment, custom: decisions.titles[moment.id], place: place)
        let userAuthored = decisions.titles[moment.id] != nil || decisions.descriptions[moment.id] != nil || moment.reviewedGroupTitle != nil
        let contextual = MomentDisplayEligibility.isContextOnly(moment, decisions: decisions.values, userAuthored: userAuthored)
        let cover = MomentDisplayEligibility.browsingCover(
            moment, decisions: decisions.values, selected: selection?.selected ?? [])
        let status = contextual ? "Saved in library"
            : MomentPresentation.status(moment, pending: selection?.pending.isEmpty != true, userAuthored: userAuthored, place: place)
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(.quaternary)
                if let cover {
                    if loadPreview {
                        SimilarityThumbnail(photo: cover, height: 190, squareCrop: false,
                                            requestedEdge: 640, showsTimestamp: false)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.image").font(.largeTitle)
                        Text("No preview photo").font(.caption)
                    }.foregroundStyle(.secondary)
                }
                if moment.publishedAlbumID != nil || uploadedToGoogle {
                    HStack(spacing: 8) {
                        if uploadedToGoogle {
                            Label("In Google", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11 * fontSizeScale, weight: .semibold))
                                .foregroundStyle(.blue)
                        }
                        if moment.publishedAlbumID != nil {
                            Label("In Photos", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11 * fontSizeScale, weight: .semibold))
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
                }
            }.frame(height: 190).clipped()
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 16 * fontSizeScale, weight: .semibold))
                    .lineLimit(2)
                    .help(title)
                    .textSelection(.enabled)
                let hCount = selection?.selected.count ?? 0
                let hWord = hCount == 1 ? "highlight" : "highlights"
                let pCount = moment.photos.count
                let pWord = pCount == 1 ? "photo" : "photos"
                Text("\(hCount) \(hWord) · \(pCount) \(pWord)")
                    .font(.system(size: 14 * fontSizeScale, weight: .medium))
                    .foregroundStyle(.secondary)
                if !status.isEmpty {
                    Text(status)
                        .font(.system(size: 13 * fontSizeScale, weight: status.hasPrefix("Title preparation") ? .medium : .regular))
                        .foregroundStyle(status.hasPrefix("Title preparation") ? Color.orange : Color.secondary)
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }.background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct MomentViewportPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct MomentsWorkspaceHelpView: View {
    @AppStorage("curator.fontSizeScale") private var fontSizeScale: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundStyle(.tint)
                    .font(.title2)
                Text("About Moments")
                    .font(.system(size: 18 * fontSizeScale, weight: .bold))
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "cpu").font(.title3).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("On-Device Intelligence")
                            .font(.system(size: 15 * fontSizeScale, weight: .semibold))
                        Text("Moments are organized privately on your Mac while idle. No photos or personal data are uploaded to the cloud.")
                            .font(.system(size: 13 * fontSizeScale))
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "calendar.badge.clock").font(.title3).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prioritize a Time Range")
                            .font(.system(size: 15 * fontSizeScale, weight: .semibold))
                        Text("Want to organize a specific trip or month first? Use \"Prioritize a Time Range…\" to prepare those photos immediately.")
                            .font(.system(size: 13 * fontSizeScale))
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "shield.lefthalf.filled").font(.title3).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Originals Stay Under Your Control")
                            .font(.system(size: 15 * fontSizeScale, weight: .semibold))
                        Text("Curated albums reference existing originals. Favorite changes are explicit, and Delete always confirms before Photos moves an original to Recently Deleted.")
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

struct CuratorSettingsView: View {
    @ObservedObject var curator: CuratorController
    @ObservedObject var model: PhotoRelayViewModel
    @State private var diagnostics = false
    @AppStorage("curator.fontSizeScale") private var fontSizeScale: Double = 1.0
    @ObservedObject private var meaningfulPlaces = MeaningfulPlacesStore.shared
    @State private var addingPlace = false
    @State private var editingPlace: MeaningfulPlace?

    var body: some View {
        Form {
            Section("Display & Accessibility") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Text Size")
                        Spacer()
                        if abs(fontSizeScale - 1.0) > 0.01 {
                            Button("Reset (100%)") { fontSizeScale = 1.0 }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                        Text("\(Int(round(fontSizeScale * 100)))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "textformat.size.smaller")
                            .foregroundStyle(.secondary)
                        Slider(value: $fontSizeScale, in: 0.85...1.8, step: 0.05)
                        Image(systemName: "textformat.size.larger")
                            .foregroundStyle(.secondary)
                    }
                    Text("Adjust text size for easier reading across Moments, descriptions, and photo details.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Background Curation") {
                Toggle("Prepare Moments while this Mac is idle", isOn: Binding(
                    get: { curator.enabled }, set: { curator.setEnabled($0) }))
                Toggle("Auto-save ready albums to Photos", isOn: Binding(
                    get: { curator.autoPublishEnabled }, set: { curator.setAutoPublishEnabled($0) }))
                Toggle("Open Photo Curator at login", isOn: Binding(
                    get: { curator.loginEnabled }, set: { curator.setLoginEnabled($0) }))
                Text("Moments are organized privately on this Mac while idle. Albums reference your existing library under 'Photo Curator'; titles and stories remain editable in Photo Curator.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Places") {
                if meaningfulPlaces.places.isEmpty {
                    Text("Add familiar locations to turn generic map names into captions such as “Morning at Home” or “Portraits at the Studio.”")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(meaningfulPlaces.places) { place in
                        HStack {
                            Image(systemName: place.label.localizedCaseInsensitiveContains("home") ? "house.fill" : "mappin.circle.fill")
                                .foregroundStyle(.tint).frame(width: 22)
                            VStack(alignment: .leading) {
                                Text(place.label)
                                Text("\(place.address) · \(Int(place.radius)) m")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button {
                                editingPlace = place
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .help("Edit \(place.label)")
                            Button(role: .destructive) {
                                meaningfulPlaces.remove(place)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete \(place.label)")
                        }
                    }
                }
                Button("Add Meaningful Place…") { addingPlace = true }
                Text("Saved on this Mac. Address and venue lookups use Apple Maps; Photo Curator never sends photo pixels with a place lookup.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Google Photos") {
                Toggle("Skip videos", isOn: $model.skipVideos)
                Toggle("Skip Live Photos", isOn: $model.skipLivePhotos)
                Text("These apply when selected Moment highlights or Favorites are staged temporarily for Google Photos.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Button("Open Diagnostics…") { diagnostics = true }
        }.padding(24).frame(width: 540)
            .sheet(isPresented: $addingPlace) {
                MeaningfulPlaceEditor(store: meaningfulPlaces)
            }
            .sheet(item: $editingPlace) { place in
                MeaningfulPlaceEditor(store: meaningfulPlaces, place: place)
            }
            .sheet(isPresented: $diagnostics) {
                VStack {
                    HStack { Text("Curator Diagnostics").font(.headline); Spacer(); Button("Done") { diagnostics = false } }.padding()
                    CuratorDiagnosticsView(curator: curator)
                }.frame(minWidth: 820, minHeight: 600)
            }
    }
}

private struct MomentGoogleExportView: View {
    let moments: [PhotoMoment]
    @ObservedObject var decisions: MomentReviewDecisions
    @ObservedObject var model: PhotoRelayViewModel
    let close: () -> Void
    @State private var favoritesOnly = false
    @State private var selectedAlbumID = ""
    @State private var newAlbumTitle = ""
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save to Google Photos").font(.title2.bold())
            Text(moments.isEmpty
                 ? "Save Favorites from your complete Photos library. Google only exposes albums created by this app through its current API."
                 : "Choose the photos and an album managed by Photo Curator. Google only exposes albums created by this app through its current API.")
                .foregroundStyle(.secondary)
            Picker("Photos", selection: $favoritesOnly) {
                Text("Curator Highlights").tag(false)
                Text("Photos Favorites").tag(true)
            }.pickerStyle(.segmented)
                .disabled(moments.isEmpty)

            if !model.googleConnected {
                Button("Sign in with Google") { model.signInToGoogle() }
                    .buttonStyle(.borderedProminent).disabled(model.isWorking)
                Text("Google sign-in opens in your system browser and is reused while the saved authorization remains valid.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Destination album", selection: $selectedAlbumID) {
                    Text("Create a new album").tag("")
                    ForEach(model.googleAlbums) { album in Text("\(album.title) (\(album.count))").tag(album.id) }
                }
                if selectedAlbumID.isEmpty {
                    TextField("New Google Photos album name", text: $newAlbumTitle).textFieldStyle(.roundedBorder)
                } else {
                    HStack {
                        Text("New photos will be appended unless you choose replacement in the review step.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear Album…", role: .destructive) { confirmingClear = true }
                            .disabled(model.isWorking)
                    }
                }
            }
            HStack {
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Review & Save") {
                    model.frameAlbumID = selectedAlbumID
                    if selectedAlbumID.isEmpty {
                        model.frameAlbumTitle = newAlbumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if let album = model.googleAlbums.first(where: { $0.id == selectedAlbumID }) {
                        model.frameAlbumTitle = album.title
                    }
                    model.startMomentSync(moments: moments, decisions: decisions, favoritesOnly: favoritesOnly)
                    close()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.googleConnected || model.isWorking || (selectedAlbumID.isEmpty && newAlbumTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24).frame(width: 520)
        .onAppear {
            if moments.isEmpty { favoritesOnly = true }
            selectedAlbumID = model.frameAlbumID
            newAlbumTitle = model.frameAlbumTitle
            if model.googleConnected { model.signInToGoogle() }
        }
        .alert("Clear this Google Photos album?", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Album", role: .destructive) {
                model.clearGoogleAlbum(id: selectedAlbumID)
            }
        } message: {
            Text("Removes photos accessible to Photo Curator from this album. The photos remain in your Google Photos library. Items not accessible to this app are left untouched.")
        }
    }
}
