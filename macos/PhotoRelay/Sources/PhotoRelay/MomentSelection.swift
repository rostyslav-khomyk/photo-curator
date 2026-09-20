import Foundation
import CoreLocation
import Vision

enum CuratorLocationCoverage {
    static func location(_ photo: IndexedPhoto) -> CLLocation? {
        guard let lat = photo.latitude, let lon = photo.longitude,
              lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocation(latitude: lat, longitude: lon)
    }

    static func groups(_ photos: [IndexedPhoto]) -> [[IndexedPhoto]] {
        var groups: [[IndexedPhoto]] = []
        var unknown: [IndexedPhoto] = []
        for photo in photos.sorted(by: { $0.id < $1.id }) {
            guard let location = location(photo) else { unknown.append(photo); continue }
            // Anchor comparison avoids a chain of neighboring photos joining distant stops.
            if let index = groups.firstIndex(where: {
                guard let anchor = $0.first.flatMap(Self.location) else { return false }
                return location.distance(from: anchor) <= 1000
            }) {
                groups[index].append(photo)
            } else { groups.append([photo]) }
        }
        if !unknown.isEmpty { groups.append(unknown) }
        return groups
    }
}

struct MomentSelection: Codable {
    let selected: [String]
    let pending: [String]
    let similar: [String]
    var explanations: [String: String] = [:]
    var alternatives: [String] = []
    var contextOnly: [String]? = nil
}

enum BalancedMomentSelector {
    /// Temporal coverage heuristic, not semantic storytelling or an Apple Memories model.
    static func select(_ selection: MomentSelection, photos: [IndexedPhoto], results: [String: CuratorVisionResult]) -> MomentSelection {
        let eligible = Set(selection.selected)
        var output = selection
        var buckets: [String: [IndexedPhoto]] = [:]
        var retained = Set<String>()
        for photo in photos where eligible.contains(photo.id) {
            guard let date = photo.created else { retained.insert(photo.id); continue }
            let bucket = "\(Int(floor(date.timeIntervalSince1970 / 1800)))-\(photo.similarityCategory?.rawValue ?? "unknown")"
            buckets[bucket, default: []].append(photo)
        }
        func score(_ photo: IndexedPhoto) -> Float? {
            guard let result = results[photo.id], case .available(let value) = result.aesthetics,
                  value.score.isFinite else { return nil }
            return value.score - (value.utility ? 0.2 : 0)
        }
        for members in buckets.values.flatMap({ CuratorLocationCoverage.groups($0) }) {
            let favorites = members.filter(\.favorite)
            favorites.forEach { retained.insert($0.id) }
            let ranked = members.filter { !$0.favorite }.sorted {
                let a = score($0) ?? -.infinity, b = score($1) ?? -.infinity
                return a == b ? $0.id < $1.id : a > b
            }
            // Missing quality data is not evidence to set a photo aside.
            ranked.filter { score($0) == nil }.forEach { retained.insert($0.id) }
            if favorites.isEmpty, let best = ranked.first(where: { score($0) != nil }) {
                retained.insert(best.id)
                let context = CuratorLocationCoverage.location(best) == nil ? "unknown-location subgroup" : "local GPS subgroup (within 1 km of its anchor)"
                output.explanations[best.id] = "Balanced: highest available adjusted aesthetics score in this 30-minute, same-type \(context). This is a coverage heuristic, not a judgment of personal importance."
            }
        }
        output.alternatives = selection.selected.filter { !retained.contains($0) }
        for id in output.alternatives {
            output.explanations[id] = "Balanced: another shot represents this 30-minute, same-type location subgroup. Unknown locations are grouped separately. This photo is an alternative, not a duplicate or a rejected photo. Choose Include to keep it."
        }
        return MomentSelection(selected: selection.selected.filter { retained.contains($0) }, pending: selection.pending,
                               similar: selection.similar, explanations: output.explanations, alternatives: output.alternatives,
                               contextOnly: selection.contextOnly)
    }
}

enum RepresentativeSelector {
    /// Bounded target budget for curated moments.
    static func targetBudget(for totalCount: Int) -> Int {
        if totalCount <= 20 { return max(1, totalCount) }
        if totalCount <= 60 { return 20 }
        if totalCount <= 200 { return 25 }
        return 35
    }

    static func minimumBudget(for totalCount: Int) -> Int {
        if totalCount <= 20 { return max(1, totalCount) }
        if totalCount <= 60 { return 12 }
        if totalCount <= 200 { return 15 }
        return 20
    }

    static func select(_ selection: MomentSelection, photos: [IndexedPhoto], results: [String: CuratorVisionResult]) -> MomentSelection {
        let budget = targetBudget(for: photos.count)
        guard selection.selected.count > budget else { return selection }

        let photosByID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let selectedPhotos = selection.selected.compactMap { photosByID[$0] }
        guard selectedPhotos.count > budget else { return selection }

        func score(_ photo: IndexedPhoto) -> Float {
            guard let result = results[photo.id], case .available(let value) = result.aesthetics,
                  value.score.isFinite else { return 0 }
            return value.score - (value.utility ? 0.2 : 0)
        }

        func roles(_ photo: IndexedPhoto) -> Set<String> {
            var value: Set<String> = []
            if case .available(let count) = results[photo.id]?.faces, count > 0 { value.insert(count > 2 ? "group" : "portrait") }
            if case .available(let aesthetic) = results[photo.id]?.aesthetics, aesthetic.utility { value.insert("context") }
            if let date = photo.created { value.insert("time-\(Int(date.timeIntervalSince1970 / 1800))") }
            if let location = CuratorLocationCoverage.location(photo) {
                value.insert("place-\(Int(location.coordinate.latitude * 100))-\(Int(location.coordinate.longitude * 100))")
            }
            return value
        }

        let candidateDates = selectedPhotos.compactMap(\.created)
        let candidateSpan = max(60, (candidateDates.max() ?? .distantPast).timeIntervalSince(candidateDates.min() ?? .distantPast))
        let earliest = selectedPhotos.min { ($0.created ?? .distantFuture) < ($1.created ?? .distantFuture) }?.id
        let latest = selectedPhotos.max { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }?.id
        let candidates = selectedPhotos.map {
            let endpointBoost: Double = ($0.id == earliest || $0.id == latest) ? 1 : 0
            return SubmodularHighlightSelector.Candidate(id: $0.id, quality: Double(score($0)) + endpointBoost,
                protected: $0.favorite, roles: roles($0))
        }
        // Feature prints are archived for persistence. Decode each candidate once rather
        // than once per pair in the submodular selector's nested scoring loops.
        let featurePrints: [String: VNFeaturePrintObservation] = Dictionary(
            uniqueKeysWithValues: selection.selected.compactMap { id in
                guard case .available(let data) = results[id]?.featurePrint,
                      let observation = try? NSKeyedUnarchiver.unarchivedObject(
                        ofClass: VNFeaturePrintObservation.self,
                        from: data
                      ) else { return nil }
                return (id, observation)
            }
        )
        let chosen = Set(SubmodularHighlightSelector.select(candidates,
            minimum: minimumBudget(for: photos.count), maximum: budget) { lhs, rhs in
                if lhs == rhs { return 1 }
                if let a = featurePrints[lhs], let b = featurePrints[rhs] {
                    var distance: Float = 0
                    if (try? a.computeDistance(&distance, to: b)) != nil,
                       distance.isFinite, distance >= 0 {
                        return exp(-Double(distance) / Double(max(EvidenceGrouping.defaultCutoff, 0.000_001)))
                    }
                }
                guard let a = photosByID[lhs]?.created, let b = photosByID[rhs]?.created else { return nil }
                return exp(-abs(a.timeIntervalSince(b)) / (candidateSpan / 6))
            })
        if !chosen.isEmpty {
            var output = selection
            let alternatives = selection.selected.filter { !chosen.contains($0) }
            for id in alternatives {
                output.explanations[id] = "Curated alternative: the selected set already covers this part of the Moment. Choose Include or Favorite to protect it."
            }
            return MomentSelection(selected: selection.selected.filter { chosen.contains($0) }, pending: selection.pending,
                similar: selection.similar, explanations: output.explanations,
                alternatives: selection.alternatives + alternatives, contextOnly: selection.contextOnly)
        }

        let sorted = selectedPhotos.sorted {
            if $0.created != $1.created {
                return ($0.created ?? .distantPast) < ($1.created ?? .distantPast)
            }
            return $0.id < $1.id
        }

        guard let firstDate = sorted.first?.created, let lastDate = sorted.last?.created,
              lastDate.timeIntervalSince(firstDate) > 60 else {
            let ranked = sorted.sorted {
                if $0.favorite != $1.favorite { return $0.favorite }
                let s0 = score($0), s1 = score($1)
                return s0 == s1 ? $0.id < $1.id : s0 > s1
            }
            let chosen = Set(ranked.prefix(budget).map(\.id))
            var output = selection
            let newlyAlternative = selection.selected.filter { !chosen.contains($0) }
            for id in newlyAlternative {
                let isFav = photosByID[id]?.favorite ?? false
                output.explanations[id] = isFav
                    ? "Favorited alternative: retained as an alternative to keep the display shortlist varied across this large visit. Choose Include to display it."
                    : "Curated alternative: another photo represents this visit in the balanced display shortlist. Choose Include to keep it."
            }
            return MomentSelection(
                selected: selection.selected.filter { chosen.contains($0) },
                pending: selection.pending,
                similar: selection.similar,
                explanations: output.explanations,
                alternatives: selection.alternatives + newlyAlternative,
                contextOnly: selection.contextOnly
            )
        }

        let totalSpan = lastDate.timeIntervalSince(firstDate)
        let intervalWidth = totalSpan / Double(budget)
        var intervals: [[IndexedPhoto]] = Array(repeating: [], count: budget)

        for photo in sorted {
            guard let date = photo.created else { continue }
            let offset = date.timeIntervalSince(firstDate)
            let idx = min(budget - 1, max(0, Int(floor(offset / intervalWidth))))
            intervals[idx].append(photo)
        }

        var chosenIDs = Set<String>()

        for interval in intervals where !interval.isEmpty {
            let sortedInterval = interval.sorted {
                if $0.favorite != $1.favorite { return $0.favorite }
                let s0 = score($0), s1 = score($1)
                return s0 == s1 ? $0.id < $1.id : s0 > s1
            }
            if let best = sortedInterval.first {
                chosenIDs.insert(best.id)
            }
        }

        if chosenIDs.count < budget {
            let remaining = sorted.filter { !chosenIDs.contains($0.id) }.sorted {
                if $0.favorite != $1.favorite { return $0.favorite }
                let s0 = score($0), s1 = score($1)
                return s0 == s1 ? $0.id < $1.id : s0 > s1
            }
            for photo in remaining.prefix(budget - chosenIDs.count) {
                chosenIDs.insert(photo.id)
            }
        }

        if chosenIDs.count > budget {
            let rankedChosen = sorted.filter { chosenIDs.contains($0.id) }.sorted {
                if $0.favorite != $1.favorite { return $0.favorite }
                let s0 = score($0), s1 = score($1)
                return s0 == s1 ? $0.id < $1.id : s0 > s1
            }
            chosenIDs = Set(rankedChosen.prefix(budget).map(\.id))
        }

        var output = selection
        let newlyAlternative = selection.selected.filter { !chosenIDs.contains($0) }
        for id in newlyAlternative {
            let isFav = photosByID[id]?.favorite ?? false
            output.explanations[id] = isFav
                ? "Favorited alternative: retained as an alternative to keep the display shortlist varied across this large visit. Choose Include to display it."
                : "Curated alternative: another shot represents this part of the visit in the balanced display shortlist. Choose Include to keep it."
        }

        return MomentSelection(
            selected: selection.selected.filter { chosenIDs.contains($0) },
            pending: selection.pending,
            similar: selection.similar,
            explanations: output.explanations,
            alternatives: selection.alternatives + newlyAlternative,
            contextOnly: selection.contextOnly
        )
    }
}

enum MomentSelector {
    /// Conservative first pass, not a universal similarity threshold or final ranking.
    static func select(_ photos: [IndexedPhoto], results: [String: CuratorVisionResult], threshold: Float = 0.01,
                       thresholds: [SimilarityCategory: Float] = [:],
                       distance: (CuratorVisionResult, CuratorVisionResult) throws -> Float? = { try $0.distance(to: $1) }) -> MomentSelection {
        func score(_ photo: IndexedPhoto) -> Float {
            guard let result = results[photo.id], case .available(let value) = result.aesthetics else { return 0 }
            return value.score - (value.utility ? 0.2 : 0)
        }
        let ranked = photos.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            if score($0) != score($1) { return score($0) > score($1) }
            return $0.id < $1.id
        }
        var selected: [IndexedPhoto] = [], pending: [String] = [], similar: [String] = []
        var explanations: [String: String] = [:]
        for photo in ranked {
            guard let result = results[photo.id] else {
                pending.append(photo.id)
                explanations[photo.id] = "No current analysis is cached yet. This is not a rejection."
                continue
            }
            let repetitive = !photo.favorite && selected.filter { other in
                guard photo.similarityCategory == other.similarityCategory else { return false }
                if let a = CuratorLocationCoverage.location(photo), let b = CuratorLocationCoverage.location(other),
                   a.distance(from: b) > 1000 { return false }
                guard let date = photo.created, let otherDate = other.created else { return false }
                return abs(date.timeIntervalSince(otherDate)) <= 60
            }.sorted { abs($0.created!.timeIntervalSince(photo.created!)) < abs($1.created!.timeIntervalSince(photo.created!)) }.prefix(32).contains { other in
                guard let date = photo.created, let otherDate = other.created,
                      abs(date.timeIntervalSince(otherDate)) <= 60,
                      let otherResult = results[other.id],
                      let value = try? distance(result, otherResult) else { return false }
                // Near-identical only until a real review set can calibrate thresholds.
                let cutoff = photo.similarityCategory.flatMap { thresholds[$0] } ?? threshold
                let matches = value.isFinite && value >= 0 && cutoff.isFinite && value <= max(0, cutoff)
                if matches {
                    let time = other.created?.formatted(date: .omitted, time: .standard) ?? "unknown time"
                    explanations[photo.id] = String(format: "Similar to a retained shot at %@: distance %.3f, cutoff %.3f. Same type, within 60 seconds. The representative ranked earlier by Favorite, aesthetics, or stable tie-break.", time, value, cutoff)
                }
                return matches
            }
            if repetitive { similar.append(photo.id) }
            else {
                selected.append(photo)
                explanations[photo.id] = photo.favorite
                    ? "Your Favorite is protected from automatic similarity suppression."
                    : "No qualifying similar retained shot was found among the compared neighbors. Retained does not necessarily mean a best photo."
                if case .available(let aesthetic) = result.aesthetics {
                    explanations[photo.id, default: ""] += String(format: " Aesthetics score: %.3f%@.", aesthetic.score, aesthetic.utility ? " (utility-image adjustment applied)" : "")
                }
            }
        }
        return MomentSelection(selected: selected.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }.map(\.id),
                               pending: pending, similar: similar, explanations: explanations)
    }
}
