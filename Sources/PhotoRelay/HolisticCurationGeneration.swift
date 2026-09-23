import Foundation

struct HolisticBoundaryEvidence {
    var visualPercentile: (IndexedPhoto, IndexedPhoto) -> CuratorEvidence<Double> = { _, _ in
        .init(value: nil, confidence: 0, source: "Vision feature print", version: CuratorCalibration.version)
    }
    var ocrOverlap: (IndexedPhoto, IndexedPhoto) -> CuratorEvidence<Double> = { _, _ in
        .init(value: nil, confidence: 0, source: "local OCR", version: CuratorCalibration.version)
    }
    var placeID: (IndexedPhoto) -> String? = { _ in nil }
}

struct HolisticMomentCandidate: Equatable {
    let members: [IndexedPhoto]
    let boundaryBefore: BoundaryEstimate?
}

enum HolisticCurationGenerator {
    static let algorithmVersion = "holistic-boundaries-v1"

    static func candidates(_ photos: [IndexedPhoto], calendar: Calendar = .current,
                           evidence: HolisticBoundaryEvidence = .init()) -> [HolisticMomentCandidate] {
        let ordered = photos.filter { $0.created != nil }.sorted {
            $0.created == $1.created ? $0.id < $1.id : $0.created! < $1.created!
        }
        guard let first = ordered.first else { return [] }
        let cadence = cadenceThresholds(ordered, calendar: calendar)
        var result: [HolisticMomentCandidate] = []
        var current = [first]
        var boundaryBefore: BoundaryEstimate?
        for later in ordered.dropFirst() {
            let earlier = current.last!
            let earlierDate = earlier.created!, laterDate = later.created!
            let gap = max(0, laterDate.timeIntervalSince(earlierDate))
            let geo = EvidenceGrouping.meters(earlier, later)
            let earlierPlace = evidence.placeID(earlier), laterPlace = evidence.placeID(later)
            let observation = BoundaryObservation(earlierID: earlier.id, laterID: later.id,
                logTimeGap: log1p(gap),
                geoMeters: .init(value: geo, confidence: geo == nil ? 0 : 1,
                    source: "recorded GPS", version: CuratorCalibration.version),
                visualPercentile: evidence.visualPercentile(earlier, later),
                ocrOverlap: evidence.ocrOverlap(earlier, later),
                placeConflict: earlierPlace != nil && laterPlace != nil && earlierPlace != laterPlace)
            let estimate = ProbabilisticBoundaryModel.estimate(observation)
            let day = calendar.startOfDay(for: earlierDate)
            let threshold = cadence[day] ?? 2 * 3600
            let split = !calendar.isDate(earlierDate, inSameDayAs: laterDate)
                || gap > threshold
                || estimate.probability >= 0.82
                || (geo ?? 0) > 10_000
                || ((geo ?? 0) > 1_000 && gap > 15 * 60)
                || observation.placeConflict
            if split {
                result.append(.init(members: current, boundaryBefore: boundaryBefore))
                current = [later]
                boundaryBefore = estimate
            } else {
                current.append(later)
            }
        }
        result.append(.init(members: current, boundaryBefore: boundaryBefore))
        return result
    }

    static func moments(_ photos: [IndexedPhoto], calendar: Calendar = .current,
                        evidence: HolisticBoundaryEvidence = .init()) -> [PhotoMoment] {
        makeMoments(candidates(photos, calendar: calendar, evidence: evidence)) { candidate in
            let fingerprint = candidate.members.map(\.id).joined(separator: "|")
            return "candidate-" + MomentContinuity.digest(Data(fingerprint.utf8))
        }
    }

    static func reconciledMoments(_ photos: [IndexedPhoto], previous: [MomentIdentityEntry],
                                  anchors: [String: Set<String>], calendar: Calendar = .current,
                                  evidence: HolisticBoundaryEvidence = .init(),
                                  newID: () -> String = { UUID().uuidString }) throws -> [PhotoMoment] {
        let values = candidates(photos, calendar: calendar, evidence: evidence)
        let resolution = try MomentIdentityResolver.resolve(previous: previous,
            groups: values.map { Set($0.members.map(\.id)) }, anchors: anchors, newID: newID)
        return makeMoments(values) { candidate in
            let members = Set(candidate.members.map(\.id))
            return resolution.current.first { $0.members == members }!.id
        }
    }

    private static func cadenceThresholds(_ photos: [IndexedPhoto], calendar: Calendar) -> [Date: TimeInterval] {
        var gaps: [Date: [TimeInterval]] = [:]
        for pair in zip(photos, photos.dropFirst()) {
            let earlier = pair.0.created!, later = pair.1.created!
            guard calendar.isDate(earlier, inSameDayAs: later) else { continue }
            gaps[calendar.startOfDay(for: earlier), default: []].append(later.timeIntervalSince(earlier))
        }
        return gaps.mapValues { values in
            let ordered = values.filter { $0 >= 0 }.sorted()
            let median = ordered.isEmpty ? 15 * 60 : ordered[ordered.count / 2]
            return min(3 * 3600, max(30 * 60, median * 8))
        }
    }

    private static func boundaryReason(_ estimate: BoundaryEstimate) -> String {
        let strongest = estimate.contributions.max { abs($0.value) < abs($1.value) }?.key ?? "available evidence"
        return "A conservative candidate boundary was supported most strongly by \(strongest). It remains a proposal until the generation is accepted."
    }

    private static func makeMoments(_ candidates: [HolisticMomentCandidate],
                                    id: (HolisticMomentCandidate) -> String) -> [PhotoMoment] {
        candidates.map { candidate in
            PhotoMoment(id: id(candidate), start: candidate.members.first!.created!,
                end: candidate.members.last!.created!, photos: candidate.members,
                groupingSource: algorithmVersion,
                groupingReason: candidate.boundaryBefore.map(boundaryReason), groupingState: .conservative)
        }.reversed()
    }
}

enum HolisticLibraryMetrics {
    static func measure(_ moments: [PhotoMoment], calendar: Calendar = .current,
                        falseJoins: Int? = nil, falseSplits: Int? = nil) -> CurationGenerationMetrics {
        var momentsByDay: [Date: Int] = [:]
        var crossDay = 0
        for moment in moments {
            momentsByDay[calendar.startOfDay(for: moment.start), default: 0] += 1
            if !calendar.isDate(moment.start, inSameDayAs: moment.end) { crossDay += 1 }
        }
        return CurationGenerationMetrics(
            photoCount: moments.reduce(0) { $0 + $1.photos.count }, momentCount: moments.count,
            highlightCount: moments.reduce(0) { $0 + ($1.selection?.selected.count ?? 0) },
            singletonCount: moments.filter { $0.photos.count == 1 }.count,
            smallMomentCount: moments.filter { $0.photos.count <= 3 }.count,
            largeMomentCount: moments.filter { $0.photos.count >= 101 }.count,
            giantMomentCount: moments.filter { $0.photos.count >= 500 }.count,
            fragmentedDayCount: momentsByDay.values.filter { $0 >= 5 }.count,
            crossDayMomentCount: crossDay,
            genericTitleCount: moments.filter { isGeneric($0.narrative?.headline) }.count,
            falseJoinCount: falseJoins, falseSplitCount: falseSplits)
    }

    private static func isGeneric(_ title: String?) -> Bool {
        guard let value = title?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return true }
        let lowered = value.lowercased()
        return lowered.hasPrefix("photos from ") || lowered.hasPrefix("a look back")
            || lowered.hasPrefix("time outdoors") || lowered.hasPrefix("art and interiors")
            || lowered.hasPrefix("food and dining")
    }
}

struct CurationGenerationComparison: Equatable, Sendable {
    let active: CurationGenerationMetrics
    let candidate: CurationGenerationMetrics
    let momentDelta: Int
    let singletonDelta: Int
    let largeMomentDelta: Int
    let fragmentedDayDelta: Int
    let genericTitleDelta: Int
    let activeBenchmarkCost: Int?
    let candidateBenchmarkCost: Int?
    let structuralQualityPassed: Bool
    let canRecommendActivation: Bool

    static func compare(active: CurationGenerationMetrics,
                        candidate: CurationGenerationMetrics) -> Self {
        func cost(_ value: CurationGenerationMetrics) -> Int? {
            guard let joins = value.falseJoinCount, let splits = value.falseSplitCount else { return nil }
            return joins * 3 + splits
        }
        let activeCost = cost(active), candidateCost = cost(candidate)
        let structuralQualityPassed = candidate.fragmentedDayCount <= active.fragmentedDayCount
            && candidate.giantMomentCount <= active.giantMomentCount
            && candidate.genericTitleCount <= active.genericTitleCount
            && (active.highlightCount == 0 || candidate.highlightCount > 0)
        return Self(active: active, candidate: candidate,
            momentDelta: candidate.momentCount - active.momentCount,
            singletonDelta: candidate.singletonCount - active.singletonCount,
            largeMomentDelta: candidate.largeMomentCount - active.largeMomentCount,
            fragmentedDayDelta: candidate.fragmentedDayCount - active.fragmentedDayCount,
            genericTitleDelta: candidate.genericTitleCount - active.genericTitleCount,
            activeBenchmarkCost: activeCost, candidateBenchmarkCost: candidateCost,
            structuralQualityPassed: structuralQualityPassed,
            canRecommendActivation: active.photoCount == candidate.photoCount
                && activeCost != nil && candidateCost != nil && candidateCost! <= activeCost!
                && structuralQualityPassed)
    }
}

struct LibraryOverviewPeriod: Equatable, Sendable, Identifiable {
    let year: Int
    let month: Int
    let photoCount: Int
    let momentCount: Int
    let highlightCount: Int
    var id: String { String(format: "%04d-%02d", year, month) }
}

enum HolisticLibraryOverview {
    /// Aggregate-only overview. Capture density is descriptive and never feeds event boundaries.
    static func periods(_ moments: [PhotoMoment], calendar: Calendar = .current) -> [LibraryOverviewPeriod] {
        struct Counts { var photos = 0; var moments = 0; var highlights = 0 }
        var values: [DateComponents: Counts] = [:]
        for moment in moments {
            let components = calendar.dateComponents([.year, .month], from: moment.start)
            values[components, default: Counts()].photos += moment.photos.count
            values[components, default: Counts()].moments += 1
            values[components, default: Counts()].highlights += moment.selection?.selected.count ?? 0
        }
        return values.map { components, counts in
            LibraryOverviewPeriod(year: components.year!, month: components.month!,
                photoCount: counts.photos, momentCount: counts.moments, highlightCount: counts.highlights)
        }.sorted { ($0.year, $0.month) < ($1.year, $1.month) }
    }

    static func periods(_ moments: [MomentSummary], calendar: Calendar = .current) -> [LibraryOverviewPeriod] {
        struct Counts { var photos = 0; var moments = 0; var highlights = 0 }
        var values: [DateComponents: Counts] = [:]
        for moment in moments {
            let components = calendar.dateComponents([.year, .month], from: moment.start)
            values[components, default: Counts()].photos += moment.photoCount
            values[components, default: Counts()].moments += 1
            values[components, default: Counts()].highlights += moment.highlightCount
        }
        return values.map { components, counts in
            LibraryOverviewPeriod(year: components.year!, month: components.month!,
                photoCount: counts.photos, momentCount: counts.moments, highlightCount: counts.highlights)
        }.sorted { ($0.year, $0.month) < ($1.year, $1.month) }
    }
}

struct CurationStory: Equatable, Sendable, Identifiable {
    let id: String
    let start: Date
    let end: Date
    let momentIDs: [String]
    let placeID: String
}

enum ConservativeStoryBuilder {
    /// Stories are optional navigation parents. Only repeated strong place identity may join
    /// adjacent Moments; capture density and season never provide semantic evidence.
    static func stories(_ moments: [PhotoMoment], calendar: Calendar = .current,
                        placeID: (PhotoMoment) -> String?) -> [CurationStory] {
        let ordered = moments.sorted { $0.start < $1.start }
        var runs: [[PhotoMoment]] = []
        var current: [PhotoMoment] = []
        var currentPlace: String?

        func finishCurrentRun() {
            if !current.isEmpty { runs.append(current) }
            current = []
            currentPlace = nil
        }

        for moment in ordered {
            guard let place = placeID(moment), !place.isEmpty else {
                finishCurrentRun()
                continue
            }
            if let previous = current.last, currentPlace == place,
               moment.start.timeIntervalSince(previous.end) <= 36 * 3600,
               let first = current.first,
               (calendar.dateComponents([.day], from: calendar.startOfDay(for: first.start),
                                        to: calendar.startOfDay(for: moment.start)).day ?? 8) <= 7 {
                current.append(moment)
            } else {
                finishCurrentRun()
                current = [moment]
                currentPlace = place
            }
        }
        finishCurrentRun()
        return runs.compactMap { run in
            guard run.count >= 2, let place = placeID(run[0]) else { return nil }
            let momentIDs = run.map(\.id)
            let fingerprint = place + "|" + momentIDs.joined(separator: "|")
            return CurationStory(id: "story-" + MomentContinuity.digest(Data(fingerprint.utf8)),
                start: run.first!.start, end: run.last!.end, momentIDs: momentIDs, placeID: place)
        }
    }
}

struct HierarchicalHighlightCandidate: Sendable {
    let id: String
    let momentID: String
    let quality: Double
    let protected: Bool
    let roles: Set<String>
}

struct HierarchicalHighlightAllocation: Equatable, Sendable {
    let byMoment: [String: [String]]
    let storyHighlights: [String]
}

enum HierarchicalHighlightAllocator {
    static func allocate(_ candidates: [HierarchicalHighlightCandidate],
                         similarity: (String, String) -> Double?) -> HierarchicalHighlightAllocation {
        let groups = Dictionary(grouping: candidates, by: \.momentID)
        var byMoment: [String: [String]] = [:]
        for (momentID, values) in groups {
            let budget = min(12, max(1, Int(ceil(sqrt(Double(values.count))))))
            byMoment[momentID] = SubmodularHighlightSelector.select(values.map {
                .init(id: $0.id, quality: $0.quality, protected: $0.protected,
                      roles: $0.roles.union(["moment:\(momentID)"]))
            }, maximum: budget, similarity: similarity)
        }
        let momentHighlights = Set(byMoment.values.flatMap { $0 })
        let storyCandidates = candidates.filter { momentHighlights.contains($0.id) }
        let storyBudget = min(30, max(groups.count, Int(ceil(sqrt(Double(candidates.count))))))
        let story = SubmodularHighlightSelector.select(storyCandidates.map {
            .init(id: $0.id, quality: $0.quality, protected: $0.protected,
                  roles: $0.roles.union(["moment:\($0.momentID)"]))
        }, minimum: min(groups.count, storyCandidates.count), maximum: storyBudget,
           minimumGain: 0, similarity: similarity)
        return .init(byMoment: byMoment, storyHighlights: story)
    }
}
