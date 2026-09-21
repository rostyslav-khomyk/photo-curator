import Foundation

struct PhotoDisplayEvidence: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable { case screenshot, map, menu, document }
    static let version = "display-evidence-v1-" + NarrativeVisualContext.version + MomentTextEvidenceStore.engine + CuratorVisionAnalyzer.version
    let revision: String
    let engine: String
    let reason: Reason

    var explanation: String {
        let clue: String
        switch reason {
        case .screenshot: clue = "PhotoKit identifies this as a screenshot."
        case .map: clue = "Local visual analysis suggests a map or guide."
        case .menu: clue = "Local text analysis suggests a menu."
        case .document: clue = "Local visual and text analysis suggest a document."
        }
        return clue + " Kept for context, not automatically selected for display. Choose Include to keep it; nothing is removed from Photos."
    }
}

/// Conservative display roles, not Photos utility categories or a judgment of personal value.
enum MomentDisplayEligibility {
    static func isAutoPublishEligible(_ moment: PhotoMoment, decisions: [String: ReviewDecision], userAuthored: Bool) -> Bool {
        return moment.publishedAlbumID == nil
            && (moment.groupingState == .ready || moment.groupingState == .reviewed)
            && !moment.photos.isEmpty
            && !isSupportingCollection(moment, decisions: decisions, userAuthored: userAuthored)
    }

    /// Feed promotion only: never changes membership, evidence, or review decisions.
    static func isSupportingCollection(_ moment: PhotoMoment, decisions: [String: ReviewDecision], userAuthored: Bool) -> Bool {
        guard !userAuthored, moment.groupingState != .reviewed, moment.reviewedGroupTitle == nil else { return false }
        let eligible = displayCandidates(in: moment, decisions: decisions)
        if eligible.contains(where: { $0.favorite || decisions[$0.id] == .include }) { return false }
        if eligible.isEmpty { return true }
        guard let selection = moment.selection else { return true }
        if !selection.selected.contains(where: { decisions[$0] != .exclude }) { return true }
        // A lone unendorsed photo is available for review, not promoted as an event.
        return moment.photos.count == 1
    }

    static func classify(_ photo: IndexedPhoto, labels: [String], lines: [PhotoTextLine],
                         result: CuratorVisionResult?) -> PhotoDisplayEvidence? {
        func evidence(_ reason: PhotoDisplayEvidence.Reason) -> PhotoDisplayEvidence {
            PhotoDisplayEvidence(revision: photo.analysisRevision, engine: PhotoDisplayEvidence.version, reason: reason)
        }
        if photo.similarityCategory == .screenshots { return evidence(.screenshot) }
        let labels = Set(labels.map { $0.lowercased().replacingOccurrences(of: "_", with: " ") })
        // An aesthetic utility flag alone must not suppress collections, artwork or people.
        let meaningful: Set<String> = ["people", "person", "adult", "doll", "dolls", "toy", "figurine", "painting",
            "sculpture", "statue", "flower", "garden", "food", "meal"]
        if !labels.isDisjoint(with: meaningful) { return nil }
        let text = lines.prefix(100).filter { $0.confidence.isFinite && (0.9...1).contains($0.confidence) && $0.text.count <= 500 }
        let tokens = Set(text.flatMap { $0.text.lowercased().components(separatedBy: CharacterSet.letters.inverted) })
        let headings: Set<String> = ["starters", "soups", "desserts", "appetizers", "entrees", "hoofdgerechten", "voorgerechten", "nagerechten"]
        let dishes: Set<String> = ["steak", "steaks", "burger", "burgers", "ribs", "fries", "salad", "soup", "shrimp"]
        let singular: [String: String] = ["steaks": "steak", "burgers": "burger", "soups": "soup", "shrimps": "shrimp"]
        let dishFamilies = Set(tokens.map { singular[$0] ?? $0 }).intersection(dishes)
        let menu = tokens.intersection(headings).count >= 2
            || (!tokens.isDisjoint(with: ["menu", "menukaart"]) && tokens.intersection(dishes).count >= 2)
            || (text.count >= 12 && dishFamilies.count >= 4)
        if text.count >= 6 && menu { return evidence(.menu) }
        let utility: Bool
        if let result, result.version == CuratorVisionAnalyzer.version,
           case .available(let signal) = result.aesthetics, signal.score.isFinite { utility = signal.utility }
        else { utility = false }
        if labels.contains("map") && (labels.contains("document") || utility) { return evidence(.map) }
        if (labels.contains("document") && (text.count >= 6 || utility)) || (utility && text.count >= 12) {
            return evidence(.document)
        }
        return nil
    }

    static func evidence(for photo: IndexedPhoto, in moment: PhotoMoment) -> PhotoDisplayEvidence? {
        if photo.similarityCategory == .screenshots {
            return PhotoDisplayEvidence(revision: photo.analysisRevision, engine: PhotoDisplayEvidence.version, reason: .screenshot)
        }
        guard let value = moment.displayEvidence?[photo.id], value.revision == photo.analysisRevision,
              value.engine == PhotoDisplayEvidence.version else { return nil }
        return value
    }

    static func automaticCandidates(in moment: PhotoMoment) -> [IndexedPhoto] {
        moment.photos.filter { $0.favorite || evidence(for: $0, in: moment) == nil }
    }

    static func annotate(_ selection: MomentSelection, moment: PhotoMoment) -> MomentSelection {
        var output = selection
        let contextual = moment.photos.filter { !$0.favorite && evidence(for: $0, in: moment) != nil }
        output.contextOnly = contextual.map(\.id)
        for photo in contextual { output.explanations[photo.id] = evidence(for: photo, in: moment)?.explanation }
        return output
    }

    static func displayCandidates(in moment: PhotoMoment, decisions: [String: ReviewDecision]) -> [IndexedPhoto] {
        moment.photos.filter {
            decisions[$0.id] != .exclude && (decisions[$0.id] == .include || $0.favorite || evidence(for: $0, in: moment) == nil)
        }
    }

    static func isContextOnly(_ moment: PhotoMoment, decisions: [String: ReviewDecision], userAuthored: Bool) -> Bool {
        guard !userAuthored, moment.groupingState != .reviewed, moment.reviewedGroupTitle == nil else { return false }
        return !moment.photos.isEmpty && displayCandidates(in: moment, decisions: decisions).isEmpty
    }

    static func cover(_ moment: PhotoMoment, decisions: [String: ReviewDecision], selected: [String]) -> IndexedPhoto? {
        let eligible = displayCandidates(in: moment, decisions: decisions)
        let selected = Set(selected)
        return eligible.first { selected.contains($0.id) && $0.favorite }
            ?? eligible.first { selected.contains($0.id) } ?? eligible.first
    }

    /// Workspace preview only. A contextual photo may represent its collection visually
    /// without becoming a highlight or changing what is published.
    static func browsingCover(_ moment: PhotoMoment, decisions: [String: ReviewDecision], selected: [String]) -> IndexedPhoto? {
        if let curated = cover(moment, decisions: decisions, selected: selected) { return curated }
        let available = moment.photos.filter { decisions[$0.id] != .exclude }
        return available.first(where: \.favorite) ?? available.first
    }

    /// Keep viewport promotion bounded so one large historical collection cannot starve
    /// the rest of the library's background work.
    static func viewportPriorityPhotos(_ moment: PhotoMoment, decisions: [String: ReviewDecision],
                                       selected: [String], limit: Int = 12) -> [IndexedPhoto] {
        guard limit > 0 else { return [] }
        let available = moment.photos.filter { decisions[$0.id] != .exclude }
        guard !available.isEmpty else { return [] }
        let selected = Set(selected)
        let preferred = available.filter { selected.contains($0.id) && $0.favorite }
            + available.filter { selected.contains($0.id) && !$0.favorite }
            + available.filter { !selected.contains($0.id) && $0.favorite }
        var seen = Set<String>()
        var output = preferred.filter { seen.insert($0.id).inserted }.prefix(limit).map { $0 }
        let remaining = limit - output.count
        if available.count <= remaining {
            output += available.filter { seen.insert($0.id).inserted }
        } else if remaining == 1 {
            let photo = available[available.count / 2]
            if seen.insert(photo.id).inserted { output.append(photo) }
        } else {
            for index in 0..<remaining {
                let photo = available[index * (available.count - 1) / (remaining - 1)]
                if seen.insert(photo.id).inserted { output.append(photo) }
            }
        }
        return Array(output.prefix(limit))
    }
}
