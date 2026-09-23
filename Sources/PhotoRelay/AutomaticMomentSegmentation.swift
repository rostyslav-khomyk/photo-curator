import Foundation
import CryptoKit

struct AutomaticMomentSegment: Codable {
    let id: String
    let members: [String]
    let reason: String
    var kind: AutomaticMomentSegmentKind? = nil
}

enum AutomaticMomentSegmentKind: String, Codable, Sendable { case scene, unresolved }

struct AutomaticMomentRecord: Codable {
    var version = 1
    let fingerprint: String
    let segments: [AutomaticMomentSegment]
    var evidenceFingerprint: String? = nil
    var boundaryEstimates: [BoundaryEstimate]? = nil
}

/// Conservative boundaries, not scene identity or near-duplicate clustering.
enum AutomaticMomentSegmentation {
    static func fingerprint(_ moment: PhotoMoment) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var data = try encoder.encode(moment.photos.sorted { $0.id < $1.id })
        data.append(Data(("semantic-boundaries-v2-" + CuratorVisionAnalyzer.version + NarrativeVisualContext.version).utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func propose(_ moment: PhotoMoment, labels: [String: [String]], text: [String: [PhotoTextLine]],
                        distance: (String, String) -> Float?) throws -> AutomaticMomentRecord {
        let photos = moment.photos.sorted { $0.created == $1.created ? $0.id < $1.id : ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
        guard !photos.isEmpty, photos.count <= 512,
              Set(photos.map(\.id)).count == photos.count else { throw PublicationFailure.invalidRequest }
        if SceneMomentGrouping.compressedTimes(photos) {
            if SceneMomentGrouping.sharedRecordedLocation(photos) {
                return AutomaticMomentRecord(fingerprint: try fingerprint(moment), segments: [
                    AutomaticMomentSegment(id: moment.id, members: photos.map(\.id),
                        reason: "Available recorded locations agree within 150 metres. This collection stays together despite visual changes; compressed capture times do not establish an itinerary or verified event.")])
            }
            let groups = try SceneMomentGrouping.groups(photos, labels: labels, distance: distance)
            let assigned = Set(groups.flatMap { $0.map(\.id) })
            var segments = groups.map { group in
                var reason = "Capture times are tightly packed and may reflect an import, so time order was not used to infer an outing. At least three photos match a fixed visual reference, without conflicting recorded GPS or distinctive scene clues. Similarity is not chained through neighboring photos. This is a possible repeated scene, not a verified venue or event."
                if let anchor = group.first, group.dropFirst().contains(where: {
                    EvidenceGrouping.sharedText(text[anchor.id] ?? [], text[$0.id] ?? []) != nil
                }) { reason += " Shared local OCR provides supporting context, not a place identification." }
                return AutomaticMomentSegment(id: group.count == photos.count ? moment.id : sceneID(group.map(\.id)), members: group.map(\.id), reason: reason, kind: .scene)
            }
            let unresolved = photos.filter { !assigned.contains($0.id) }
            if !unresolved.isEmpty {
                segments.append(AutomaticMomentSegment(id: groups.isEmpty ? moment.id : sceneID(unresolved.map(\.id)),
                    members: unresolved.map(\.id),
                    reason: "Capture times are tightly packed and may reflect an import. These photos lack enough repeated-scene evidence for a confident subdivision. They remain available together for review, not as a confirmed single event.", kind: .unresolved))
            }
            return AutomaticMomentRecord(fingerprint: try fingerprint(moment), segments: segments)
        }
        let distinctive: Set<String> = ["castle", "beach", "forest", "mountain", "waterfall", "desert", "snow", "church", "aquarium", "stadium"]
        func scenes(_ photo: IndexedPhoto) -> Set<String> { Set(labels[photo.id] ?? []).intersection(distinctive) }
        func close(_ a: IndexedPhoto, _ b: IndexedPhoto) -> Bool {
            guard let d = distance(a.id, b.id), d.isFinite, d >= 0 else { return false }
            return d <= EvidenceGrouping.defaultCutoff
        }
        var boundaries: [(Int, String)] = [(0, "Continuous photo sequence grouped by capture time and location.")]
        if photos.count >= 4 {
            for index in 2..<(photos.count - 1) {
                try Task.checkCancellation()
                guard index - boundaries.last!.0 >= 2 else { continue }
                let a = photos[index - 2], b = photos[index - 1], c = photos[index], d = photos[index + 1]
                guard close(a, b), close(c, d), let separation = distance(b.id, c.id),
                      separation.isFinite, separation > EvidenceGrouping.defaultCutoff else { continue }
                let before = scenes(a).intersection(scenes(b))
                let after = scenes(c).intersection(scenes(d))
                let sceneChange = !before.isEmpty && !after.isEmpty && before.isDisjoint(with: after)
                let gpsChange = (EvidenceGrouping.meters(a, b) ?? .infinity) <= 1000
                    && (EvidenceGrouping.meters(c, d) ?? .infinity) <= 1000
                    && (EvidenceGrouping.meters(b, c) ?? 0) > 1500
                guard sceneChange || gpsChange else { continue }
                var reason = gpsChange ? "Recorded GPS shifts more than 1.5 km between locally coherent pairs."
                    : "Repeated scene clues change from \(before.sorted().joined(separator: ", ")) to \(after.sorted().joined(separator: ", "))."
                reason += " Visual separation supports this proposed boundary; venue and event remain unverified."
                if EvidenceGrouping.sharedText(text[c.id] ?? [], text[d.id] ?? []) != nil {
                    reason += " Repeated local OCR supports continuity after the boundary."
                }
                boundaries.append((index, reason))
            }
        }
        let estimates = zip(photos, photos.dropFirst()).map { lhs, rhs in
            let gap = max(0, (rhs.created ?? .distantPast).timeIntervalSince(lhs.created ?? .distantPast))
            let geo = EvidenceGrouping.meters(lhs, rhs)
            let visual = distance(lhs.id, rhs.id)
            return ProbabilisticBoundaryModel.estimate(.init(earlierID: lhs.id, laterID: rhs.id,
                logTimeGap: log1p(gap),
                geoMeters: .init(value: geo, confidence: geo == nil ? 0 : 1, source: "PhotoKit GPS", version: CuratorCalibration.version),
                visualPercentile: CuratorCalibration.percentile(visual, cutoffs: [0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 20]),
                ocrOverlap: .init(value: nil, confidence: 0, source: "Vision OCR", version: CuratorCalibration.version),
                placeConflict: geo.map { $0 > 1_500 } ?? false))
        }
        let segments = boundaries.indices.map { index -> AutomaticMomentSegment in
            let end = index + 1 < boundaries.count ? boundaries[index + 1].0 : photos.count
            let members = Array(photos[boundaries[index].0..<end]).map(\.id)
            let hash = SHA256.hash(data: Data(members.sorted().joined(separator: "|").utf8)).map { String(format: "%02x", $0) }.joined()
            return AutomaticMomentSegment(id: boundaries.count == 1 ? moment.id : "moment-" + hash,
                                          members: members, reason: boundaries[index].1)
        }
        return AutomaticMomentRecord(fingerprint: try fingerprint(moment), segments: segments,
                                     boundaryEstimates: ProbabilisticBoundaryModel.smooth(estimates))
    }

    private static func sceneID(_ members: [String]) -> String {
        "moment-" + SHA256.hash(data: Data(members.sorted().joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

struct AutomaticMomentStore {
    let root: URL
    let cache: DerivedCacheStore?
    let namespace: DerivedCacheNamespace

    init(root: URL, cache: DerivedCacheStore? = nil,
         namespace: DerivedCacheNamespace = .automaticMoments) {
        self.root = root
        self.cache = cache ?? (try? DerivedCacheStore(url: DerivedCacheStore.adjacentToLegacyDirectory(root)))
        self.namespace = namespace
    }

    func discard(_ id: String) throws {
        let file = url(id)
        if let cache { try cache.remove(namespace: namespace, key: key(id)) }
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    private func key(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func url(_ id: String) -> URL {
        root.appendingPathComponent(key(id) + ".json")
    }
    func load(_ id: String) throws -> AutomaticMomentRecord? {
        let file = url(id)
        let data = cache?.data(namespace: namespace, key: key(id), maximumBytes: 256 * 1024, legacyURL: file)
            ?? ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { size in
                size <= 256 * 1024 ? try? Data(contentsOf: file) : nil
            })
        guard let data else { return nil }
        let record = try JSONDecoder().decode(AutomaticMomentRecord.self, from: data)
        let members = record.segments.flatMap(\.members)
        guard record.version == 1, !record.segments.isEmpty,
              record.segments.allSatisfy({ !$0.members.isEmpty }),
              Set(record.segments.map(\.id)).count == record.segments.count,
              Set(members).count == members.count else { throw PublicationFailure.corruptJournal }
        return record
    }
    func save(_ record: AutomaticMomentRecord, for moment: PhotoMoment) throws {
        try Task.checkCancellation()
        let members = record.segments.flatMap(\.members)
        guard record.version == 1, !record.segments.isEmpty,
              record.segments.allSatisfy({ !$0.id.isEmpty && !$0.members.isEmpty }),
              Set(record.segments.map(\.id)).count == record.segments.count,
              Set(members).count == members.count,
              Set(members) == Set(moment.photos.map(\.id)),
              record.fingerprint == (try AutomaticMomentSegmentation.fingerprint(moment)) else { throw PublicationFailure.invalidRequest }
        let data = try JSONEncoder().encode(record)
        guard data.count <= 256 * 1024 else { throw PublicationFailure.invalidRequest }
        if let cache {
            try cache.set(data, namespace: namespace, key: key(moment.id), maximumBytes: 256 * 1024)
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url(moment.id), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(moment.id).path)
        }
    }
    func apply(_ moment: PhotoMoment, protected: Set<String>) throws -> [PhotoMoment] {
        var pending = moment
        if moment.groupingState == .reviewed || protected.contains(moment.id) {
            pending.groupingState = .reviewed
            return [pending]
        }
        if moment.photos.count > 512,
           try load(moment.id)?.segments.contains(where: { protected.contains($0.id) }) != true {
            return [try LargeMomentWindowStore(root: root, cache: cache).project(moment)]
        }
        pending.groupingState = moment.photos.count > 512 ? .conservative : .preparing
        pending.groupingReason = moment.photos.count > 512
            ? "This large collection keeps its time/location grouping; finer grouping is not yet supported for more than 512 photos."
            : "Waiting for local visual and text evidence before refining this time/location group."
        if let continuity = moment.continuityReason { pending.groupingReason = continuity + " " + (pending.groupingReason ?? "") }
        guard let record = try load(moment.id) else { return [pending] }
        let current = record.fingerprint == (try AutomaticMomentSegmentation.fingerprint(moment))
        guard current || record.segments.contains(where: { protected.contains($0.id) }) else { return [pending] }
        let photos = Dictionary(uniqueKeysWithValues: moment.photos.map { ($0.id, $0) })
        var assigned = Set<String>()
        var output: [PhotoMoment] = []
        for segment in record.segments {
            let members = segment.members.compactMap { photos[$0] }.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
            guard let start = members.first?.created, let end = members.last?.created else { continue }
            assigned.formUnion(members.map(\.id))
            output.append(PhotoMoment(id: segment.id, start: start, end: end, photos: members,
                                      groupingSource: moment.id, groupingReason: (moment.continuityReason.map { $0 + " " } ?? "") + segment.reason,
                                      groupingState: current ? (segment.kind == .unresolved ? .conservative : .ready) : .reviewed,
                                      groupingKind: segment.kind, continuityReason: moment.continuityReason))
        }
        let added = moment.photos.filter { !assigned.contains($0.id) }
        for residual in MomentGrouping.group(added) {
            let hash = SHA256.hash(data: Data(residual.photos.map(\.id).sorted().joined(separator: "|").utf8))
                .map { String(format: "%02x", $0) }.joined()
            output.append(PhotoMoment(id: "unassigned-" + hash, start: residual.start, end: residual.end,
                photos: residual.photos, groupingState: .preparing))
        }
        return output
    }
}
