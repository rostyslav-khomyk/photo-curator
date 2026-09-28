import Foundation

struct CuratorEvidence<Value: Codable & Equatable>: Codable, Equatable {
    let value: Value?
    let confidence: Double
    let source: String
    let version: String
    var available: Bool { value != nil }
}

struct BoundaryObservation: Codable, Equatable {
    let earlierID: String
    let laterID: String
    let logTimeGap: Double
    let geoMeters: CuratorEvidence<Double>
    let visualPercentile: CuratorEvidence<Double>
    let ocrOverlap: CuratorEvidence<Double>
    let placeConflict: Bool
}

struct BoundaryEstimate: Codable, Equatable {
    let probability: Double
    let contributions: [String: Double]
    let modelVersion: String
}

enum CuratorCalibration {
    static let version = "math-v1"

    static func percentile(_ value: Float?, cutoffs: [Float]) -> CuratorEvidence<Double> {
        guard let value, value.isFinite, value >= 0, !cutoffs.isEmpty else {
            return .init(value: nil, confidence: 0, source: "Vision feature print", version: version)
        }
        let ordered = cutoffs.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !ordered.isEmpty else { return .init(value: nil, confidence: 0, source: "Vision feature print", version: version) }
        let rank = ordered.partitioningIndex { $0 >= value }
        return .init(value: Double(rank) / Double(ordered.count), confidence: min(1, Double(ordered.count) / 50), source: "empirical Vision distance", version: version)
    }
}

private extension Array {
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high { let mid = (low + high) / 2; if predicate(self[mid]) { high = mid } else { low = mid + 1 } }
        return low
    }
}

enum ProbabilisticBoundaryModel {
    static let version = "boundary-v1"
    static func estimate(_ observation: BoundaryObservation) -> BoundaryEstimate {
        var c: [String: Double] = ["time": min(3.2, max(-2.0, observation.logTimeGap - log1p(120))) * 0.72]
        if let geo = observation.geoMeters.value {
            c["geo"] = min(3, max(-1, log1p(geo) - log1p(150))) * 0.65 * observation.geoMeters.confidence
        }
        if let visual = observation.visualPercentile.value {
            c["visual"] = (visual - 0.5) * 2.2 * observation.visualPercentile.confidence
        }
        if let overlap = observation.ocrOverlap.value {
            c["ocr"] = -1.4 * overlap * observation.ocrOverlap.confidence
        }
        if observation.placeConflict { c["placeConflict"] = 3.0 }
        let logit = -1.1 + c.values.reduce(0, +)
        return .init(probability: 1 / (1 + exp(-logit)), contributions: c, modelVersion: version)
    }

    /// Two-sided duration support removes isolated spikes without erasing strong boundaries.
    static func smooth(_ estimates: [BoundaryEstimate]) -> [BoundaryEstimate] {
        estimates.indices.map { i in
            let p = estimates[i].probability
            guard p < 0.9 else { return estimates[i] }
            let neighbors = [i - 1, i + 1].filter { estimates.indices.contains($0) }.map { estimates[$0].probability }
            guard !neighbors.isEmpty else { return estimates[i] }
            let adjusted = 0.75 * p + 0.25 * (neighbors.reduce(0, +) / Double(neighbors.count))
            return .init(probability: adjusted, contributions: estimates[i].contributions, modelVersion: version)
        }
    }
}

enum SubmodularHighlightSelector {
    struct Candidate {
        let id: String
        let quality: Double
        let protected: Bool
        let roles: Set<String>
    }

    static func select(_ candidates: [Candidate], minimum: Int = 1, maximum: Int, minimumGain: Double = 0.08,
                       similarity: (String, String) -> Double?) -> [String] {
        guard maximum > 0 else { return [] }
        // A user decision is not traded against an automatic cardinality budget.
        var chosen = candidates.filter(\.protected).map(\.id)
        let effectiveMaximum = max(maximum, chosen.count)
        var remaining = candidates.filter { !chosen.contains($0.id) }
        var coveredRoles = Set(candidates.filter { chosen.contains($0.id) }.flatMap(\.roles))
        while chosen.count < effectiveMaximum, !remaining.isEmpty {
            var scored: [(candidate: Candidate, gain: Double)] = []
            for item in remaining {
                let coverage = candidates.reduce(0.0) { sum, target in
                    let before = chosen.compactMap { similarity($0, target.id) }.max() ?? 0
                    let after = max(before, similarity(item.id, target.id) ?? (item.id == target.id ? 1 : 0))
                    return sum + max(0, after - before)
                } / Double(max(1, candidates.count))
                let roleGain = Double(item.roles.subtracting(coveredRoles).count) * 0.12
                let normalizedQuality = Swift.max(-1.0, Swift.min(1.0, item.quality))
                let gain = normalizedQuality * 0.35 + coverage * 0.53 + roleGain
                scored.append((item, gain))
            }
            scored.sort { $0.gain == $1.gain ? $0.candidate.id < $1.candidate.id : $0.gain > $1.gain }
            guard let best = scored.first, best.gain >= minimumGain || chosen.count < minimum else { break }
            chosen.append(best.candidate.id); coveredRoles.formUnion(best.candidate.roles)
            remaining.removeAll { $0.id == best.candidate.id }
        }
        return chosen
    }
}

enum NarrativeInformationScorer {
    static func salience(support: Int, inspected: Int, documentFrequency: Int, corpusSize: Int, confidence: Double) -> Double {
        guard support >= 2, inspected > 0, corpusSize > 0, confidence > 0 else { return 0 }
        return (Double(support) / Double(inspected)) * log((Double(corpusSize) + 1) / (Double(documentFrequency) + 1)) * min(1, confidence)
    }

    static func score(grounding: Double, specificity: Double, unsupportedClaims: Int,
                      metadataDuplication: Bool, similarityToRecent: Double) -> Double {
        grounding * 0.5 + specificity * 0.3 - Double(unsupportedClaims) - (metadataDuplication ? 0.4 : 0)
            - max(0, min(1, similarityToRecent)) * 0.25
    }
}
