import XCTest
import CoreGraphics
@testable import PhotoRelay

@MainActor
private final class FakeThumbnailProvider: CuratorThumbnailProvider {
    var callback: (@MainActor @Sendable (ThumbnailEvent) -> Void)?
    var immediate: ThumbnailEvent?
    var cancellations: [Int32] = []
    var requests = 0
    var requestedEdge = 0
    func request(
        assetID: String,
        edge: Int,
        completion: @MainActor @escaping @Sendable (ThumbnailEvent) -> Void
    ) -> Int32 {
        requests += 1
        requestedEdge = edge
        callback = completion
        if let immediate { completion(immediate) }
        return Int32(requests)
    }
    func cancel(_ requestID: Int32) { cancellations.append(requestID) }
}

final class ThumbnailLoaderTests: XCTestCase {
    @MainActor func testLargerPreviewClampsRequestWithoutUpscaling() async throws {
        let provider = FakeThumbnailProvider()
        provider.immediate = .image(image(width: 2048, height: 1024), degraded: false)
        let loader = CuratorThumbnailLoader(provider: provider)
        let result = try await loader.load(assetID: "preview", edge: 10000)
        XCTAssertEqual(provider.requestedEdge, 4096)
        XCTAssertEqual(result.width, 2048)
        XCTAssertEqual(result.height, 1024)
    }
    private func image(width: Int = 8, height: Int = 8) -> CGImage {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    @MainActor func testSynchronousCallbackAndSizeBound() async throws {
        let provider = FakeThumbnailProvider()
        provider.immediate = .image(image(width: 2048, height: 1024), degraded: false)
        let loader = CuratorThumbnailLoader(provider: provider)
        let result = try await loader.load(assetID: "synthetic")
        XCTAssertEqual(result.width, 1024)
        XCTAssertEqual(result.height, 512)
        XCTAssertEqual(provider.cancellations, [1])
        provider.callback?(.failure(.unavailable)) // Duplicate callback must be ignored.
    }

    @MainActor func testTimeoutCancelsAndLoaderCanBeReused() async throws {
        let provider = FakeThumbnailProvider()
        let loader = CuratorThumbnailLoader(provider: provider)
        do { _ = try await loader.load(assetID: "a", timeout: 0.01); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? ThumbnailFailure, .timedOut) }
        XCTAssertEqual(provider.cancellations, [1])
        let stale = provider.callback
        provider.immediate = .image(image(), degraded: false)
        _ = try await loader.load(assetID: "b")
        stale?(.failure(.missing))
    }

    @MainActor func testDegradedResultDoesNotCountAsAnalysisImage() async throws {
        let provider = FakeThumbnailProvider()
        provider.immediate = .image(image(), degraded: true)
        let loader = CuratorThumbnailLoader(provider: provider)
        do { _ = try await loader.load(assetID: "a", timeout: 0.01); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? ThumbnailFailure, .timedOut) }
    }

    @MainActor func testTaskCancellationAndBusyLimit() async throws {
        let provider = FakeThumbnailProvider()
        let loader = CuratorThumbnailLoader(provider: provider)
        let pending = Task { try await loader.load(assetID: "a") }
        while provider.requests == 0 { await Task.yield() }
        do { _ = try await loader.load(assetID: "b"); XCTFail("Expected busy") }
        catch { XCTAssertEqual(error as? ThumbnailFailure, .busy) }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? ThumbnailFailure, .cancelled) }
        XCTAssertEqual(provider.cancellations, [1])
        XCTAssertEqual(provider.requests, 1)
    }

    @MainActor func testMissingCloudAndPermissionRemainDistinct() async throws {
        let provider = FakeThumbnailProvider()
        let loader = CuratorThumbnailLoader(provider: provider)
        for reason in [ThumbnailFailure.cloudOnly, .missing, .permissionDenied, .unavailable] {
            provider.immediate = .failure(reason)
            do { _ = try await loader.load(assetID: "a"); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? ThumbnailFailure, reason) }
        }
    }
}
