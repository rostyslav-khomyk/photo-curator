import Foundation
import CryptoKit
import Vision
import SwiftUI

struct PhotoTextLine: Codable, Equatable {
    let text: String
    let confidence: Float
}

struct PhotoTextEvidence: Codable {
    let assetID: String
    let revision: String
    let engine: String
    let lines: [PhotoTextLine]
}

enum TextRecognitionFailure: Error {
    case timedOut
    /// Vision/OCR rejected the frame; treat as empty evidence and continue.
    case unavailable
}

private final class TextRecognitionOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let request = VNRecognizeTextRequest()
    private var continuation: CheckedContinuation<[PhotoTextLine], Error>?
    private var completed = false
    private var terminalResult: Result<[PhotoTextLine], Error>?

    init() {
        request.recognitionLevel = .accurate
        request.revision = 3
    }

    func run(_ image: CGImage, timeout: TimeInterval) async throws -> [PhotoTextLine] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let terminalResult {
                lock.unlock()
                continuation.resume(with: terminalResult)
                return
            }
            self.continuation = continuation
            lock.unlock()
            DispatchQueue.global(qos: .utility).async { [self] in
                do {
                    try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
                    let lines: [PhotoTextLine] = (request.results ?? []).prefix(100).compactMap { observation -> PhotoTextLine? in
                        guard let candidate = observation.topCandidates(1).first else { return nil }
                        return PhotoTextLine(text: String(candidate.string.prefix(500)),
                                             confidence: candidate.confidence)
                    }
                    finish(.success(lines))
                } catch is CancellationError {
                    finish(.failure(CancellationError()))
                } catch {
                    // CRImageReaderError and similar framework failures must not halt curation.
                    finish(.failure(TextRecognitionFailure.unavailable))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [self] in
                request.cancel()
                finish(.failure(TextRecognitionFailure.timedOut))
            }
        }
    }

    func cancel() {
        request.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<[PhotoTextLine], Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        terminalResult = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// OCR output is evidence, not a verified place or an instruction to the model.
actor MomentTextEvidenceStore {
    static let engine = "vision-ocr-accurate-v1-\(ProcessInfo.processInfo.operatingSystemVersionString)"
    let directory: URL
    private let cache: DerivedCacheStore?

    init(directory: URL, cache: DerivedCacheStore? = nil) {
        self.directory = directory
        self.cache = cache ?? (try? DerivedCacheStore(url: DerivedCacheStore.adjacentToLegacyDirectory(directory)))
    }

    static func cacheKey(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func url(_ id: String) -> URL {
        directory.appendingPathComponent(Self.cacheKey(id) + ".json")
    }

    func cached(_ photo: IndexedPhoto) -> PhotoTextEvidence? {
        let file = url(photo.id)
        let data = cache?.data(namespace: .textEvidence, key: Self.cacheKey(photo.id),
                               maximumBytes: 128 * 1024, legacyURL: file)
            ?? ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { size in
                size <= 128 * 1024 ? try? Data(contentsOf: file) : nil
            })
        guard let data,
              let value = try? JSONDecoder().decode(PhotoTextEvidence.self, from: data),
              value.assetID == photo.id, value.revision == photo.visualContentRevision,
              value.engine == Self.engine else { return nil }
        return value
    }

    func save(_ lines: [PhotoTextLine], for photo: IndexedPhoto) throws -> PhotoTextEvidence {
        try Task.checkCancellation()
        let value = PhotoTextEvidence(assetID: photo.id, revision: photo.visualContentRevision,
                                      engine: Self.engine, lines: Array(lines.prefix(100)))
        let data = try JSONEncoder().encode(value)
        guard data.count <= 128 * 1024 else { throw NarrativeFailure.invalidMetadata }
        if let cache {
            try cache.set(data, namespace: .textEvidence, key: Self.cacheKey(photo.id), maximumBytes: 128 * 1024)
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try data.write(to: url(photo.id), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(photo.id).path)
        }
        return value
    }

    static let maximumEdge = 2048
    static let minimumMeanConfidence: Float = 0.5

    /// Medium-size OCR that errored or found only low-confidence text is retried on the original.
    /// No text at all is a normal result and must not trigger a full-size download.
    static func needsOriginal(_ lines: [PhotoTextLine]?) -> Bool {
        guard let lines else { return true }
        guard !lines.isEmpty else { return false }
        let mean = lines.reduce(Float(0)) { $0 + $1.confidence } / Float(lines.count)
        return mean < minimumMeanConfidence
    }

    func recognize(_ image: CGImage) async throws -> [PhotoTextLine] {
        try Task.checkCancellation()
        // Oversized decode is treated like an unavailable reader: empty OCR, keep going.
        guard image.width <= Self.maximumEdge, image.height <= Self.maximumEdge else {
            throw TextRecognitionFailure.unavailable
        }
        let operation = TextRecognitionOperation()
        return try await withTaskCancellationHandler {
            try await operation.run(image, timeout: 20)
        } onCancel: {
            operation.cancel()
        }
    }
}

struct MomentTextEvidenceView: View {
    let moment: PhotoMoment
    let useClue: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("curator.fontSizeScale") private var fontSizeScale: Double = 1.0
    @State private var results: [PhotoTextEvidence] = []
    @State private var status = "Preparing local text scan..."
    @State private var enlarged: IndexedPhoto?
    @State private var correction = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Text in Photos").font(.system(size: 20 * fontSizeScale, weight: .bold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Local text recognition, not verified places. Signs can help; clothing and packaging can mislead. Inspect the photo, then choose or correct a clue. No downloads or uploads.")
                .font(.system(size: 13 * fontSizeScale)).foregroundStyle(.secondary)
            Text(status).font(.system(size: 12 * fontSizeScale))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(results, id: \.assetID) { result in
                        if !result.lines.isEmpty, let photo = moment.photos.first(where: { $0.id == result.assetID }) {
                            HStack(alignment: .top) {
                                Button { enlarged = photo } label: {
                                    SimilarityThumbnail(photo: photo, height: 110, squareCrop: false)
                                        .frame(width: 140)
                                }.buttonStyle(.plain).help("Inspect source photo")
                                VStack(alignment: .leading) {
                                    Text(photo.created?.formatted() ?? "Date unavailable").font(.caption)
                                    ForEach(Array(result.lines.enumerated()), id: \.offset) { _, line in
                                        HStack {
                                            Button(String(line.text.prefix(100))) { correction = line.text }
                                                .lineLimit(2)
                                            Spacer()
                                            Text("\(Int(line.confidence * 100))% OCR").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            TextField("Choose text above or enter a corrected clue", text: $correction)
                .textFieldStyle(.roundedBorder)
            Button("Use Clue in Caption Suggestion") {
                useClue(String(correction.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)))
                dismiss()
            }.disabled(correction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("OCR confidence measures text recognition, not location certainty. Closing stops the scan; completed results remain cached locally.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 620, idealWidth: 760, minHeight: 480, idealHeight: 650)
        .sheet(item: $enlarged) { ReviewPhotoZoom(photo: $0) }
        .task {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Photo Curator/curator/text-evidence")
            let store = MomentTextEvidenceStore(directory: directory, cache: try? DerivedCacheStore.production())
            let loader = CuratorThumbnailLoader(provider: PhotoKitThumbnailProvider())
            var failed = 0
            for (index, photo) in moment.photos.enumerated() {
                do {
                    try Task.checkCancellation()
                    status = "Reading photo \(index + 1) of \(moment.photos.count)..."
                    if let cached = await store.cached(photo) { results.append(cached) }
                    else {
                        let image = try await loader.load(assetID: photo.id, timeout: 5, edge: 2048)
                        let lines = try await store.recognize(image)
                        results.append(try await store.save(lines, for: photo))
                    }
                } catch is CancellationError { return }
                catch {
                    if Task.isCancelled { return }
                    failed += 1
                }
            }
            status = "\(results.count) photos read; \(results.filter { !$0.lines.isEmpty }.count) with text; \(failed) unavailable or failed."
        }
    }
}
