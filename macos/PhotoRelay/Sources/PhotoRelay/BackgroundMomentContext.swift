import Foundation
import CryptoKit
import CoreGraphics

struct BackgroundCaption: Codable {
    let fingerprint: String
    let narrative: MomentNarrative
    var retryAfter: Date? = nil
    var evidence: MomentCaptionEvidence? = nil
    var evidenceFingerprint: String? = nil
}

/// Derived local evidence and text; never writes to the user's correction store.
actor BackgroundMomentContext {
    let root: URL
    private let classifier = NarrativeVisualContext()
    private let textStore: MomentTextEvidenceStore
    private var preparing = false
    init(root: URL, textDirectory: URL? = nil) {
        self.root = root
        self.textStore = MomentTextEvidenceStore(directory: textDirectory ?? root.appendingPathComponent("text-evidence"))
    }

    private func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func labelsURL(_ photo: IndexedPhoto) -> URL {
        root.appendingPathComponent("labels-" + key(photo.id + photo.analysisRevision + NarrativeVisualContext.version + ProcessInfo.processInfo.operatingSystemVersionString) + ".json")
    }
    private func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 128 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private func write<T: Encodable>(_ value: T, at url: URL) throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(value)
        guard data.count < 128 * 1024 else { throw NarrativeFailure.invalidMetadata }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func hasLabels(_ photo: IndexedPhoto) -> Bool { read([String].self, at: labelsURL(photo)) != nil }
    func cachedLabels(_ photo: IndexedPhoto) -> [String]? { read([String].self, at: labelsURL(photo)) }
    func saveLabels(_ labels: [String], for photo: IndexedPhoto) throws {
        guard labels.count <= 8, labels.allSatisfy({ !$0.isEmpty && $0.count <= 100 }) else { throw NarrativeFailure.invalidMetadata }
        try write(labels, at: labelsURL(photo))
    }
    func capture(_ photo: IndexedPhoto, image: CGImage) async throws {
        guard !hasLabels(photo) else { return }
        let labels = try await classifier.labels(image)
        try saveLabels(labels, for: photo)
    }
    private func fingerprint(_ moment: PhotoMoment) -> String {
        struct Input: Encodable {
            struct Photo: Encodable {
                let id: String, revision: String
                let date: Date?
                let favorite: Bool
                let screenshot: Bool
                let latitude: Double?, longitude: Double?
            }
            let photos: [Photo]
            let groupingKind: AutomaticMomentSegmentKind?
            let version: String
        }
        let input = Input(photos: moment.photos.map {
            Input.Photo(id: $0.id, revision: $0.analysisRevision, date: $0.created, favorite: $0.favorite,
                        screenshot: $0.similarityCategory == .screenshots, latitude: $0.latitude, longitude: $0.longitude)
        }.sorted { $0.id < $1.id }, groupingKind: moment.groupingKind,
            version: CaptionEvidenceBuilder.version + MomentTextEvidenceStore.engine + NarrativeVisualContext.version)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return key(String(decoding: (try? encoder.encode(input)) ?? Data(), as: UTF8.self))
    }
    func cached(_ moment: PhotoMoment) -> BackgroundCaption? {
        let value = read(BackgroundCaption.self, at: root.appendingPathComponent("moment-" + key(moment.id) + ".json"))
        return value?.fingerprint == fingerprint(moment) ? value : nil
    }

    /// One collection per invocation. Revisit when sampled visual evidence improves.
    func prepare(_ moment: PhotoMoment, model: LocalNarrativeModel) async throws -> Bool {
        let photos = moment.photos
        guard !photos.isEmpty, !preparing, moment.groupingKind != .unresolved else { return false }
        preparing = true
        defer { preparing = false }
        var inputs: [CaptionEvidencePhoto] = []
        let sampled = CaptionEvidenceBuilder.sample(photos)
        for photo in sampled {
            try Task.checkCancellation()
            if photo.similarityCategory == .screenshots {
                inputs.append(CaptionEvidencePhoto(photo: photo, labels: [], lines: []))
                continue
            }
            // Empty results are completed evidence; absent cache entries are not.
            if let labels = cachedLabels(photo), let text = await textStore.cached(photo) {
                inputs.append(CaptionEvidencePhoto(photo: photo, labels: labels, lines: text.lines))
            }
        }
        let required = min(sampled.count, 4)
        guard inputs.count >= required, !inputs.isEmpty else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let evidenceFingerprint = key(String(decoding: try encoder.encode(inputs), as: UTF8.self))
        if let previous = cached(moment), previous.evidenceFingerprint == evidenceFingerprint,
           previous.retryAfter == nil || previous.retryAfter! > Date() { return false }
        let evidence = CaptionEvidenceBuilder.build(inputs, moment: moment)
        let place = await CuratorGeocodingService.shared.place(for: moment)
        let metadata = MomentNarrativeMetadata(dateLabel: moment.start.formatted(date: .abbreviated, time: .omitted),
            photoCount: photos.count, favoriteCount: moment.favorites, verifiedPlace: place?.friendlyName,
            contextEvidence: evidence, placeRole: place?.meaningfulLabel)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let suggestion = try await LocalMomentNarrative(cacheURL: root.appendingPathComponent("caption-choices.json")).suggest(metadata, model: model)
        let narrative = MomentNarrative(version: MomentNarrative.version, headline: suggestion.text.title, deck: nil,
            story: suggestion.text.description, place: place?.friendlyName, date: metadata.dateLabel,
            confidence: suggestion.source == "Deterministic fallback" ? 0.55 : 0.8,
            provenance: [suggestion.source], state: .automatic)
        try write(BackgroundCaption(fingerprint: fingerprint(moment), narrative: narrative,
                                    retryAfter: suggestion.source == "Deterministic fallback" ? Date().addingTimeInterval(3600) : nil,
                                    evidence: evidence, evidenceFingerprint: evidenceFingerprint),
                  at: root.appendingPathComponent("moment-" + key(moment.id) + ".json"))
        return true
    }
}
