import Foundation
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

// Read-only capability probe. Does not load photos, run inference, or download models.
print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("Vision face revisions: \(Array(VNDetectFaceRectanglesRequest.supportedRevisions))")
print("Vision similarity revisions: \(Array(VNGenerateImageFeaturePrintRequest.supportedRevisions))")
if #available(macOS 15.0, *) {
    print("Vision aesthetics revisions: \(Array(VNCalculateImageAestheticsScoresRequest.supportedRevisions))")
} else {
    print("Vision aesthetics: unavailable; use metadata/diversity fallback")
}
#if canImport(FoundationModels)
if #available(macOS 26.0, *) {
    print("Local language model: \(SystemLanguageModel.default.availability)")
} else {
    print("Local language model: unavailable; use deterministic titles")
}
#else
print("Local language model: not supported by this SDK")
#endif
