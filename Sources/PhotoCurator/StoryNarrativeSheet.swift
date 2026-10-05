import SwiftUI

struct StoryNarrativeSheet: View {
    let story: StorySummary
    @ObservedObject var curator: CuratorController
    let close: () -> Void

    @State private var title: String
    @State private var synopsis: String
    @State private var candidates: [StoryNarrativeText] = []
    @State private var busy = false
    @State private var status = ""

    init(story: StorySummary, curator: CuratorController, close: @escaping () -> Void) {
        self.story = story
        self.curator = curator
        self.close = close
        _title = State(initialValue: story.title)
        _synopsis = State(initialValue: story.synopsis ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Story Title & Synopsis").font(.title2.bold())
            Text("Candidates come only from this Story’s stops, dates, and transport evidence. The optional on-device model may pick among them; it never invents places.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Title", text: $title)
            TextField("Synopsis", text: $synopsis, axis: .vertical)
                .lineLimit(3...6)
            if let uncertainty = StoryNarrativeUncertainty.line(title: story.title, stops: story.stops) {
                Label(uncertainty, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !candidates.isEmpty {
                Text("Grounded candidates").font(.headline)
                ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.title).font(.body.weight(.semibold))
                        Text(candidate.synopsis).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Use Title") { title = candidate.title }
                            Button("Use Synopsis") { synopsis = candidate.synopsis }
                            Button("Apply Both") {
                                title = candidate.title
                                synopsis = candidate.synopsis
                            }
                        }.buttonStyle(.link).font(.caption)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Suggest") { Task { await suggest() } }
                    .disabled(busy)
                Spacer()
                Button("Clear Customization") {
                    Task {
                        do {
                            try await curator.saveStoryEdit(id: story.id, title: nil, synopsis: nil)
                            close()
                        } catch { status = error.localizedDescription }
                    }
                }
                .disabled(busy)
                Button("Cancel", role: .cancel) { close() }
                Button("Save") {
                    Task {
                        do {
                            try await curator.saveStoryEdit(id: story.id, title: title, synopsis: synopsis)
                            close()
                        } catch { status = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(24)
        .frame(width: 520)
        .task { await suggest() }
    }

    private func suggest() async {
        busy = true
        status = "Preparing grounded candidates…"
        defer { busy = false }
        let metadata = LocalStoryNarrative.metadata(for: story)
        candidates = (try? LocalStoryNarrative.candidates(metadata)) ?? []
        do {
            let choice = try await LocalStoryNarrative.suggest(metadata, model: AppleLocalNarrativeModel())
            if title == story.title { title = choice.title }
            if synopsis.isEmpty || synopsis == story.synopsis { synopsis = choice.synopsis }
            status = "Ready. Save to keep your edits across Story rebuilds."
        } catch {
            status = error.localizedDescription
        }
    }
}
