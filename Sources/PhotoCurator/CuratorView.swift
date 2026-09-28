import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CuratorDiagnosticsView: View {
    @ObservedObject var curator: CuratorController
    @Environment(\.dismiss) private var dismiss
    @State private var exportingDiagnostics = false
    @State private var diagnosticExportStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Diagnostics").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            Form {
                Section("Catalog Status") {
                    LabeledContent("Indexed photos", value: curator.indexedCount.formatted())
                    LabeledContent("Photos without dates", value: curator.undatedCount.formatted())
                    LabeledContent("Available Moments", value: curator.availableMoments.formatted())
                    LabeledContent("This session",
                        value: "\(curator.analyzedThisSession.formatted()) analyzed, \(curator.deferredThisSession.formatted()) deferred")
                    Text(curator.activity)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if curator.scanTotal > 0 && curator.scanned < curator.scanTotal {
                        ProgressView(value: Double(curator.scanned), total: Double(curator.scanTotal))
                    }
                }

                Section("Support Export") {
                    Text("Exports app and macOS versions, aggregate catalog sizes, and counts-only activity history. It never includes photos, identifiers, filenames, titles, locations, OCR, or account credentials.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button(exportingDiagnostics ? "Preparing Diagnostics…" : "Export Diagnostics…") {
                            exportDiagnostics()
                        }
                        .disabled(exportingDiagnostics)
                        if let diagnosticExportStatus {
                            Text(diagnosticExportStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(12)
        }
        .frame(width: 560, height: 420)
        .alert("Photo Curator", isPresented: Binding(
            get: { curator.errorMessage != nil },
            set: { if !$0 { curator.errorMessage = nil } })) {
                Button("OK") { curator.errorMessage = nil }
            } message: {
                Text(curator.errorMessage ?? "")
            }
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
