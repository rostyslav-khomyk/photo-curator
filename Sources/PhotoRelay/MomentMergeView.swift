import SwiftUI

struct MomentMergeDraft: Identifiable {
    let id = UUID()
    let moments: [PhotoMoment]
    let revision: Int
    static var store: GroupReviewStore {
        GroupReviewStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Relay/curator/group-review.json"))
    }
}

struct MomentMergeView: View {
    let draft: MomentMergeDraft
    @ObservedObject var decisions: MomentReviewDecisions
    @ObservedObject var curator: CuratorController
    let completed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var error: String?
    @State private var merging = false

    private var sourceTitles: [String] {
        draft.moments.map { MomentPresentation.title($0, custom: decisions.titles[$0.id]) }
    }

    private var titleSuggestions: [String] {
        let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return sourceTitles.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }.prefix(4).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Merge \(draft.moments.count) Moments").font(.title2.bold())
            Text("Creates one saved collection. If any selected Moments already have Photo Curator albums in Photos, a verified replacement is created before those old album containers are removed. Original photos are never deleted by merging.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(draft.moments) { moment in
                        Text(MomentPresentation.title(moment, custom: decisions.titles[moment.id]))
                            .font(.headline).textSelection(.enabled)
                        if let description = decisions.descriptions[moment.id] {
                            Text(description).font(.caption).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 180)
            TextField("Name for the merged Moment", text: $title).textFieldStyle(.roundedBorder)
            if !titleSuggestions.isEmpty {
                HStack(spacing: 6) {
                    Text("Suggestions:").font(.caption).foregroundStyle(.secondary)
                    ForEach(titleSuggestions, id: \.self) { suggestion in
                        Button(suggestion) { title = suggestion }
                            .buttonStyle(.link)
                            .lineLimit(1)
                    }
                }
            }
            Text("Choose a name for the result. Original names and descriptions are retained in the local merge record. The merged membership is protected from automatic regrouping.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(merging ? "Merging…" : "Merge") {
                    merging = true
                    Task {
                        do {
                            try await curator.mergeMoments(draft.moments,
                                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                decisions: decisions, expectedRevision: draft.revision)
                            completed(); dismiss()
                        } catch {
                            self.error = "The merged Moment was kept, but Photo Curator could not safely finish every Photos album change: \(error.localizedDescription)"
                        }
                        merging = false
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(merging || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 200)
            }
        }.padding(24).frame(width: 520)
    }
}
