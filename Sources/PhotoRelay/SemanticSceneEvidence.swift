import Foundation
import Vision

struct SemanticSceneEvidence {
    var clues: Set<String> = []
    var indoor = false
    var outdoor = false

    static func from(_ labels: [String: Float]) -> Self {
        // Broad labels and people's appearance must not stand in for a venue.
        let distinctive: Set<String> = ["castle", "beach", "forest", "mountain", "waterfall",
            "desert", "snow", "boat", "church", "aquarium", "playground", "stadium"]
        let clues = Set(labels.filter { distinctive.contains($0.key) && $0.value.isFinite && $0.value >= 0.7 }.map(\.key))
        return Self(clues: clues, indoor: (labels["interior_room"] ?? 0) >= 0.9,
                    outdoor: (labels["outdoor"] ?? 0) >= 0.9)
    }

    func conflicts(with other: Self) -> Bool {
        (indoor && !outdoor && other.outdoor && !other.indoor) ||
        (outdoor && !indoor && other.indoor && !other.outdoor)
    }
}
