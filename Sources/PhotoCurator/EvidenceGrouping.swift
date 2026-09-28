import Foundation
import CoreLocation

struct SuggestedPhotoGroup: Identifiable {
    let id: String
    var photos: [IndexedPhoto]
    var explanations: [String: String]
    var inferredLocationSources: [String: String] = [:]
    var title: String = ""
}

struct GroupingProposal {
    var groups: [SuggestedPhotoGroup]
    let suspiciousTimes: Bool
}

/// Experimental, fixed-anchor visual grouping. No transitive location propagation.
enum EvidenceGrouping {
    // Conservative starting point from the exported test set, not a universal venue score.
    static let defaultCutoff: Float = 16
    static func validGPS(_ photo: IndexedPhoto) -> Bool {
        guard let lat = photo.latitude, let lon = photo.longitude else { return false }
        return lat.isFinite && lon.isFinite && (-90...90).contains(lat) && (-180...180).contains(lon)
    }

    static func meters(_ a: IndexedPhoto, _ b: IndexedPhoto) -> Double? {
        guard validGPS(a), validGPS(b) else { return nil }
        return CLLocation(latitude: a.latitude!, longitude: a.longitude!).distance(
            from: CLLocation(latitude: b.latitude!, longitude: b.longitude!))
    }

    static func sharedText(_ a: [PhotoTextLine], _ b: [PhotoTextLine]) -> String? {
        func clues(_ lines: [PhotoTextLine]) -> Set<String> {
            Set(lines.filter { $0.confidence.isFinite && $0.confidence >= 0.8 }
                .map { $0.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { (5...100).contains($0.count) && $0.contains(where: \.isLetter) })
        }
        return clues(a).intersection(clues(b)).sorted().first
    }

    static func propose(_ photos: [IndexedPhoto], text: [String: [PhotoTextLine]], cutoff: Float,
                        scenes: [String: SemanticSceneEvidence] = [:],
                        distance: (String, String) -> Float?) -> GroupingProposal {
        let ordered = photos.sorted {
            if $0.created == $1.created { return $0.id < $1.id }
            return ($0.created ?? .distantFuture) < ($1.created ?? .distantFuture)
        }
        var groups: [SuggestedPhotoGroup] = []
        func nearby(_ a: IndexedPhoto, _ b: IndexedPhoto) -> Bool {
            guard let x = a.created, let y = b.created else { return false }
            return abs(x.timeIntervalSince(y)) <= 30 * 60
        }
        func closeVisuals(_ a: IndexedPhoto, _ b: IndexedPhoto) -> Float? {
            let lhs = scenes[a.id] ?? SemanticSceneEvidence()
            let rhs = scenes[b.id] ?? SemanticSceneEvidence()
            guard !lhs.conflicts(with: rhs) else { return nil }
            let shared = !lhs.clues.intersection(rhs.clues).isEmpty
            let limit = cutoff + (shared ? min(2, max(0, cutoff) / 8) : 0)
            guard cutoff.isFinite, cutoff >= 0,
                  a.similarityCategory == b.similarityCategory,
                  let value = distance(a.id, b.id), value.isFinite, value >= 0, value <= limit else { return nil }
            return value
        }
        for photo in ordered {
            if Task.isCancelled { break }
            var best: (index: Int, distance: Float)?
            // Bound work and compare against fixed group anchors, not chains of neighbors.
            for index in groups.indices.suffix(32) {
                let anchor = groups[index].photos[0]
                guard nearby(photo, anchor), let value = closeVisuals(photo, anchor) else { continue }
                let conflict = groups[index].photos.contains {
                    if let separation = meters(photo, $0) { return separation > 1000 }
                    return false
                }
                guard !conflict else { continue }
                if best == nil || value < best!.distance { best = (index, value) }
            }
            if let best {
                let anchor = groups[best.index].photos[0]
                var reason = "Within 30 minutes of the group anchor; visual distance \(String(format: "%.2f", best.distance)). Venue/event not confirmed."
                let shared = (scenes[photo.id]?.clues ?? []).intersection(scenes[anchor.id]?.clues ?? [])
                if !shared.isEmpty {
                    reason += " Shared local scene clues: \(shared.sorted().joined(separator: ", ")). These are model hints, not identified places."
                }
                if let clue = sharedText(text[photo.id] ?? [], text[anchor.id] ?? []) {
                    reason += " Shared OCR: \(clue). Text supports review, not proof of a place."
                }
                groups[best.index].photos.append(photo)
                groups[best.index].explanations[photo.id] = reason
            } else {
                groups.append(SuggestedPhotoGroup(id: photo.id, photos: [photo], explanations: [photo.id:
                    "New group anchor: no eligible time/visual match without conflicting GPS. Missing analysis stays separate."]))
            }
        }
        let dated = ordered.compactMap(\.created)
        // Keep this guard independent of the slider: a looser cutoff cannot legitimize dates.
        let suspicious = dated.count >= 8 &&
            (dated.last!.timeIntervalSince(dated.first!) <= Double(dated.count * 3))
        if !suspicious {
            for index in groups.indices {
                let anchors = groups[index].photos.filter(validGPS)
                for photo in groups[index].photos where !validGPS(photo) {
                    let matches = anchors.filter {
                        guard nearby(photo, $0), let value = closeVisuals(photo, $0) else { return false }
                        // Loosening the preview must not loosen geographic inference.
                        return value <= defaultCutoff
                    }
                    guard let anchor = matches.first else { continue }
                    // All recorded locations in the group must agree before inference.
                    guard anchors.allSatisfy({ (meters(anchor, $0) ?? .infinity) <= 1000 }) else { continue }
                    groups[index].inferredLocationSources[photo.id] = anchor.id
                }
            }
        }
        return GroupingProposal(groups: groups, suspiciousTimes: suspicious)
    }
}
