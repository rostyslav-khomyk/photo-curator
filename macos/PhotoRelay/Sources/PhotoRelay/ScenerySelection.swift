import Foundation

/// Shortlist variety, not duplicate detection. Only compares retained scenery in one Moment.
enum ScenerySelection {
    static func select(_ selection: MomentSelection, photos: [IndexedPhoto],
                       labels: [String: [String]], results: [String: CuratorVisionResult],
                       distance: (CuratorVisionResult, CuratorVisionResult) throws -> Float? = { try $0.distance(to: $1) }) -> MomentSelection {
        let selected = Set(selection.selected)
        let subjects: Set<String> = ["castle", "church", "ceiling", "corridor", "arch", "architecture",
            "building", "lake", "garden", "forest", "mountain", "beach", "waterfall"]
        let people: Set<String> = ["people", "person", "adult", "child", "baby", "portrait"]
        func clues(_ photo: IndexedPhoto) -> Set<String> { Set(labels[photo.id] ?? []) }
        func eligible(_ photo: IndexedPhoto) -> Bool {
            guard !photo.favorite, let result = results[photo.id],
                  case .available(0) = result.faces,
                  case .available(let aesthetic) = result.aesthetics, !aesthetic.utility,
                  aesthetic.score.isFinite, clues(photo).isDisjoint(with: people) else { return false }
            return !clues(photo).intersection(subjects).isEmpty
        }
        func score(_ photo: IndexedPhoto) -> Float {
            guard let result = results[photo.id], case .available(let value) = result.aesthetics,
                  value.score.isFinite else { return -.infinity }
            return value.score
        }
        let ranked = photos.filter { selected.contains($0.id) }.sorted {
            score($0) == score($1) ? $0.id < $1.id : score($0) > score($1)
        }
        var anchors: [IndexedPhoto] = [], alternatives = Set<String>(), comparisons = 0
        var output = selection
        for photo in ranked where eligible(photo) {
            var representative: IndexedPhoto?
            for anchor in anchors {
                guard comparisons < 2048 else { break }
                guard photo.similarityCategory == anchor.similarityCategory,
                      !clues(photo).intersection(clues(anchor)).intersection(subjects).isEmpty,
                      let meters = EvidenceGrouping.meters(photo, anchor), meters <= 150,
                      let lhs = results[photo.id], let rhs = results[anchor.id] else { continue }
                comparisons += 1
                guard let value = try? distance(lhs, rhs), value.isFinite, value >= 0,
                      value <= EvidenceGrouping.defaultCutoff else { continue }
                representative = anchor
                break
            }
            if let representative {
                alternatives.insert(photo.id)
                let time = representative.created?.formatted(date: .omitted, time: .standard) ?? "an unknown time"
                output.explanations[photo.id] = "Scenery alternative: a retained photo at \(time) represents similar scenery at a nearby recorded location with a higher aesthetics score (or stable tie-break). This is not a duplicate judgment. Choose Include to keep it."
            } else { anchors.append(photo) }
        }
        output = MomentSelection(selected: selection.selected.filter { !alternatives.contains($0) },
            pending: selection.pending, similar: selection.similar, explanations: output.explanations,
            alternatives: selection.alternatives + selection.selected.filter { alternatives.contains($0) },
            contextOnly: selection.contextOnly)
        return output
    }
}
