import Foundation

/// Repeated visual scenes in a compressed/import-like timeline, not verified venues.
enum SceneMomentGrouping {
    static func sharedRecordedLocation(_ photos: [IndexedPhoto]) -> Bool {
        let located = photos.filter(EvidenceGrouping.validGPS)
        guard located.count >= 2, let anchor = located.first else { return false }
        return located.allSatisfy { (EvidenceGrouping.meters(anchor, $0) ?? .infinity) <= 150 }
    }
    static func compressedTimes(_ photos: [IndexedPhoto]) -> Bool {
        let dates = photos.compactMap(\.created).sorted()
        return dates.count == photos.count && dates.count >= 8
            && dates.last!.timeIntervalSince(dates.first!) <= Double(dates.count * 3)
    }

    static func groups(_ photos: [IndexedPhoto], labels: [String: [String]],
                       distance: (String, String) -> Float?) throws -> [[IndexedPhoto]] {
        // A shared recorded location is stronger than visual changes within that venue.
        if sharedRecordedLocation(photos) { return [] }
        let distinctive: Set<String> = ["castle", "beach", "forest", "mountain", "waterfall",
            "desert", "snow", "boat", "church", "aquarium", "playground", "stadium"]
        var pairs: [String: [String: Float]] = [:]
        var comparisons = 0
        var exhausted = false
        func separation(_ a: IndexedPhoto, _ b: IndexedPhoto) -> Float? {
            if let cached = pairs[a.id]?[b.id] ?? pairs[b.id]?[a.id] { return cached.isFinite ? cached : nil }
            guard comparisons < 8192 else { exhausted = true; return nil }
            comparisons += 1
            let value = distance(a.id, b.id)
            let valid = value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            pairs[a.id, default: [:]][b.id] = valid ?? .nan
            return valid
        }
        func compatible(_ a: IndexedPhoto, _ b: IndexedPhoto) -> Bool {
            if let meters = EvidenceGrouping.meters(a, b), meters > 1000 { return false }
            let lhs = Set(labels[a.id] ?? []).intersection(distinctive)
            let rhs = Set(labels[b.id] ?? []).intersection(distinctive)
            return lhs.isEmpty || rhs.isEmpty || !lhs.isDisjoint(with: rhs)
        }
        var candidates: [[IndexedPhoto]] = []
        // Stable asset ordering deliberately avoids treating imported seconds as an itinerary.
        for photo in photos.sorted(by: { $0.id < $1.id }) {
            try Task.checkCancellation()
            var best: (index: Int, maximum: Float)?
            for index in candidates.indices {
                try Task.checkCancellation()
                // A fixed reference allows varied views without neighbor-to-neighbor chains.
                guard let anchor = candidates[index].first,
                      let value = separation(photo, anchor),
                      candidates[index].allSatisfy({ compatible(photo, $0) }) else { continue }
                let shared = Set(labels[photo.id] ?? []).intersection(labels[anchor.id] ?? []).intersection(distinctive)
                let limit = EvidenceGrouping.defaultCutoff + (shared.isEmpty ? 0 : 2)
                guard value <= limit else { continue }
                if best == nil || value < best!.maximum { best = (index, value) }
            }
            if let best { candidates[best.index].append(photo) }
            else { candidates.append([photo]) }
            // Never publish a partially searched split just because its work budget ran out.
            if exhausted { return [] }
        }
        let repeated = candidates.filter { $0.count >= 3 }
        // A uniformly similar burst is one plausible scene, not an unresolved itinerary.
        if repeated.count == 1, repeated[0].count == photos.count { return repeated }
        guard repeated.count >= 2,
              repeated.reduce(0, { $0 + $1.count }) * 4 >= photos.count else { return [] }
        return repeated
    }
}
