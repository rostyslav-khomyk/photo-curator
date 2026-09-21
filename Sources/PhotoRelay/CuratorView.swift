import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CuratorDiagnosticsView: View {
    @ObservedObject var curator: CuratorController
    @State private var similaritySettings = false
    @State private var reviewing: PhotoMoment?
    @StateObject private var reviewDecisions = MomentReviewDecisions()
    @State private var exportingDiagnostics = false
    @State private var diagnosticExportStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Rediscover your moments").font(.largeTitle.weight(.semibold))
                        Text("Let your Mac prepare your library quietly, or process a period now.")
                            .foregroundStyle(.secondary)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Analyze my Photos library while this Mac is idle", isOn: Binding(
                                get: { curator.enabled }, set: { curator.setEnabled($0) }))
                            Toggle("Open Photo Relay at login", isOn: Binding(
                                get: { curator.loginEnabled }, set: { curator.setLoginEnabled($0) }))
                            Text("Metadata and local visual analysis. No iCloud downloads, internet lookups, or album changes. Pauses between photos during activity, sync, Low Power Mode, or thermal pressure.")
                                .font(.caption).foregroundStyle(.secondary)
                            Divider()
                            Text("\(curator.indexedCount.formatted()) photos indexed · \(curator.undatedCount.formatted()) without dates")
                                .font(.callout).monospacedDigit()
                            Text("This session: \(curator.analyzedThisSession) visual results saved, \(curator.deferredThisSession) deferred.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(8)
                    }

                    GroupBox("Read-only library test") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(curator.diagnosticReport).font(.callout).textSelection(.enabled)
                            if curator.diagnosticRunning {
                                Button("Stop Test") { curator.stopDiagnostic() }
                            } else {
                                Button("Test Local Photos") { curator.runDiagnostic() }
                                    .disabled(curator.syncBusy || curator.foregroundActive || curator.selectedRange == nil)
                            }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Support diagnostics") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Exports app and macOS versions, aggregate catalog sizes, and counts-only activity history. It never includes photos, identifiers, filenames, titles, locations, OCR, or account credentials.")
                                .font(.callout).foregroundStyle(.secondary)
                            HStack {
                                Button(exportingDiagnostics ? "Preparing Diagnostics..." : "Export Diagnostics...") {
                                    exportDiagnostics()
                                }
                                .disabled(exportingDiagnostics)
                                if let diagnosticExportStatus {
                                    Text(diagnosticExportStatus).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(alignment: .center) {
                        Picker("Time range", selection: $curator.period) {
                            ForEach(CuratorPeriod.allCases) { Text($0.title).tag($0) }
                        }
                        .frame(maxWidth: 280)
                        .disabled(curator.foregroundActive)
                        Spacer()
                        if curator.foregroundActive {
                            Button("Stop Range Scan") { curator.stopForeground() }
                        } else {
                            Button("Process This Range Now") { curator.processRangeNow() }
                                .buttonStyle(.borderedProminent)
                                .disabled(curator.selectedRange == nil || curator.syncBusy || curator.diagnosticRunning)
                        }
                    }
                    if curator.period == .custom {
                        HStack {
                            DatePicker("From", selection: $curator.customStart, displayedComponents: .date)
                            DatePicker("Through", selection: $curator.customEnd, displayedComponents: .date)
                        }
                        .disabled(curator.foregroundActive)
                    }
                    if let interval = curator.selectedRange {
                        Text("\(interval.start.formatted(date: .abbreviated, time: .omitted)) – \(interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Choose an end date on or after the start date.").foregroundStyle(.red)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Toggle("Balanced shortlist (experimental)", isOn: Binding(
                            get: { curator.balancedSelection }, set: { curator.setBalancedSelection($0) }))
                        Text("Keeps Favorites and representatives across photo types, half-hours and GPS areas. Unknown locations are kept in a separate group. Other shots remain available as alternatives.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Similar Photos Settings...") { similaritySettings = true }
                            .disabled(curator.selectedRange == nil || curator.syncBusy)
                        Text("\(curator.moments.count.formatted()) candidate moments").font(.headline)
                        Text("Grouped by day, time gaps, and location. A conservative first selection keeps Favorites and reduces near-identical shots. Thumbnail review comes next; nothing is deleted or published.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if curator.moments.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.stack").font(.largeTitle).foregroundStyle(.secondary)
                            Text("No indexed moments in this period")
                            Text("Process this range now, or leave background indexing enabled while your Mac is idle.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(25)
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(curator.moments) { moment in
                                HStack(spacing: 14) {
                                    Image(systemName: "calendar").font(.title2).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(reviewDecisions.titles[moment.id] ?? moment.start.formatted(date: .abbreviated, time: .omitted)).font(.headline)
                                        Text("\(moment.start.formatted(date: .omitted, time: .shortened)) – \(moment.end.formatted(date: .omitted, time: .shortened))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text("\(moment.photos.count.formatted()) photos · \(moment.favorites) favorites")
                                        if let selection = moment.selection {
                                            let reviewed = MomentReviewDecisions.apply(reviewDecisions.values, to: selection, photos: moment.photos)
                                            let excluded = moment.photos.filter { reviewDecisions.values[$0.id] == .exclude }.count
                                            Text("\(reviewed.selected.count) selected · \(reviewed.similar.count) similar · \(reviewed.alternatives.count) alternatives · \(reviewed.pending.count) awaiting analysis · \(excluded) excluded by you")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Text(moment.hasLocation ? "Location metadata available" : "Location unknown")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Button("Review Photos...") {
                                            MomentReviewWindowManager.shared.open(moment: moment, decisions: reviewDecisions)
                                        }
                                    }
                                }
                                .padding(14)
                                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 850)
                .frame(maxWidth: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                if curator.scanTotal > 0 && curator.scanned < curator.scanTotal {
                    ProgressView(value: Double(curator.scanned), total: Double(curator.scanTotal))
                }
                Text(curator.activity).font(.callout).foregroundStyle(.secondary)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
        }
        .task { await curator.refreshOverview() }
        .sheet(isPresented: $similaritySettings) { SimilaritySettingsView(curator: curator) }
        .onChange(of: curator.period) { _ in Task { await curator.refreshOverview() } }
        .onChange(of: curator.customStart) { _ in Task { await curator.refreshOverview() } }
        .onChange(of: curator.customEnd) { _ in Task { await curator.refreshOverview() } }
        .alert("Photo Relay Curator", isPresented: Binding(get: { curator.errorMessage != nil }, set: { if !$0 { curator.errorMessage = nil } })) {
            Button("OK") { curator.errorMessage = nil }
        } message: { Text(curator.errorMessage ?? "") }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Photo Curator Diagnostics.json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let context = DiagnosticExportContext(
            indexedPhotos: curator.indexedCount,
            availableMoments: curator.availableMoments,
            visibleMoments: curator.moments.count,
            analyzedThisSession: curator.analyzedThisSession,
            deferredThisSession: curator.deferredThisSession,
            backgroundCurationEnabled: curator.enabled,
            automaticPublicationEnabled: curator.autoPublishEnabled
        )
        exportingDiagnostics = true
        diagnosticExportStatus = nil
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try DiagnosticBundleExporter.export(context: context, to: destination)
                }.value
                diagnosticExportStatus = "Saved"
            } catch {
                diagnosticExportStatus = "Export failed"
                curator.errorMessage = error.localizedDescription
            }
            exportingDiagnostics = false
        }
    }
}
