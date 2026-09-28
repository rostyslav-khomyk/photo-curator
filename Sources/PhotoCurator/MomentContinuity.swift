import Foundation
import CryptoKit

struct MomentContinuityPair {
    let earlier: PhotoMoment
    let later: PhotoMoment
    var id: String { "continuity-" + MomentContinuity.digest(Data((earlier.id + "|" + later.id).utf8)) }
    var photos: [IndexedPhoto] { earlier.photos + later.photos }
}

struct MomentContinuityRecord: Codable {
    struct Match: Codable { let earlier: String; let later: String; let distance: Float }
    let fingerprint: String
    let evidenceFingerprint: String
    let matches: [Match]
    var boundaryEstimate: BoundaryEstimate? = nil
    var joins: Bool { matches.count >= 2 && (boundaryEstimate?.probability ?? 0) < 0.95 }
    static let reason = "Possible continuation of the same visit across a time gap: recorded locations agree within 150 metres and multiple display photos match across the gap. No conflicting local scene or occasion clues were found. This is provisional continuity, not a verified event or venue; no coordinates were inferred."
}

enum MomentContinuity {
    static let version = "continuity-v2-" + CuratorVisionAnalyzer.version + NarrativeVisualContext.version + MomentTextEvidenceStore.engine + PhotoDisplayEvidence.version
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func eligible(_ pair: MomentContinuityPair, protected: Set<String> = [], calendar: Calendar = .current) -> Bool {
        let a = pair.earlier, b = pair.later
        let gap = b.start.timeIntervalSince(a.end)
        return a.id != b.id && !protected.contains(a.id) && !protected.contains(b.id)
            && a.groupingState != .reviewed && b.groupingState != .reviewed
            && a.reviewedGroupTitle == nil && b.reviewedGroupTitle == nil
            && a.continuityReason == nil && b.continuityReason == nil
            && gap >= 0 && gap <= 10800 && b.end.timeIntervalSince(a.start) <= 21600
            && calendar.isDate(a.start, inSameDayAs: b.end)
            && (2...512).contains(a.photos.count) && b.photos.count >= 2 && pair.photos.count <= 512
            && Set(pair.photos.map(\.id)).count == pair.photos.count
            && pair.photos.allSatisfy({ $0.created?.timeIntervalSince1970.isFinite == true })
            && !SceneMomentGrouping.compressedTimes(a.photos) && !SceneMomentGrouping.compressedTimes(b.photos)
    }

    static func pairs(_ moments: [PhotoMoment], protected: Set<String>) -> [MomentContinuityPair] {
        let ordered = moments.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start > $1.start }
        return zip(ordered, ordered.dropFirst()).compactMap { later, earlier in
            let pair = MomentContinuityPair(earlier: earlier, later: later)
            return eligible(pair, protected: protected) ? pair : nil
        }
    }

    static func fingerprint(_ pair: MomentContinuityPair) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var data = try encoder.encode(pair.photos.sorted { $0.id < $1.id })
        data.append(Data((version + pair.id).utf8))
        return digest(data)
    }

    static func propose(_ pair: MomentContinuityPair, labels: [String: [String]], text: [String: [PhotoTextLine]],
                        results: [String: CuratorVisionResult], evidenceFingerprint: String,
                        distance: (String, String) -> Float?) throws -> MomentContinuityRecord {
        let fingerprint = try fingerprint(pair)
        func decision(_ matches: [MomentContinuityRecord.Match] = [], estimate: BoundaryEstimate? = nil) -> MomentContinuityRecord {
            MomentContinuityRecord(fingerprint: fingerprint, evidenceFingerprint: evidenceFingerprint, matches: matches,
                                   boundaryEstimate: estimate)
        }
        guard eligible(pair) else { return decision() }
        let locatedA = pair.earlier.photos.filter(EvidenceGrouping.validGPS)
        let locatedB = pair.later.photos.filter(EvidenceGrouping.validGPS)
        guard locatedA.count >= 2, locatedB.count >= 2, let anchor = locatedA.first,
              (locatedA + locatedB).allSatisfy({ (EvidenceGrouping.meters(anchor, $0) ?? .infinity) <= 150 }) else { return decision() }

        let distinctive: Set<String> = ["castle", "beach", "forest", "mountain", "waterfall", "desert", "church", "aquarium", "stadium"]
        let occasions: Set<String> = ["wedding", "birthday", "graduation", "conference", "funeral", "anniversary"]
        func repeated(_ photos: [IndexedPhoto], words: (IndexedPhoto) -> Set<String>) -> Set<String> {
            var counts: [String: Int] = [:]
            for photo in photos { for value in words(photo) { counts[value, default: 0] += 1 } }
            return Set(counts.filter { $0.value >= 2 }.keys)
        }
        func scenes(_ photos: [IndexedPhoto]) -> Set<String> {
            repeated(photos) { Set(labels[$0.id] ?? []).intersection(distinctive) }
        }
        func events(_ photos: [IndexedPhoto]) -> Set<String> {
            repeated(photos) { photo in
                Set((text[photo.id] ?? []).filter { $0.confidence.isFinite && (0.9...1).contains($0.confidence) }
                    .flatMap { $0.text.lowercased().components(separatedBy: CharacterSet.letters.inverted) }).intersection(occasions)
            }
        }
        let a = scenes(pair.earlier.photos), b = scenes(pair.later.photos)
        let eventA = events(pair.earlier.photos), eventB = events(pair.later.photos)
        guard a.isEmpty || b.isEmpty || !a.isDisjoint(with: b),
              eventA.isEmpty || eventB.isEmpty || eventA == eventB else { return decision() }
        func candidates(_ photos: [IndexedPhoto]) -> [IndexedPhoto] {
            photos.filter { photo in
                MomentDisplayEligibility.classify(photo, labels: labels[photo.id] ?? [], lines: text[photo.id] ?? [], result: results[photo.id]) == nil
            }.sorted { $0.created == $1.created ? $0.id < $1.id : ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
        }
        // Fixed boundary samples and one-to-one matches prevent one repeated image from joining visits.
        let left = Array(candidates(pair.earlier.photos).suffix(6))
        let right = Array(candidates(pair.later.photos).prefix(6))
        var edges: [MomentContinuityRecord.Match] = []
        for lhs in left { for rhs in right {
            try Task.checkCancellation()
            guard let d = distance(lhs.id, rhs.id), d.isFinite, d >= 0, d <= EvidenceGrouping.defaultCutoff else { continue }
            edges.append(.init(earlier: lhs.id, later: rhs.id, distance: d))
        } }
        edges.sort { $0.distance == $1.distance ? ($0.earlier + $0.later) < ($1.earlier + $1.later) : $0.distance < $1.distance }
        var usedA = Set<String>(), usedB = Set<String>(), matches: [MomentContinuityRecord.Match] = []
        for edge in edges where !usedA.contains(edge.earlier) && !usedB.contains(edge.later) {
            usedA.insert(edge.earlier); usedB.insert(edge.later); matches.append(edge)
        }
        guard matches.count >= 2 else { return decision() }
        let gap = max(0, pair.later.start.timeIntervalSince(pair.earlier.end))
        let geo = EvidenceGrouping.meters(pair.earlier.photos[0], pair.later.photos[0])
        let medianDistance = matches.map(\.distance).sorted()[matches.count / 2]
        let sharedOCR = pair.earlier.photos.contains { lhs in pair.later.photos.contains { rhs in
            EvidenceGrouping.sharedText(text[lhs.id] ?? [], text[rhs.id] ?? []) != nil
        } }
        let observation = BoundaryObservation(earlierID: pair.earlier.id, laterID: pair.later.id,
            logTimeGap: log1p(gap),
            geoMeters: .init(value: geo, confidence: geo == nil ? 0 : 1, source: "PhotoKit GPS", version: CuratorCalibration.version),
            visualPercentile: CuratorCalibration.percentile(medianDistance,
                cutoffs: [0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 20]),
            ocrOverlap: .init(value: sharedOCR ? 1 : nil, confidence: sharedOCR ? 1 : 0,
                              source: "Vision OCR", version: CuratorCalibration.version),
            placeConflict: geo.map { $0 > 1_500 } ?? false)
        return decision(matches, estimate: ProbabilisticBoundaryModel.estimate(observation))
    }
}

struct MomentContinuityStore {
    let root: URL
    let cache: DerivedCacheStore?

    init(root: URL, cache: DerivedCacheStore? = nil) {
        self.root = root
        self.cache = cache ?? (try? DerivedCacheStore(url: DerivedCacheStore.adjacentToLegacyDirectory(root)))
    }

    private func file(_ pair: MomentContinuityPair) -> URL { root.appendingPathComponent(pair.id + ".json") }
    func load(_ pair: MomentContinuityPair) throws -> MomentContinuityRecord? {
        let url = file(pair)
        let data = cache?.data(namespace: .momentContinuity, key: pair.id, maximumBytes: 64 * 1024, legacyURL: url)
            ?? ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { size in
                size <= 64 * 1024 ? try? Data(contentsOf: url) : nil
            })
        guard let data, let record = try? JSONDecoder().decode(MomentContinuityRecord.self, from: data),
              record.fingerprint == (try MomentContinuity.fingerprint(pair)), record.matches.count <= 6,
              Set(record.matches.map(\.earlier)).count == record.matches.count,
              Set(record.matches.map(\.later)).count == record.matches.count,
              record.matches.allSatisfy({ edge in pair.earlier.photos.contains { $0.id == edge.earlier }
                  && pair.later.photos.contains { $0.id == edge.later }
                  && edge.distance.isFinite && (0...EvidenceGrouping.defaultCutoff).contains(edge.distance) }),
              record.boundaryEstimate.map({ $0.probability.isFinite && (0...1).contains($0.probability) }) ?? true else { return nil }
        return record
    }
    func save(_ record: MomentContinuityRecord, pair: MomentContinuityPair) throws {
        try Task.checkCancellation()
        guard record.fingerprint == (try MomentContinuity.fingerprint(pair)), record.matches.count <= 6,
              record.evidenceFingerprint.count <= 128,
              Set(record.matches.map(\.earlier)).count == record.matches.count,
              Set(record.matches.map(\.later)).count == record.matches.count,
              record.matches.allSatisfy({ edge in pair.earlier.photos.contains { $0.id == edge.earlier }
                  && pair.later.photos.contains { $0.id == edge.later }
                  && edge.distance.isFinite && (0...EvidenceGrouping.defaultCutoff).contains(edge.distance) }),
              record.boundaryEstimate.map({ $0.probability.isFinite && (0...1).contains($0.probability) }) ?? true else { throw PublicationFailure.invalidRequest }
        let data = try JSONEncoder().encode(record)
        guard data.count <= 64 * 1024 else { throw PublicationFailure.invalidRequest }
        if let cache {
            try cache.set(data, namespace: .momentContinuity, key: pair.id, maximumBytes: 64 * 1024)
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file(pair), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(pair).path)
        }
    }
    func apply(_ moments: [PhotoMoment], protected: Set<String>) throws -> [PhotoMoment] {
        var assigned = Set<String>(), merged: [PhotoMoment] = []
        for pair in MomentContinuity.pairs(moments, protected: protected) {
            guard !assigned.contains(pair.earlier.id), !assigned.contains(pair.later.id), try load(pair)?.joins == true else { continue }
            assigned.formUnion([pair.earlier.id, pair.later.id])
            let photos = pair.photos.sorted { $0.created == $1.created ? $0.id < $1.id : $0.created! < $1.created! }
            merged.append(PhotoMoment(id: pair.id, start: pair.earlier.start, end: pair.later.end, photos: photos,
                groupingReason: MomentContinuityRecord.reason, continuityReason: MomentContinuityRecord.reason))
        }
        return (moments.filter { !assigned.contains($0.id) } + merged).sorted { $0.start == $1.start ? $0.id < $1.id : $0.start > $1.start }
    }
}
