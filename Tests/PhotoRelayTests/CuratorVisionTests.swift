import XCTest
import CoreGraphics
@testable import PhotoRelay

final class CuratorVisionTests: XCTestCase {
    func testSyntheticImageInferenceAndFeatureArchive() async throws {
        let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        let result = try await CuratorVisionAnalyzer().analyze(context.makeImage()!)
        XCTAssertEqual(result.faces, .available(0))
        guard case .available = result.featurePrint else { XCTFail("Feature extraction failed"); return }
        XCTAssertEqual(try XCTUnwrap(result.distance(to: result)), 0, accuracy: 0.0001)
        XCTAssertFalse(result.permitsResearchUpload)
        if #available(macOS 15.0, *) {
            guard case .available(let value) = result.aesthetics else { XCTFail("Aesthetics request failed"); return }
            XCTAssertTrue((-1...1).contains(value.score))
        }
    }

    func testFailureAndAbsenceNeverClearPrivacyGate() throws {
        for faces in [VisionSignal<Int>.available(0), .available(2), .failed, .unavailable] {
            let result = CuratorVisionResult(version: "test", faces: faces, aesthetics: .unavailable, featurePrint: .failed)
            XCTAssertFalse(result.permitsResearchUpload)
            XCTAssertEqual(try JSONDecoder().decode(CuratorVisionResult.self, from: JSONEncoder().encode(result)), result)
        }
    }

    func testIncompatibleVersionsAreNotCompared() throws {
        let a = CuratorVisionResult(version: "1", faces: .failed, aesthetics: .failed, featurePrint: .available(Data()))
        let b = CuratorVisionResult(version: "2", faces: .failed, aesthetics: .failed, featurePrint: .available(Data()))
        XCTAssertNil(try a.distance(to: b))
    }

    func testResultRoundTripsThroughQueue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CuratorStore(url: directory.appendingPathComponent("test.sqlite3"))
        let result = CuratorVisionResult(version: CuratorVisionAnalyzer.version, faces: .available(1), aesthetics: .available(.init(score: -0.2, utility: true)), featurePrint: .unavailable)
        try store.enqueueAnalysis(asset: "fixture", revision: "1", analyzer: result.version)
        let job = try XCTUnwrap(store.claimAnalysis())
        XCTAssertTrue(try store.finishAnalysis(job, result: JSONEncoder().encode(result)))
        let data = try XCTUnwrap(store.analysisResult(asset: "fixture", revision: "1", analyzer: result.version))
        XCTAssertEqual(try JSONDecoder().decode(CuratorVisionResult.self, from: data), result)
    }

    func testOversizedInputRejectedBeforeInference() async throws {
        let image = CGContext(data: nil, width: 1025, height: 1, bitsPerComponent: 8, bytesPerRow: 4100,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        do { _ = try await CuratorVisionAnalyzer().analyze(image); XCTFail("Expected size rejection") }
        catch { XCTAssertEqual((error as NSError).domain, "PhotoRelay.Vision") }
    }
}
