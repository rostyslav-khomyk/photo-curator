import Vision
import Foundation

actor NarrativeVisualContext {
    static let version = "vision-classify2-context2"
    func labels(_ image: CGImage) throws -> [String] {
        try Task.checkCancellation()
        guard image.width <= 1024, image.height <= 1024 else { throw NarrativeFailure.invalidMetadata }
        let request = VNClassifyImageRequest()
        request.revision = 2
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        try Task.checkCancellation()
        let results = request.results ?? []
        return Self.retainedLabels(Dictionary(results.map { ($0.identifier, $0.confidence) }, uniquingKeysWith: max))
    }

    static func retainedLabels(_ scores: [String: Float]) -> [String] {
        let ordered = scores.keys.filter { scores[$0]!.isFinite }.sorted {
            scores[$0] == scores[$1] ? $0 < $1 : scores[$0]! > scores[$1]!
        }
        let scenes = SemanticSceneEvidence.from(scores).clues
        let general = Array(ordered.filter { scores[$0]! >= 0.5 }.prefix(4))
        // Keep confident scene clues even when generic people/sky labels rank above them.
        let specific = ordered.filter { scenes.contains($0) }
        var seen = Set<String>()
        return Array((general + specific).filter { seen.insert($0).inserted }.prefix(8))
            .map { $0.replacingOccurrences(of: "_", with: " ") }
    }
}
