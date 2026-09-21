import AppKit
import ImageIO
import Photos

enum ThumbnailFailure: Error, Equatable {
    case busy, cancelled, timedOut, cloudOnly, missing, permissionDenied, unavailable
}

enum ThumbnailEvent {
    case image(CGImage, degraded: Bool)
    case failure(ThumbnailFailure)
}

@MainActor
protocol CuratorThumbnailProvider {
    func request(assetID: String, edge: Int,
                 completion: @MainActor @escaping @Sendable (ThumbnailEvent) -> Void) -> Int32
    func cancel(_ requestID: Int32)
}

/// One outstanding request per loader; callers must await it rather than build a backlog.
@MainActor
final class CuratorThumbnailLoader {
    private let provider: CuratorThumbnailProvider
    private var active: UUID?
    private var requestID: Int32?
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var timeoutTask: Task<Void, Never>?
    static let maximumEdge = 1024

    init(provider: CuratorThumbnailProvider) { self.provider = provider }

    func load(assetID: String, timeout: TimeInterval = 20, edge: Int = 1024) async throws -> CGImage {
        let interval = CuratorPerformance.begin("Thumbnail request")
        defer { CuratorPerformance.end("Thumbnail request", interval) }
        try Task.checkCancellation()
        guard active == nil else { throw ThumbnailFailure.busy }
        let requestedEdge = min(4096, max(1, edge))
        guard timeout.isFinite, timeout > 0, timeout <= 120 else { throw ThumbnailFailure.timedOut }
        let token = UUID()
        active = token
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    self?.finish(token, .failure(ThumbnailFailure.timedOut))
                }
                let id = provider.request(assetID: assetID, edge: requestedEdge) { [weak self] event in
                    guard let self, self.active == token else { return }
                    switch event {
                    case .image(_, degraded: true): break
                    case .image(let image, degraded: false):
                        if let bounded = Self.bounded(image, edge: requestedEdge) { self.finish(token, .success(bounded)) }
                        else { self.finish(token, .failure(ThumbnailFailure.unavailable)) }
                    case .failure(let error): self.finish(token, .failure(error))
                    }
                }
                // PhotoKit is allowed to call back before returning the request identifier.
                if active == token { requestID = id }
                else { provider.cancel(id) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(token, .failure(ThumbnailFailure.cancelled)) }
        }
    }

    private func finish(_ token: UUID, _ result: Result<CGImage, Error>) {
        guard active == token else { return }
        let continuation = self.continuation
        let id = requestID
        active = nil
        requestID = nil
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if let id { provider.cancel(id) }
        continuation?.resume(with: result)
    }

    private static func bounded(_ image: CGImage, edge: Int) -> CGImage? {
        let scale = min(1, Double(edge) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

@MainActor
final class PhotoKitThumbnailProvider: CuratorThumbnailProvider {
    private final class ReviewRequest {
        var photoKitID = PHInvalidImageRequestID
        var fallbackTask: Task<Void, Never>?
        var usingOriginal = false
    }

    private static let gridManager = PHCachingImageManager()
    private let manager: PHImageManager
    private let allowsNetworkAccess: Bool
    private var reviewRequests: [Int32: ReviewRequest] = [:]
    private var nextReviewRequestID: Int32 = -1000

    init(allowsNetworkAccess: Bool = false) {
        self.allowsNetworkAccess = allowsNetworkAccess
        manager = allowsNetworkAccess ? PHImageManager() : Self.gridManager
    }

    static func setCaching(_ enabled: Bool, assetIDs: [String], edge: Int) {
        guard !assetIDs.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        var values: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in values.append(asset) }
        let size = CGSize(width: edge, height: edge)
        if enabled {
            gridManager.startCachingImages(for: values, targetSize: size, contentMode: .aspectFit, options: nil)
        } else {
            gridManager.stopCachingImages(for: values, targetSize: size, contentMode: .aspectFit, options: nil)
        }
    }

    func request(assetID: String, edge: Int,
                 completion: @MainActor @escaping @Sendable (ThumbnailEvent) -> Void) -> Int32 {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                Task { @MainActor in
                    if newStatus == .authorized {
                        NotificationCenter.default.post(name: .photoRelayPhotosAccessChanged, object: nil)
                        _ = self.performFetch(assetID: assetID, edge: edge, completion: completion)
                    } else {
                        completion(.failure(.permissionDenied))
                    }
                }
            }
            return PHInvalidImageRequestID
        }
        guard status == .authorized else {
            completion(.failure(.permissionDenied)); return PHInvalidImageRequestID
        }
        return performFetch(assetID: assetID, edge: edge, completion: completion)
    }

    private func performFetch(assetID: String, edge: Int,
                              completion: @MainActor @escaping @Sendable (ThumbnailEvent) -> Void) -> Int32 {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject,
              !asset.isHidden else {
            completion(.failure(.missing)); return PHInvalidImageRequestID
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = allowsNetworkAccess
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.version = .current
        if allowsNetworkAccess {
            return requestReviewImage(for: asset, assetID: assetID, edge: edge, completion: completion)
        }
        return manager.requestImage(for: asset, targetSize: CGSize(width: edge, height: edge),
                                    contentMode: .aspectFit, options: options) { image, info in
            let event: ThumbnailEvent
            if (info?[PHImageCancelledKey] as? Bool) == true { event = .failure(.cancelled) }
            else if info?[PHImageErrorKey] != nil { event = .failure(.unavailable) }
            else if let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                event = .image(cgImage, degraded: (info?[PHImageResultIsDegradedKey] as? Bool) == true)
            } else if (info?[PHImageResultIsInCloudKey] as? Bool) == true { event = .failure(.cloudOnly) }
            else { event = .failure(.unavailable) }
            Task { @MainActor in completion(event) }
        }
    }

    private func requestReviewImage(
        for asset: PHAsset,
        assetID: String,
        edge: Int,
        completion: @MainActor @escaping @Sendable (ThumbnailEvent) -> Void
    ) -> Int32 {
        let requestID = nextReviewRequestID
        nextReviewRequestID -= 1
        let request = ReviewRequest()
        reviewRequests[requestID] = request
        startReviewDataRequest(requestID: requestID, request: request, asset: asset,
                               assetID: assetID, edge: edge, version: .current,
                               completion: completion)
        request.fallbackTask = Task { [weak self, weak request] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, let request else { return }
            self.startOriginalFallback(requestID: requestID, request: request, asset: asset,
                                       assetID: assetID, edge: edge, completion: completion)
        }
        return requestID
    }

    private func startReviewDataRequest(
        requestID: Int32,
        request: ReviewRequest,
        asset: PHAsset,
        assetID: String,
        edge: Int,
        version: PHImageRequestOptionsVersion,
        completion: @MainActor @escaping @Sendable (ThumbnailEvent) -> Void
    ) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.version = version
        request.photoKitID = manager.requestImageDataAndOrientation(for: asset, options: options) { [weak self, weak request] data, _, _, info in
            Task { @MainActor [weak self, weak request] in
                guard let self, let request, self.reviewRequests[requestID] === request else { return }
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    if !request.usingOriginal { return }
                    self.finishReviewRequest(requestID, request: request, event: .failure(.cancelled),
                                             completion: completion)
                } else if let error = info?[PHImageErrorKey] as? Error {
                    NSLog("Photo Curator %@ preview failed for %@: %@",
                          version == .original ? "original" : "edited", assetID, error.localizedDescription)
                    if version == .current {
                        self.startOriginalFallback(requestID: requestID, request: request, asset: asset,
                                                   assetID: assetID, edge: edge, completion: completion)
                    } else {
                        self.finishReviewRequest(requestID, request: request, event: .failure(.unavailable),
                                                 completion: completion)
                    }
                } else if let data, let image = Self.thumbnail(from: data, edge: edge) {
                    self.finishReviewRequest(requestID, request: request, event: .image(image, degraded: false),
                                             completion: completion)
                } else if (info?[PHImageResultIsInCloudKey] as? Bool) == true {
                    if version == .current {
                        self.startOriginalFallback(requestID: requestID, request: request, asset: asset,
                                                   assetID: assetID, edge: edge, completion: completion)
                    } else {
                        self.finishReviewRequest(requestID, request: request, event: .failure(.cloudOnly),
                                                 completion: completion)
                    }
                } else if version == .current {
                    self.startOriginalFallback(requestID: requestID, request: request, asset: asset,
                                               assetID: assetID, edge: edge, completion: completion)
                } else {
                    NSLog("Photo Curator original preview returned no decodable data for %@", assetID)
                    self.finishReviewRequest(requestID, request: request, event: .failure(.unavailable),
                                             completion: completion)
                }
            }
        }
    }

    private func startOriginalFallback(
        requestID: Int32,
        request: ReviewRequest,
        asset: PHAsset,
        assetID: String,
        edge: Int,
        completion: @MainActor @escaping @Sendable (ThumbnailEvent) -> Void
    ) {
        guard reviewRequests[requestID] === request, !request.usingOriginal else { return }
        request.usingOriginal = true
        request.fallbackTask?.cancel()
        request.fallbackTask = nil
        if request.photoKitID != PHInvalidImageRequestID { manager.cancelImageRequest(request.photoKitID) }
        NSLog("Photo Curator using original preview fallback for %@", assetID)
        startReviewDataRequest(requestID: requestID, request: request, asset: asset,
                               assetID: assetID, edge: edge, version: .original,
                               completion: completion)
    }

    private func finishReviewRequest(
        _ requestID: Int32,
        request: ReviewRequest,
        event: ThumbnailEvent,
        completion: @MainActor @escaping @Sendable (ThumbnailEvent) -> Void
    ) {
        guard reviewRequests.removeValue(forKey: requestID) === request else { return }
        request.fallbackTask?.cancel()
        request.fallbackTask = nil
        completion(event)
    }

    private static func thumbnail(from data: Data, edge: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    func cancel(_ requestID: Int32) {
        if let request = reviewRequests.removeValue(forKey: requestID) {
            request.fallbackTask?.cancel()
            if request.photoKitID != PHInvalidImageRequestID { manager.cancelImageRequest(request.photoKitID) }
            return
        }
        if requestID != PHInvalidImageRequestID { manager.cancelImageRequest(requestID) }
    }
}
