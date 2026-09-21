import Foundation
import Vision
import ImageIO

enum VisionSignal<Value: Codable & Equatable>: Codable, Equatable {
    case available(Value)
    case unavailable
    case failed
}

struct AestheticSignal: Codable, Equatable {
    let score: Float
    let utility: Bool
}

struct CuratorVisionResult: Codable, Equatable {
    let version: String
    let faces: VisionSignal<Int>
    let aesthetics: VisionSignal<AestheticSignal>
    let featurePrint: VisionSignal<Data>

    // A thumbnail is not a privacy clearance, even when Vision detects no faces.
    var permitsResearchUpload: Bool { false }

    func distance(to other: Self) throws -> Float? {
        guard version == other.version,
              case .available(let lhs) = featurePrint,
              case .available(let rhs) = other.featurePrint else { return nil }
        guard let a = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: lhs),
              let b = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: rhs) else { return nil }
        var distance: Float = 0
        try a.computeDistance(&distance, to: b)
        return distance.isFinite ? distance : nil
    }
}

/// Serialized, off-main-actor analysis. Input must be the orientation-corrected thumbnail.
actor CuratorVisionAnalyzer {
    static var version: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        // Include OS model changes as well as explicitly pinned Vision request revisions.
        return "vision1-face3-print1-aesthetic1-os\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    func analyze(_ image: CGImage) throws -> CuratorVisionResult {
        try Task.checkCancellation()
        guard image.width <= 1024, image.height <= 1024 else {
            throw NSError(domain: "PhotoRelay.Vision", code: 1, userInfo: [NSLocalizedDescriptionKey: "Analysis requires a bounded thumbnail."])
        }
        let faces: VisionSignal<Int> = try signal {
            guard VNDetectFaceRectanglesRequest.supportedRevisions.contains(3) else { return .unavailable }
            let request = VNDetectFaceRectanglesRequest()
            request.revision = 3
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
            guard let results = request.results else { return .failed }
            return .available(results.count)
        }
        let aesthetics: VisionSignal<AestheticSignal> = try signal {
            guard #available(macOS 15.0, *) else { return .unavailable }
            guard VNCalculateImageAestheticsScoresRequest.supportedRevisions.contains(1) else { return .unavailable }
            let request = VNCalculateImageAestheticsScoresRequest()
            request.revision = 1
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
            guard let result = request.results?.first, result.overallScore.isFinite else { return .failed }
            return .available(AestheticSignal(score: result.overallScore, utility: result.isUtility))
        }
        let feature: VisionSignal<Data> = try signal {
            guard VNGenerateImageFeaturePrintRequest.supportedRevisions.contains(1) else { return .unavailable }
            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = 1
            request.imageCropAndScaleOption = .scaleFit
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
            guard let result = request.results?.first else { return .failed }
            return .available(try NSKeyedArchiver.archivedData(withRootObject: result, requiringSecureCoding: true))
        }
        try Task.checkCancellation()
        return CuratorVisionResult(version: Self.version, faces: faces, aesthetics: aesthetics, featurePrint: feature)
    }

    private func signal<T>(_ operation: () throws -> VisionSignal<T>) throws -> VisionSignal<T> {
        try Task.checkCancellation()
        do { return try operation() }
        catch is CancellationError { throw CancellationError() }
        catch { return .failed }
    }
}
