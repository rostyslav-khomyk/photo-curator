import SwiftUI
import AppKit
import Photos

struct CuratorView: View {
    private static let allMomentsScopeID = "all"

    @ObservedObject var curator: CuratorController
    @ObservedObject var model: PhotoCuratorViewModel
    @StateObject private var decisions = MomentReviewDecisions()
    @State private var selecting = false
    @State private var selection = MomentMultiSelection()
    @State private var mergeDraft: MomentMergeDraft?
    @State private var showWorkspaceHelp = false
    @State private var showLibraryOverview = false
    @State private var googleExportMoments: [PhotoMoment] = []
    @State private var showingGoogleExport = false
    @State private var activeMomentID: String?
    @State private var selectedStoryID: String = CuratorView.allMomentsScopeID
    @State private var editingStory: StorySummary?
    @State private var selectingJourneys = false
    @State private var journeySelection = Set<String>()
    @State private var journeyMergeDraft: JourneyMergeDraft?
    @State private var selectedJourneyStops = Set<Int>()
    @AppStorage("curator.hidePublishedMoments.v1") private var hidePublishedMoments = false
    @AppStorage("curator.hideGoogleUploadedMoments.v1") private var hideGoogleUploadedMoments = false
    /// Persisted via UserDefaults writes — not @AppStorage — so soak/activity ticks and
    /// focus changes do not invalidate the All Moments ScrollView through AppStorage.
    @State private var savedActiveMomentID = UserDefaults.standard.string(forKey: "curator.lastActiveMomentID.v1") ?? ""
    @State private var savedScrollAnchorMomentID = UserDefaults.standard.string(forKey: "curator.scrollAnchorMomentID.v1") ?? ""
    @State private var savedBrowseStoryID = UserDefaults.standard.string(forKey: "curator.browseStoryID.v1") ?? ""
    @State private var restoredScrollPosition = false
    @State private var scrollRestoreID: String?
    /// Scroll-to only for keyboard navigation — never while the user is free-scrolling.
    @State private var keyboardScrollID: String?
    @ObservedObject private var meaningfulPlaces = MeaningfulPlacesStore.shared

    private var libraryMoments: [MomentSummary] {
        curator.momentSummaries.filter { moment in
            (!hidePublishedMoments || !moment.inPhotos)
                && (!hideGoogleUploadedMoments || !moment.inGoogle)
        }
    }

    private var visibleMoments: [MomentSummary] {
        guard selectedStoryID != Self.allMomentsScopeID,
              let story = curator.storySummaries.first(where: { $0.id == selectedStoryID }) else {
            return libraryMoments
        }
        let members = Set(story.momentIDs)
        let inStory = libraryMoments.filter { members.contains($0.id) }
        guard story.kind == .journey, !selectedJourneyStops.isEmpty else { return inStory }
        return JourneyMomentFilter.applying(inStory, stops: story.stops, selected: selectedJourneyStops)
    }

    private var displayedIDs: [String] {
        visibleMoments.map(\.id)
    }

    private var journeyStories: [StorySummary] {
        // Placeholder `Journey from Home` shells flicker while stops geocode; seasonal and renamed titles stay.
        curator.storySummaries.filter(\.isFinalizedJourney)
    }

    private var outingStories: [StorySummary] {
        curator.storySummaries.filter { $0.kind == .outing }
    }

    private var selectedStory: StorySummary? {
        guard selectedStoryID != Self.allMomentsScopeID else { return nil }
        return curator.storySummaries.first { $0.id == selectedStoryID }
    }

    private var detailTitle: String {
        selectedStory?.title ?? "Moments"
    }

    private var detailSubtitle: String {
        if let story = selectedStory {
            let range: String
            if Calendar.current.isDate(story.start, inSameDayAs: story.end) {
                range = story.start.formatted(.dateTime.month(.abbreviated).day().year())
            } else {
                range = "\(story.start.formatted(.dateTime.month(.abbreviated).day()))–\(story.end.formatted(.dateTime.month(.abbreviated).day().year()))"
            }
            return "\(range) · \(story.momentIDs.count) Moments · \(story.photoCount) photos"
        }
        return "Your library, rediscovered. Curated privately on your Mac."
    }

    private var storiesSidebar: some View {
        Group {
            if selectingJourneys {
                // Native multi-select: clicking rows (and ⌘-click) toggles merge members.
                List(selection: $journeySelection) {
                    Section {
                        Text("Click Journeys to include in the merge. Choose at least two, then Merge Journeys.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                    Section("Journeys") {
                        ForEach(journeyStories) { story in
                            storySidebarRow(story, systemImage: "map",
                                            checked: journeySelection.contains(story.id))
                                .tag(story.id)
                        }
                    }
                }
            } else {
                List(selection: $selectedStoryID) {
                    Section {
                        Label("All Moments", systemImage: "square.grid.2x2")
                            .tag(Self.allMomentsScopeID)
                            .accessibilityLabel("Show all Moments")
                    }
                    if !journeyStories.isEmpty {
                        Section("Journeys") {
                            ForEach(journeyStories) { story in
                                storySidebarRow(story, systemImage: "map")
                                    .tag(story.id)
                            }
                        }
                    }
                    if !outingStories.isEmpty {
                        Section("Outings") {
                            ForEach(outingStories) { story in
                                storySidebarRow(story, systemImage: "mappin.and.ellipse")
                                    .tag(story.id)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // A List's ideal height is all of its rows; reported upward it makes the split
        // taller than the window and pushes All Moments above the toolbar.
        .frame(minHeight: 0, idealHeight: 0, maxHeight: .infinity)
        .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 420)
    }

    private func storySidebarRow(_ story: StorySummary, systemImage: String, checked: Bool? = nil) -> some View {
        HStack(spacing: 8) {
            if let checked {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(checked ? Color.accentColor : .secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(story.title)
                    .lineLimit(2)
                Text("\(story.momentIDs.count) Moments · \(story.photoCount) photos · \(story.highlightCount) highlights")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityLabel(checked == nil
            ? "\(story.title), \(story.momentIDs.count) Moments, \(story.highlightCount) highlights"
            : (checked == true
               ? "\(story.title), selected for merge"
               : "\(story.title), not selected for merge"))
        .accessibilityAddTraits(checked == true ? .isSelected : [])
    }

    private var momentsDetail: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(detailTitle).font(.largeTitle.bold()).textSelection(.enabled)
                    Text(detailSubtitle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let story = selectedStory {
                        if let synopsis = story.synopsis, !synopsis.isEmpty {
                            Text(synopsis)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let uncertainty = StoryNarrativeUncertainty.line(title: story.title, stops: story.stops) {
                            Label(uncertainty, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button(story.kind == .journey
                               ? "Rename Journey…"
                               : (story.customized ? "Edit Story Title & Synopsis…" : "Suggest Story Title & Synopsis…")) {
                            editingStory = story
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                    HStack(spacing: 6) {
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
                        if selectedStory != nil {
                            Button("Show All Moments") { selectedStoryID = Self.allMomentsScopeID }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                }
                Spacer()
            }.padding(24)
            if let story = selectedStory, story.kind == .journey, story.stops.count >= 2 {
                JourneyRoutePanel(stops: story.stops, selectedStopIDs: selectedJourneyStops,
                                  onToggleStop: toggleJourneyStop, onClearStops: { selectedJourneyStops = [] })
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
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
            // Equatable timeline: curator.activity / story geocode publishes must not rebuild
            // the LazyVGrid and kick All Moments back toward the start.
            MomentsTimelineScroll(
                scopeID: selectedStoryID,
                moments: visibleMoments,
                emptyTitle: emptyMomentsTitle,
                emptyMessage: emptyMomentsMessage,
                emptySystemImage: selectedStory != nil
                    ? "map"
                    : (hidePublishedMoments ? "line.3.horizontal.decrease.circle" : "photo.stack"),
                overviewLoading: curator.overviewLoading,
                showAllMomentsButton: selectedStory != nil,
                activeMomentID: activeMomentID,
                selecting: selecting,
                selectionIDs: selection.ids,
                customTitles: decisions.titles,
                customDescriptions: decisions.descriptions,
                restoredScrollPosition: restoredScrollPosition,
                keyboardScrollID: $keyboardScrollID,
                scrollRestoreID: $scrollRestoreID,
                onSelect: { id in
                    if selecting {
                        selection.click(id, ordered: displayedIDs, range: NSEvent.modifierFlags.contains(.shift))
                    } else {
                        activeMomentID = id
                        openMoment(id)
                    }
                },
                onShowAllMoments: { selectedStoryID = Self.allMomentsScopeID },
                onRestored: { restoredScrollPosition = true },
                onPersistAnchor: { id in
                    savedScrollAnchorMomentID = id
                    UserDefaults.standard.set(id, forKey: "curator.scrollAnchorMomentID.v1")
                },
                onPrioritize: { id in
                    Task { await prioritizeActiveMoment(id) }
                }
            )
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            CuratorActivityFooter(activity: curator.activity)
        }
    }

    private var emptyMomentsTitle: String {
        if curator.overviewLoading { return "Loading your collections…" }
        if !selectedJourneyStops.isEmpty { return "No Moments at the selected stops" }
        if selectedStory != nil { return "No Moments in this Story" }
        if hidePublishedMoments { return "All loaded Moments are already in Photos" }
        return "Your Moments are taking shape"
    }

    private var emptyMomentsMessage: String {
        if !selectedJourneyStops.isEmpty {
            return "These flags do not overlap the Moments in this Journey. Clear the map filter to see the whole trip."
        }
        if selectedStory != nil {
            return "This Story’s Moments may be hidden by filters, or its membership is still catching up."
        }
        if hidePublishedMoments || hideGoogleUploadedMoments {
            return "Adjust the Moment filters to see hidden collections."
        }
        return "Photo Curator prepares collections in the background. Moments remain available while their titles are still being refined."
    }

    var body: some View {
        browsableWorkspace
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("PhotoCuratorGroupReviewChanged"))) { _ in
            Task { await curator.refreshOverview() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .photoCuratorPhotosAccessChanged)) { _ in
            Task { await curator.refreshOverview() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized {
                reloadMomentSummaries()
            }
        }
        .sheet(item: $mergeDraft) { draft in
            MomentMergeView(draft: draft, decisions: decisions, curator: curator) {
                selection = MomentMultiSelection(); selecting = false
                Task { await curator.refreshOverview() }
            }
        }
        .sheet(item: $journeyMergeDraft) { draft in
            JourneyMergeSheet(stories: draft.stories, curator: curator) {
                finishJourneyMerge(draft)
            }
        }
        .sheet(item: $editingStory) { story in
            StoryNarrativeSheet(story: story, curator: curator) {
                editingStory = nil
            }
        }
        .sheet(isPresented: $showingGoogleExport) { googleExportSheet }
        .alert("Moments", isPresented: Binding(get: { curator.errorMessage != nil }, set: { if !$0 { curator.errorMessage = nil } })) {
            Button("OK") { curator.errorMessage = nil }
        } message: { Text(curator.errorMessage ?? "") }
    }

    private var googleExportSheet: some View {
        MomentGoogleExportView(moments: googleExportMoments, decisions: decisions, model: model) {
            showingGoogleExport = false
            googleExportMoments = []
        }
    }

    private var browsableWorkspace: some View {
        NavigationSplitView {
            storiesSidebar
        } detail: {
            momentsDetail
                .frame(minHeight: 0, idealHeight: 0, maxHeight: .infinity, alignment: .top)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minHeight: 0, idealHeight: 0, maxHeight: .infinity)
        .toolbar {
            if selectingJourneys {
                ToolbarItem(placement: .navigation) {
                    Text("Select Journeys").font(.headline)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                workspaceToolbarItems
            }
        }
        .task {
            await curator.reloadMomentSummaries(googleUploadedAssetIDs: model.uploadedGoogleAssetIDs,
                                                 reviewDecisions: decisions.values)
            restoreBrowseScope()
            if activeMomentID == nil {
                activeMomentID = displayedIDs.contains(savedActiveMomentID) ? savedActiveMomentID : displayedIDs.first
            }
            if !savedScrollAnchorMomentID.isEmpty, displayedIDs.contains(savedScrollAnchorMomentID) {
                scrollRestoreID = savedScrollAnchorMomentID
            } else {
                restoredScrollPosition = true
            }
        }
        .onChange(of: model.uploadedGoogleAssetIDs) { ids in
            Task { await curator.reloadMomentSummaries(googleUploadedAssetIDs: ids,
                                                        reviewDecisions: decisions.values) }
        }
        .onChange(of: decisions.values) { values in
            Task { await curator.reloadMomentSummaries(googleUploadedAssetIDs: model.uploadedGoogleAssetIDs,
                                                        reviewDecisions: values) }
        }
        .onChange(of: selectedStoryID) { id in
            selectedJourneyStops = []
            let browse = id == Self.allMomentsScopeID ? "" : id
            savedBrowseStoryID = browse
            UserDefaults.standard.set(browse, forKey: "curator.browseStoryID.v1")
            selection = MomentMultiSelection()
            selecting = false
            activeMomentID = displayedIDs.first
            restoredScrollPosition = true
        }
        .onChange(of: curator.storySummaries) { _ in
            restoreBrowseScope()
        }
        .onChange(of: displayedIDs) { ids in
            // Keep focus if still present; never steal scroll by jumping to the first Moment on refresh.
            if let active = activeMomentID, ids.contains(active) { return }
            activeMomentID = ids.first
            if !restoredScrollPosition, !savedScrollAnchorMomentID.isEmpty,
               ids.contains(savedScrollAnchorMomentID) {
                scrollRestoreID = savedScrollAnchorMomentID
            }
        }
        .onChange(of: activeMomentID) { id in
            guard let id else { return }
            savedActiveMomentID = id
            UserDefaults.standard.set(id, forKey: "curator.lastActiveMomentID.v1")
        }
        .background(MomentGridKeyHandler { event in handleGridKey(event) })
    }

    private func reloadMomentSummaries() {
        Task {
            await curator.reloadMomentSummaries(googleUploadedAssetIDs: model.uploadedGoogleAssetIDs,
                                                 reviewDecisions: decisions.values)
        }
    }

    @ViewBuilder
    private var workspaceToolbarItems: some View {
        Button {
            showLibraryOverview = true
        } label: {
            Label("Library Overview", systemImage: "chart.bar.xaxis")
        }
        .help("See capture density across your library")
        .popover(isPresented: $showLibraryOverview) {
            LibraryOverviewView(periods: curator.libraryOverview)
        }

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
            Task {
                googleExportMoments = await curator.momentDetails(selection.ids)
                showingGoogleExport = true
            }
        } label: {
            Label("Save to Google Photos", systemImage: "icloud.and.arrow.up")
        }
        .disabled(model.isWorking)
        .help(selection.ids.isEmpty
              ? "Save Favorites from your Photos library to Google Photos"
              : "Review selected Moment highlights or Favorites for Google Photos")

        Button(action: openMergeDraft) {
            Label("Merge Moments", systemImage: "rectangle.stack.badge.plus")
        }
        .disabled(selection.ids.count < 2)
        .help("Merge the selected Moments")

        journeyToolbarButtons
    }

    @ViewBuilder
    private var journeyToolbarButtons: some View {
        Button {
            guard let story = selectedStory, story.kind == .journey else { return }
            editingStory = story
        } label: {
            Label("Rename Journey", systemImage: "pencil")
        }
        .disabled(selectedStory?.kind != .journey)
        .help("Edit this Journey’s name and synopsis")

        Button {
            if selectingJourneys {
                selectingJourneys = false
                journeySelection = []
            } else {
                selectingJourneys = true
                // Seed with the Journey currently open, if any.
                if let story = selectedStory, story.kind == .journey {
                    journeySelection = [story.id]
                } else {
                    journeySelection = []
                }
            }
        } label: {
            Label(selectingJourneys ? "Cancel Journey Selection" : "Select Journeys",
                  systemImage: selectingJourneys ? "xmark.circle" : "checkmark.circle")
        }
        .help(selectingJourneys
              ? "Leave merge selection"
              : "Multi-select Journeys in the sidebar, then Merge Journeys")

        Button(action: openJourneyMerge) {
            Label(journeySelection.count >= 2
                  ? "Merge Journeys (\(journeySelection.count))"
                  : "Merge Journeys",
                  systemImage: "arrow.triangle.merge")
        }
        .disabled(journeySelection.count < 2)
        .help(journeySelection.count < 2
              ? "Select at least two Journeys in the sidebar first"
              : "Merge the selected Journeys into one")

        Button {
            Task {
                do { try await curator.reprocessJourneys() }
                catch { curator.errorMessage = error.localizedDescription }
            }
        } label: {
            Label("Refresh Journey Names", systemImage: "arrow.clockwise")
        }
        .disabled(curator.maintenanceBusy || journeyStories.isEmpty)
        .help("Retitle Journeys from countries/seasons and rebuild home start/end circles")
    }

    private func finishJourneyMerge(_ draft: JourneyMergeDraft) {
        let members = Set(draft.stories.flatMap(\.momentIDs))
        journeySelection = []
        selectingJourneys = false
        journeyMergeDraft = nil
        if let merged = curator.storySummaries.first(where: { Set($0.momentIDs) == members && $0.kind == .journey }) {
            selectedStoryID = merged.id
        }
    }

    private func openJourneyMerge() {
        let chosen = journeyStories.filter { journeySelection.contains($0.id) }
        guard chosen.count >= 2 else { return }
        journeyMergeDraft = JourneyMergeDraft(stories: chosen)
    }

    private func toggleJourneyStop(_ id: Int) {
        if selectedJourneyStops.contains(id) { selectedJourneyStops.remove(id) }
        else { selectedJourneyStops.insert(id) }
    }

    private func restoreBrowseScope() {
        if !savedBrowseStoryID.isEmpty,
           let saved = curator.storySummaries.first(where: { $0.id == savedBrowseStoryID }),
           saved.kind != .journey || saved.isFinalizedJourney {
            selectedStoryID = savedBrowseStoryID
        } else if selectedStoryID != Self.allMomentsScopeID {
            let selected = curator.storySummaries.first(where: { $0.id == selectedStoryID })
            let visible = selected.map { $0.kind != .journey || $0.isFinalizedJourney } ?? false
            if !visible {
                selectedStoryID = Self.allMomentsScopeID
            }
        }
    }

    private func handleGridKey(_ event: NSEvent) -> Bool {
        guard mergeDraft == nil, !showingGoogleExport, googleExportMoments.isEmpty,
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
            openMoment(displayedIDs[current])
            return true
        default: return false
        }
        if let next {
            let id = displayedIDs[next]
            activeMomentID = id
            keyboardScrollID = id
            return true
        }
        return false
    }

    private func openMergeDraft() {
        Task {
            let chosen = await curator.momentDetails(selection.ids)
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
    }

    private func openMoment(_ id: String) {
        Task {
            if let moment = await curator.momentDetail(id) {
            MomentReviewWindowManager.shared.open(moment: moment, decisions: decisions, curator: curator) {
                Task {
                    // Light refresh after review; avoid a full library sync on every close.
                    await curator.reloadMomentSummaries(
                        googleUploadedAssetIDs: model.uploadedGoogleAssetIDs,
                        reviewDecisions: decisions.values)
                }
            }
                return
            }
            if curator.errorMessage == nil {
                curator.errorMessage = "This Moment is no longer available."
            }
        }
    }

    /// Viewport analysis priority only for the focused Moment — not every cell that appears while scrolling.
    private func prioritizeActiveMoment(_ id: String?) async {
        guard let id, let detail = await curator.momentDetail(id) else { return }
        let applied = detail.selection.map {
            MomentReviewDecisions.apply(decisions.values, to: $0, photos: detail.photos)
        }
        let priority = MomentDisplayEligibility.viewportPriorityPhotos(
            detail, decisions: decisions.values, selected: applied?.selected ?? [])
        await curator.prioritizeVisibleMoment(detail, photos: priority)
    }
}

/// Isolates the All Moments ScrollView from CuratorController activity publishes.
/// Equality ignores closures; parent must pass stable moment/selection inputs.
private struct MomentsTimelineScroll: View, Equatable {
    let scopeID: String
    let moments: [MomentSummary]
    let emptyTitle: String
    let emptyMessage: String
    let emptySystemImage: String
    let overviewLoading: Bool
    let showAllMomentsButton: Bool
    let activeMomentID: String?
    let selecting: Bool
    let selectionIDs: Set<String>
    let customTitles: [String: String]
    let customDescriptions: [String: String]
    let restoredScrollPosition: Bool
    @Binding var keyboardScrollID: String?
    @Binding var scrollRestoreID: String?
    let onSelect: (String) -> Void
    let onShowAllMoments: () -> Void
    let onRestored: () -> Void
    let onPersistAnchor: (String) -> Void
    let onPrioritize: (String?) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scopeID == rhs.scopeID
            && lhs.moments == rhs.moments
            && lhs.emptyTitle == rhs.emptyTitle
            && lhs.emptyMessage == rhs.emptyMessage
            && lhs.emptySystemImage == rhs.emptySystemImage
            && lhs.overviewLoading == rhs.overviewLoading
            && lhs.showAllMomentsButton == rhs.showAllMomentsButton
            && lhs.activeMomentID == rhs.activeMomentID
            && lhs.selecting == rhs.selecting
            && lhs.selectionIDs == rhs.selectionIDs
            && lhs.customTitles == rhs.customTitles
            && lhs.customDescriptions == rhs.customDescriptions
            && lhs.restoredScrollPosition == rhs.restoredScrollPosition
            && lhs.keyboardScrollID == rhs.keyboardScrollID
            && lhs.scrollRestoreID == rhs.scrollRestoreID
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if moments.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: emptySystemImage)
                            .font(.system(size: 42)).foregroundStyle(.secondary)
                        Text(emptyTitle).font(.title2)
                        Text(emptyMessage)
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .frame(maxWidth: 480)
                        if overviewLoading { ProgressView().controlSize(.small) }
                        if showAllMomentsButton {
                            Button("Show All Moments", action: onShowAllMoments)
                        }
                    }.frame(maxWidth: .infinity).padding(60)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 380), spacing: 20)], spacing: 24) {
                        ForEach(moments) { moment in
                            Button {
                                onSelect(moment.id)
                            } label: {
                                MomentSummaryCard(moment: moment,
                                                  customTitle: customTitles[moment.id],
                                                  customDescription: customDescriptions[moment.id],
                                                  loadPreview: restoredScrollPosition)
                                    .overlay(alignment: .topTrailing) {
                                        if selecting {
                                            Image(systemName: selectionIDs.contains(moment.id) ? "checkmark.circle.fill" : "circle")
                                                .font(.title2)
                                                .foregroundStyle(selectionIDs.contains(moment.id) ? Color.accentColor : .secondary)
                                                .padding(8).background(.regularMaterial, in: Circle()).padding(8)
                                        }
                                    }
                                    .overlay {
                                        if activeMomentID == moment.id {
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(Color.accentColor, lineWidth: 2)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .id(moment.id)
                            .accessibilityValue(selecting ? (selectionIDs.contains(moment.id) ? "Selected" : "Not selected") : "")
                            .accessibilityLabel("Open Moment, \(customTitles[moment.id] ?? moment.headline ?? moment.start.formatted(.dateTime.month(.abbreviated).day().year()))")
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id("moments-scroll-\(scopeID)")
            .onChange(of: activeMomentID) { id in
                if let id { onPersistAnchor(id) }
                onPrioritize(id)
            }
            .onChange(of: keyboardScrollID) { id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(id, anchor: .center) }
                keyboardScrollID = nil
            }
            .onChange(of: scrollRestoreID) { id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .top)
                onRestored()
                scrollRestoreID = nil
            }
        }
    }
}

private struct CuratorActivityFooter: View {
    let activity: String

    var body: some View {
        HStack {
            Text(activity).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
        }.padding(14).background(.bar)
    }
}

private struct LibraryOverviewView: View {
    let periods: [LibraryOverviewPeriod]

    private var maximum: Int { max(1, periods.map(\.photoCount).max() ?? 1) }
    private var totals: (photos: Int, moments: Int, highlights: Int) {
        periods.reduce((0, 0, 0)) { ($0.0 + $1.photoCount, $0.1 + $1.momentCount, $0.2 + $1.highlightCount) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Library Overview").font(.title2.bold())
            Text("Capture density across your library. Quiet months are simply months with fewer photographs; they are not less important.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if periods.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Overview is preparing").font(.headline)
                    Text("Monthly totals will appear after Moment summaries load.")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let totals = totals
                Text("\(totals.photos.formatted()) photos · \(totals.moments.formatted()) Moments · \(totals.highlights.formatted()) highlights")
                    .font(.headline).monospacedDigit()
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(periods.reversed()) { period in
                            HStack(spacing: 10) {
                                Text(month(period)).frame(width: 82, alignment: .leading)
                                GeometryReader { geometry in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.accentColor.opacity(0.7))
                                        .frame(width: max(2, geometry.size.width
                                            * CGFloat(period.photoCount) / CGFloat(maximum)))
                                }.frame(height: 9)
                                Text(period.photoCount.formatted())
                                    .font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
        .padding(20).frame(width: 480, height: 520)
    }

    private func month(_ period: LibraryOverviewPeriod) -> String {
        var components = DateComponents()
        components.year = period.year; components.month = period.month; components.day = 1
        return Calendar.current.date(from: components)?.formatted(.dateTime.month(.abbreviated).year())
            ?? period.id
    }
}

struct MomentSummaryCard: View {
    let moment: MomentSummary
    let customTitle: String?
    let customDescription: String?
    var loadPreview = true
    @AppStorage("curator.fontSizeScale") private var fontSizeScale: Double = 1.0

    private var title: String {
        customTitle ?? moment.headline
            ?? moment.start.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private var status: String {
        if customTitle != nil || customDescription != nil || moment.customized { return "✓ Customized" }
        if !moment.groupingReady { return "Preparing grouping…" }
        // Date/place titles are already shown; richer captions upgrade quietly in the background.
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(.quaternary)
                if moment.coverAssetID != nil || !moment.fallbackCoverAssetIDs.isEmpty {
                    if loadPreview {
                        MomentSummaryThumbnail(moment: moment)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.image").font(.largeTitle)
                        Text("No preview photo").font(.caption)
                    }.foregroundStyle(.secondary)
                }
                if moment.inPhotos || moment.inGoogle {
                    HStack(spacing: 8) {
                        if moment.inGoogle {
                            Label("In Google", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        }
                        if moment.inPhotos {
                            Label("In Photos", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .font(.system(size: 11 * fontSizeScale, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule()).padding(8)
                }
            }.frame(height: 190).clipped()
            VStack(alignment: .leading, spacing: 6) {
                // No textSelection here: it steals trackpad drag from ScrollView on macOS.
                Text(title).font(.system(size: 16 * fontSizeScale, weight: .semibold))
                    .lineLimit(2).help(title)
                Text("\(moment.highlightCount) \(moment.highlightCount == 1 ? "highlight" : "highlights") · \(moment.photoCount) \(moment.photoCount == 1 ? "photo" : "photos")")
                    .font(.system(size: 14 * fontSizeScale, weight: .medium)).foregroundStyle(.secondary)
                if !status.isEmpty {
                    Text(status).font(.system(size: 13 * fontSizeScale,
                        weight: status.hasPrefix("Title preparation") ? .medium : .regular))
                        .foregroundStyle(status.hasPrefix("Title preparation") ? Color.orange : Color.secondary)
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { PhotoKitThumbnailProvider.setCaching(true, assetIDs: moment.fallbackCoverAssetIDs, edge: 480) }
        .onDisappear { PhotoKitThumbnailProvider.setCaching(false, assetIDs: moment.fallbackCoverAssetIDs, edge: 480) }
    }
}

private struct MomentSummaryThumbnail: View {
    let moment: MomentSummary
    @State private var candidateIndex = 0

    private var candidates: [String] {
        var result: [String] = []
        for id in [moment.coverAssetID].compactMap({ $0 }) + moment.fallbackCoverAssetIDs where !result.contains(id) {
            result.append(id)
        }
        return result
    }

    var body: some View {
        if candidates.indices.contains(candidateIndex) {
            let assetID = candidates[candidateIndex]
            SimilarityThumbnail(photo: IndexedPhoto(id: assetID, created: moment.start,
                modified: nil, latitude: nil, longitude: nil, favorite: false, width: 1, height: 1),
                height: 190, requestedEdge: 480, showsTimestamp: false,
                cacheRevision: "\(moment.id)-\(moment.revision)-\(assetID)") { _ in
                    if candidateIndex + 1 < candidates.count { candidateIndex += 1 }
                }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo.badge.exclamationmark")
                Text("Preview unavailable").font(.caption)
            }.foregroundStyle(.secondary)
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
                    Image(systemName: "sidebar.left").font(.title3).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stories Filter Moments")
                            .font(.system(size: 15 * fontSizeScale, weight: .semibold))
                        Text("Choose a Journey or Outing in the sidebar to show only its Moments. Drag the divider to resize. All Moments clears the filter.")
                            .font(.system(size: 13 * fontSizeScale))
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
    @ObservedObject var model: PhotoCuratorViewModel
    @State private var similaritySettings = false
    @AppStorage("curator.fontSizeScale") private var fontSizeScale: Double = 1.0
    @AppStorage("curatorJourneyPlaceNames") private var journeyPlaceNames = true
    @AppStorage("curatorJourneyRoadRoutes") private var journeyRoadRoutes = false
    @AppStorage(ExperimentalUnlocatedJourneyBuilder.extendedAccessKey) private var extendedPhotosMetadata = true
    @ObservedObject private var meaningfulPlaces = MeaningfulPlacesStore.shared
    @State private var addingPlace = false
    @State private var editingPlace: MeaningfulPlace?
    @State private var resetPreview: CuratorResetPreview?
    @State private var loadingResetPreview = false

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
                Toggle("Prepare Moments in the background", isOn: Binding(
                    get: { curator.enabled }, set: { curator.setEnabled($0) }))
                Toggle("Auto-save ready albums to Photos", isOn: Binding(
                    get: { curator.autoPublishEnabled }, set: { curator.setAutoPublishEnabled($0) }))
                Toggle("Open Photo Curator at login", isOn: Binding(
                    get: { curator.loginEnabled }, set: { curator.setLoginEnabled($0) }))
                Text("Moment preparation runs privately at low priority and pauses for sync, Low Power Mode, or thermal pressure. Albums reference your existing library under 'Photo Curator'.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Curation") {
                Toggle("Balanced shortlist", isOn: Binding(
                    get: { curator.balancedSelection }, set: { curator.setBalancedSelection($0) }))
                Text("Keeps Favorites and representative photos across time, location, and photo type while reducing near-identical shots.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Similar Photos Settings…") { similaritySettings = true }
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
                Toggle("Name Journeys with Apple Maps", isOn: $journeyPlaceNames)
                    .onChange(of: journeyPlaceNames) { _ in curator.journeyPlaceNamingChanged() }
                Toggle("Road routes for Journey maps", isOn: $journeyRoadRoutes)
                Text("Saved on this Mac. Address and venue lookups use Apple Maps; Photo Curator never sends photo pixels with a place lookup. Road routes optionally ask Apple Maps for paths between Journey stops only — never per photo.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Google Photos") {
                Toggle("Skip videos", isOn: $model.skipVideos)
                Toggle("Skip Live Photos", isOn: $model.skipLivePhotos)
            }

            Section("Experimental") {
                Toggle("Use experimental extended access to Photos metadata", isOn: $extendedPhotosMetadata)
                    .onChange(of: extendedPhotosMetadata) { _ in curator.experimentalPhotosMetadataChanged() }
                Text("Reads People names, original filenames, and time zones from the Photos library database to build Journeys for pre-2010 photos without location. Read-only and private to this Mac. These fields are not public Apple API and may stop working after a macOS update.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Maintenance") {
                Button("Reset Photo Curator…", role: .destructive) {
                    loadingResetPreview = true
                    Task {
                        do { resetPreview = try await curator.nuclearResetPreview() }
                        catch { curator.errorMessage = error.localizedDescription }
                        loadingResetPreview = false
                    }
                }
                .disabled(loadingResetPreview || curator.maintenanceBusy || curator.syncBusy)
                if loadingResetPreview { ProgressView().controlSize(.small) }
                if let message = curator.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }.padding(24).frame(width: 540)
            .sheet(isPresented: $addingPlace) {
                MeaningfulPlaceEditor(store: meaningfulPlaces)
            }
            .sheet(item: $editingPlace) { place in
                MeaningfulPlaceEditor(store: meaningfulPlaces, place: place)
            }
            .sheet(isPresented: $similaritySettings) {
                SimilaritySettingsView(curator: curator)
            }
            .sheet(item: $resetPreview) { preview in
                NuclearResetConfirmationView(preview: preview, curator: curator) {
                    resetPreview = nil
                }
            }
    }
}

private struct NuclearResetConfirmationView: View {
    let preview: CuratorResetPreview
    @ObservedObject var curator: CuratorController
    let close: () -> Void
    @State private var understandsLoss = false

    private var reclaimed: String {
        ByteCountFormatter.string(fromByteCount: preview.reclaimableBytes, countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reset Photo Curator").font(.title2.bold())
            Text("This removes your local Moment titles, selections, merges, review decisions, analysis, and publication history. It cannot be undone.")
            GroupBox("Verified effects") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Delete \(preview.verifiedAlbums) proven Photo Curator albums and \(preview.verifiedFolders) proven folders")
                    Text("Reclaim approximately \(reclaimed) of generated local data")
                    Text("Preserve \(preview.library.assets.formatted()) Photos assets and \(preview.library.favorites.formatted()) Favorites")
                    if preview.unverifiedAlbums > 0 {
                        Text("Keep the Photos albums referenced by \(preview.unverifiedAlbums.formatted()) older publication records. Photo Curator cannot prove it created those albums, so they will remain in Photos.")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text("After Photos confirms the container changes, Photo Curator quits and reopens on its own to finish the clean rebuild.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("I understand that my Photo Curator edits and curation will be permanently removed", isOn: $understandsLoss)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                    .disabled(curator.maintenanceBusy)
                Button("Reset Photo Curator", role: .destructive) {
                    Task {
                        do {
                            try await curator.performNuclearReset(preview)
                            close()
                            await Task.yield()
                            curator.quitAndRelaunchAfterReset()
                        } catch {
                            curator.errorMessage = error.localizedDescription
                            close()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!understandsLoss || curator.maintenanceBusy)
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(curator.maintenanceBusy)
    }
}

private struct MomentGoogleExportView: View {
    let moments: [PhotoMoment]
    @ObservedObject var decisions: MomentReviewDecisions
    @ObservedObject var model: PhotoCuratorViewModel
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
