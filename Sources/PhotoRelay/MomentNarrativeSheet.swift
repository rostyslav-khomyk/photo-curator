import SwiftUI

struct MomentNarrativeSheet: View {
    let moment: PhotoMoment
    @ObservedObject var decisions: MomentReviewDecisions
    @Environment(\.dismiss) private var dismiss

    @AppStorage("curator.fontSizeScale") private var fontSizeScale: Double = 1.0
    @State private var title = ""
    @State private var description = ""
    @State private var suggestion: MomentNarrativeSuggestion?
    @State private var candidates: [MomentNarrativeText] = []
    @State private var error: String?
    @State private var loading = true
    @State private var progress = "Reading local previews…"
    @State private var textEvidence = false
    @State private var textClue = ""
    @State private var detectedClues: [PhotoTextLine] = []
    @State private var place: ResolvedPlace? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: Title & subtitle on left, Cancel on right
            HStack(alignment: .top) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20 * fontSizeScale))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suggest Title & Story")
                            .font(.system(size: 18 * fontSizeScale, weight: .bold))
                        Text("Generated locally using on-device intelligence.")
                            .font(.system(size: 13 * fontSizeScale))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .font(.system(size: 12 * fontSizeScale))
            }

            // Title
            VStack(alignment: .leading, spacing: 5) {
                Text("Title")
                    .font(.system(size: 13 * fontSizeScale, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Moment title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15 * fontSizeScale))
                    .accessibilityLabel("Moment title")
            }

            // Story
            VStack(alignment: .leading, spacing: 6) {
                Text("Story")
                    .font(.system(size: 13 * fontSizeScale, weight: .semibold))
                    .foregroundStyle(.secondary)

                // Clean on-device OCR pills without confidence percentages
                if !detectedClues.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Text Found in Photos")
                                .font(.system(size: 11 * fontSizeScale, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                textEvidence = true
                            } label: {
                                Text("All Photos…")
                                    .font(.system(size: 11 * fontSizeScale))
                            }
                            .buttonStyle(.link)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(detectedClues, id: \.text) { clue in
                                    let isSelected = textClue == clue.text
                                    Button {
                                        if isSelected {
                                            textClue = ""
                                        } else {
                                            textClue = clue.text
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text(clue.text)
                                            if isSelected {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.system(size: 11 * fontSizeScale))
                                            }
                                        }
                                        .font(.system(size: 12 * fontSizeScale, weight: isSelected ? .semibold : .regular))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
                                        .foregroundStyle(isSelected ? .white : .primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 2)
                }

                TextEditor(text: $description)
                    .font(.system(size: 14 * fontSizeScale))
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    .accessibilityLabel("Moment description")
            }

            Divider()

            // Suggestions Section
            Text("Suggestions")
                .font(.system(size: 15 * fontSizeScale, weight: .bold))

            if loading {
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(progress)
                        .font(.system(size: 13 * fontSizeScale))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if let error {
                Text(error)
                    .font(.system(size: 13 * fontSizeScale))
                    .foregroundStyle(.secondary)
            } else if candidates.isEmpty && suggestion == nil {
                Text("No suggestions available for this moment.")
                    .font(.system(size: 13 * fontSizeScale))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(displayCandidates.enumerated()), id: \.offset) { _, candidate in
                            let isTopPick = candidate.title == suggestion?.text.title
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(alignment: .center) {
                                    Text(candidate.title)
                                        .font(.system(size: 15 * fontSizeScale, weight: .bold))
                                        .foregroundStyle(.primary)

                                    Spacer()

                                    if isTopPick {
                                        HStack(spacing: 4) {
                                            Image(systemName: "sparkles")
                                            Text("Top Pick")
                                        }
                                        .font(.system(size: 11 * fontSizeScale, weight: .semibold))
                                        .foregroundStyle(.tint)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2.5)
                                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                                    }
                                }

                                Text(candidate.description)
                                    .font(.system(size: 13 * fontSizeScale))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)

                                // Action buttons on dedicated row so "Apply" never truncates
                                HStack(spacing: 8) {
                                    Spacer()
                                    Button("Use Title") {
                                        title = candidate.title
                                    }
                                    .font(.system(size: 12 * fontSizeScale))
                                    .buttonStyle(.bordered)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)

                                    Button("Use Story") {
                                        description = candidate.description
                                    }
                                    .font(.system(size: 12 * fontSizeScale))
                                    .buttonStyle(.bordered)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)

                                    Button("Apply") {
                                        title = candidate.title
                                        description = candidate.description
                                    }
                                    .font(.system(size: 12 * fontSizeScale, weight: .semibold))
                                    .buttonStyle(.borderedProminent)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                            .padding(12)
                            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: 230)
            }

            Spacer(minLength: 4)

            // Footer: Privacy status on left, Save to Moment on right
            HStack(alignment: .center) {
                HStack(spacing: 5) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 13 * fontSizeScale))
                    Text("On-Device & Private")
                        .font(.system(size: 12 * fontSizeScale))
                }
                .foregroundStyle(.secondary)

                Spacer()

                Button("Save to Moment") {
                    saveAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .font(.system(size: 13 * fontSizeScale, weight: .semibold))
            }
        }
        .padding(22)
        .frame(minWidth: 560, idealWidth: 580, maxWidth: 620, minHeight: 500, idealHeight: 580, maxHeight: 640)
        .sheet(isPresented: $textEvidence) {
            MomentTextEvidenceView(moment: moment) { textClue = $0 }
        }
        .onAppear {
            title = decisions.titles[moment.id] ?? moment.reviewedGroupTitle ?? ""
            description = decisions.descriptions[moment.id] ?? ""
        }
        .task(id: textClue) {
            await loadSuggestions()
        }
    }

    private var displayCandidates: [MomentNarrativeText] {
        var items: [MomentNarrativeText] = []
        if let top = suggestion?.text {
            items.append(top)
        }
        for c in candidates where c.title != suggestion?.text.title {
            items.append(c)
        }
        return items
    }

    private func saveAndDismiss() {
        decisions.setTitle(title, for: moment.id, moment: moment)
        decisions.setDescription(description, for: moment.id, moment: moment)
        dismiss()
    }

    private func loadSuggestions() async {
        loading = true
        suggestion = nil
        candidates = []
        error = nil
        place = await CuratorGeocodingService.shared.place(for: moment)
        let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Relay/curator/narrative-cache.json")
        let textDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Relay/curator/text-evidence")
        let textStore = MomentTextEvidenceStore(directory: textDir, cache: try? DerivedCacheStore.production())

        var metadata = MomentNarrativeMetadata(
            dateLabel: moment.start.formatted(date: .abbreviated, time: .omitted),
            photoCount: moment.photos.count,
            favoriteCount: moment.favorites,
            verifiedPlace: place?.friendlyName
        )
        metadata.textClue = textClue.isEmpty ? nil : textClue
        do {
            let loader = CuratorThumbnailLoader(provider: PhotoKitThumbnailProvider())
            let classifier = NarrativeVisualContext()
            var frequencies: [String: Int] = [:]
            var rawTextLines: [PhotoTextLine] = []
            let ordered = moment.photos.sorted { $0.id < $1.id }
            let step = max(1, Int(ceil(Double(ordered.count) / 8)))
            let sample = stride(from: 0, to: ordered.count, by: step).map { ordered[$0] }
            for (index, photo) in sample.enumerated() {
                try Task.checkCancellation()
                progress = "Reading photo \(index + 1) of \(sample.count)…"
                do {
                    let image = try await loader.load(assetID: photo.id, timeout: 5)
                    for label in try await classifier.labels(image) { frequencies[label, default: 0] += 1 }

                    // Automatic on-device OCR scan & cache query
                    if let cached = await textStore.cached(photo) {
                        rawTextLines.append(contentsOf: cached.lines)
                    } else if let recognized = try? await textStore.recognize(image) {
                        _ = try? await textStore.save(recognized, for: photo)
                        rawTextLines.append(contentsOf: recognized)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { try Task.checkCancellation() }
            }

            // Extract clean, high-confidence text clues without raw percentages
            let filteredClues = rawTextLines.filter { line in
                let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.confidence >= 0.70, trimmed.count >= 3, trimmed.count <= 40 else { return false }
                let letters = trimmed.filter { $0.isLetter }
                return letters.count >= 3 && !trimmed.allSatisfy { $0.isNumber || $0.isPunctuation }
            }
            var uniqueClues: [String: PhotoTextLine] = [:]
            for line in filteredClues {
                let key = line.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let existing = uniqueClues[key] {
                    if line.confidence > existing.confidence { uniqueClues[key] = line }
                } else {
                    uniqueClues[key] = line
                }
            }
            let sortedClues = Array(uniqueClues.values.sorted {
                if abs($0.confidence - $1.confidence) > 0.05 {
                    return $0.confidence > $1.confidence
                }
                return $0.text.count < $1.text.count
            }.prefix(5))
            self.detectedClues = sortedClues

            // Automatically use top text clue if none manually selected
            if metadata.textClue == nil, let topClue = sortedClues.first, topClue.confidence >= 0.80 {
                metadata.textClue = topClue.text
            }

            metadata.visualLabels = Array(frequencies.keys.sorted {
                let a = frequencies[$0]!, b = frequencies[$1]!
                return a == b ? $0 < $1 : a > b
            }.prefix(8))

            candidates = (try? LocalMomentNarrative.candidates(metadata)) ?? []
            progress = "Generating suggestions…"
            let value = try await LocalMomentNarrative(cacheURL: cache).suggest(metadata, model: AppleLocalNarrativeModel())
            try Task.checkCancellation()
            suggestion = value
        } catch is CancellationError { return }
        catch { self.error = "A suggestion could not be prepared. You can still write and save your own text." }
        loading = false
    }
}
