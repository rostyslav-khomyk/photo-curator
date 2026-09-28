import Foundation
import CoreLocation

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

    /// Coalesces only uncurated singletons at a habitual place. Event-sized, reviewed,
    /// customized, Favorite, and published Moments remain untouched.
    static func refiningRoutineSingletons(_ moments: [PhotoMoment], places: [MeaningfulPlace],
                                          protectedMomentIDs: Set<String> = [],
                                          calendar: Calendar = .current) -> [PhotoMoment] {
        struct Key: Hashable { let placeID: UUID; let year: Int; let month: Int; let reference: Bool }
        var groups: [Key: [(PhotoMoment, MeaningfulPlace)]] = [:]
        var output: [PhotoMoment] = []

        for moment in moments {
            guard moment.photos.count == 1, !moment.photos[0].favorite,
                  moment.publishedAlbumID == nil, moment.groupingState != .reviewed,
                  moment.narrative?.state != .customized, !protectedMomentIDs.contains(moment.id),
                  let place = habitualPlace(for: moment, places: places) else {
                output.append(moment)
                continue
            }
            let parts = calendar.dateComponents([.year, .month], from: moment.start)
            guard let year = parts.year, let month = parts.month else { output.append(moment); continue }
            let reference = MomentDisplayEligibility.evidence(for: moment.photos[0], in: moment) != nil
            groups[Key(placeID: place.id, year: year, month: month, reference: reference), default: []]
                .append((moment, place))
        }

        for (key, values) in groups {
            guard values.count >= 2 else { output.append(values[0].0); continue }
            let ordered = values.map(\.0).sorted { $0.start < $1.start }
            let place = values[0].1
            let photos = ordered.flatMap(\.photos)
            let fingerprint = photos.map(\.id).sorted().joined(separator: "|")
            let titlePrefix = key.reference ? "Notes and records" : "Everyday life"
            var dateParts = DateComponents(); dateParts.year = key.year; dateParts.month = key.month; dateParts.day = 1
            let period = calendar.date(from: dateParts)?.formatted(.dateTime.month(.wide).year())
                ?? "\(key.year)-\(key.month)"
            let narrative = MomentNarrative(version: MomentNarrative.version,
                headline: "\(titlePrefix) at \(place.label) in \(period)", deck: nil, story: nil,
                place: place.label, date: period, confidence: 1,
                provenance: ["habitual place", key.reference ? "reference capture" : "sparse everyday capture"],
                state: .automatic)
            output.append(PhotoMoment(id: "routine-" + MomentContinuity.digest(Data(fingerprint.utf8)),
                start: ordered.first!.start, end: ordered.last!.end, photos: photos,
                selection: combinedSelection(ordered), narrative: narrative,
                groupingSource: algorithmVersion,
                groupingReason: "Sparse captures at the same habitual place were collected within one calendar month. Exact photo dates are preserved.",
                groupingState: .conservative,
                displayEvidence: ordered.reduce(into: [:]) { result, moment in
                    result.merge(moment.displayEvidence ?? [:]) { current, _ in current }
                }))
        }
        return output.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start > $1.start }
    }

    private static func habitualPlace(for moment: PhotoMoment, places: [MeaningfulPlace]) -> MeaningfulPlace? {
        let photo = moment.photos[0]
        if EvidenceGrouping.validGPS(photo) {
            let location = CLLocation(latitude: photo.latitude!, longitude: photo.longitude!)
            return places.compactMap { place -> (MeaningfulPlace, Double)? in
                let distance = location.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
                return distance <= max(place.radius, 750) ? (place, distance) : nil
            }.min { $0.1 < $1.1 }?.0
        }
        guard let named = moment.narrative?.place else { return nil }
        return places.first { $0.label.compare(named, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    private static func combinedSelection(_ moments: [PhotoMoment]) -> MomentSelection? {
        let selections = moments.compactMap(\.selection)
        guard !selections.isEmpty else { return nil }
        var explanations: [String: String] = [:]
        for selection in selections { explanations.merge(selection.explanations) { current, _ in current } }
        return MomentSelection(selected: selections.flatMap(\.selected), pending: selections.flatMap(\.pending),
            similar: selections.flatMap(\.similar), explanations: explanations,
            alternatives: selections.flatMap(\.alternatives), contextOnly: selections.flatMap { $0.contextOnly ?? [] })
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
            if calendar.isDate(moment.start, inSameDayAs: moment.end) {
                momentsByDay[calendar.startOfDay(for: moment.start), default: 0] += 1
            } else {
                crossDay += 1
            }
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

struct CurationRebuildPreview: Identifiable, Equatable, Sendable {
    let generationID: String
    let comparison: CurationGenerationComparison
    var id: String { generationID }
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

enum StoryKind: String, Codable, Equatable, Sendable { case journey, outing }

enum JourneyTransportMode: String, Codable, Equatable, Sendable { case air, overland, unknown }

struct JourneyLegEvidence: Codable, Equatable, Sendable {
    let mode: JourneyTransportMode
    let distanceMeters: Double
    let elapsedSeconds: TimeInterval
    let confidence: Double
    var localSupport: JourneyLocalTransportSupport? = nil
}

struct JourneyLocalTransportSupport: Codable, Equatable, Sendable {
    var inspectedPhotos = 0
    var airPhotos = 0
    var overlandPhotos = 0

    mutating func inspect(labels: [String], lines: [PhotoTextLine]) {
        inspectedPhotos += 1
        let labels = Set(labels.map { $0.lowercased() })
        let text = lines.filter { $0.confidence >= 0.8 }.map { $0.text.lowercased() }
        let airVisual = !labels.isDisjoint(with: ["airplane", "aircraft", "airport"])
        let landVisual = !labels.isDisjoint(with: ["car", "vehicle", "train", "railway", "highway"])
        if airVisual && text.contains(where: { $0.contains("boarding pass") || $0.contains("boarding gate") }) {
            airPhotos += 1
        }
        if landVisual && text.contains(where: { $0.contains("railway station") || $0.contains("train ticket") || $0.contains("motorway") || $0.contains("autoroute") }) {
            overlandPhotos += 1
        }
    }

    func applying(to leg: JourneyLegEvidence) -> JourneyLegEvidence {
        // Recompute from the geometric baseline so retries cannot compound confidence.
        let baseline: Double = leg.mode == .air ? 0.8 : leg.mode == .overland ? 0.65 : 0.25
        let supports = leg.mode == .air ? airPhotos >= 2 && overlandPhotos == 0
            : leg.mode == .overland && overlandPhotos >= 2 && airPhotos == 0
        return JourneyLegEvidence(mode: leg.mode, distanceMeters: leg.distanceMeters,
            elapsedSeconds: leg.elapsedSeconds, confidence: baseline + (supports ? 0.1 : 0),
            localSupport: self)
    }
}

struct JourneyStopEvidence: Codable, Equatable, Sendable {
    let start: Date
    let end: Date
    let latitude: Double
    let longitude: Double
    let momentCount: Int
    let photoCount: Int
    let place: String?
    let confidence: Double
    let transportFromPrevious: JourneyLegEvidence?

    init(start: Date, end: Date, latitude: Double, longitude: Double, momentCount: Int,
         photoCount: Int, place: String?, confidence: Double,
         transportFromPrevious: JourneyLegEvidence? = nil) {
        self.start = start; self.end = end
        self.latitude = latitude; self.longitude = longitude
        self.momentCount = momentCount; self.photoCount = photoCount
        self.place = place; self.confidence = confidence
        self.transportFromPrevious = transportFromPrevious
    }
}

enum JourneyTransportInference {
    static func applying(to stops: [JourneyStopEvidence]) -> [JourneyStopEvidence] {
        stops.enumerated().map { index, stop in
            guard index > 0 else { return stop }
            let previous = stops[index - 1]
            let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: stop.latitude, longitude: stop.longitude))
            let elapsed = max(0, stop.start.timeIntervalSince(previous.end))
            let speed = elapsed > 0 ? distance / elapsed * 3.6 : 0
            let leg: JourneyLegEvidence
            if distance >= 400_000, elapsed >= 30 * 60, elapsed <= 12 * 3600,
               speed >= 180, speed <= 1_100 {
                leg = .init(mode: .air, distanceMeters: distance, elapsedSeconds: elapsed, confidence: 0.8)
            } else if distance >= 20_000, elapsed >= 10 * 60, elapsed <= 36 * 3600, speed <= 160 {
                leg = .init(mode: .overland, distanceMeters: distance, elapsedSeconds: elapsed, confidence: 0.65)
            } else {
                leg = .init(mode: .unknown, distanceMeters: distance, elapsedSeconds: elapsed, confidence: 0.25)
            }
            return JourneyStopEvidence(start: stop.start, end: stop.end,
                latitude: stop.latitude, longitude: stop.longitude,
                momentCount: stop.momentCount, photoCount: stop.photoCount,
                place: stop.place, confidence: stop.confidence, transportFromPrevious: leg)
        }
    }
}

struct CurationStory: Equatable, Sendable, Identifiable {
    let id: String
    let start: Date
    let end: Date
    let momentIDs: [String]
    let placeID: String
    let kind: StoryKind
    let stops: [JourneyStopEvidence]
}

enum ConservativeStoryBuilder {
    /// Stories are optional navigation parents. A repeated non-routine place may anchor a
    /// continuous trip and include intervening excursions; density alone is never evidence.
    static func stories(_ moments: [PhotoMoment], calendar: Calendar = .current,
                        routinePlaceIDs: Set<String> = ["home", "work"],
                        placeID: (PhotoMoment) -> String?) -> [CurationStory] {
        let ordered = moments.sorted { $0.start < $1.start }
        let located = ordered.compactMap { moment -> (PhotoMoment, String, String)? in
            guard let place = placeID(moment)?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty else {
                return nil
            }
            // Story scope is broader than Moment scope: city districts belong to the same visit.
            let storyPlace = place.split(separator: ",").last.map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }.flatMap { $0.isEmpty ? nil : $0 } ?? place
            let key = storyPlace.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return (moment, storyPlace, key)
        }
        let byPlace = Dictionary(grouping: located, by: { $0.2 })
        let inferredRoutine = Set(byPlace.compactMap { key, values -> String? in
            let days = Set(values.map { calendar.startOfDay(for: $0.0.start) }).count
            let months = Set(values.map { calendar.dateComponents([.year, .month], from: $0.0.start) }).count
            return days >= 15 || months >= 3 ? key : nil
        })
        var candidates: [(story: CurationStory, anchorCount: Int)] = []

        for (key, values) in byPlace where !routinePlaceIDs.contains(key) && !inferredRoutine.contains(key) {
            let anchors = values.sorted { $0.0.start < $1.0.start }
            var batches: [[(PhotoMoment, String, String)]] = []
            for anchor in anchors {
                if let previous = batches.last?.last,
                   anchor.0.start.timeIntervalSince(previous.0.end) <= 72 * 3600,
                   anchor.0.start.timeIntervalSince(batches.last!.first!.0.start) <= 14 * 86_400 {
                    batches[batches.count - 1].append(anchor)
                } else {
                    batches.append([anchor])
                }
            }
            for batch in batches where batch.count >= 2 {
                let days = Set(batch.map { calendar.startOfDay(for: $0.0.start) }).count
                let sameDayOuting = days == 1
                    && batch.last!.0.end.timeIntervalSince(batch.first!.0.start) <= 12 * 3600
                guard days >= 2 || sameDayOuting else { continue }
                let first = batch.first!.0, last = batch.last!.0
                let members = days >= 2
                    ? ordered.filter { $0.start >= first.start.addingTimeInterval(-86_400)
                        && $0.start <= last.end.addingTimeInterval(86_400) }
                    : batch.map(\.0)
                let place = batch[0].1
                let momentIDs = members.map(\.id)
                let fingerprint = place + "|" + momentIDs.joined(separator: "|")
                candidates.append((CurationStory(
                    id: "story-" + MomentContinuity.digest(Data(fingerprint.utf8)),
                    start: members.first!.start, end: members.last!.end,
                    momentIDs: momentIDs, placeID: place, kind: .outing, stops: []), batch.count))
            }
        }

        var claimed = Set<String>(), result: [CurationStory] = []
        for candidate in candidates.sorted(by: {
            ($0.anchorCount, $0.story.momentIDs.count) > ($1.anchorCount, $1.story.momentIDs.count)
        }) where claimed.isDisjoint(with: candidate.story.momentIDs) {
            let momentIDs = candidate.story.momentIDs
            let place = candidate.story.placeID
            let fingerprint = place + "|" + momentIDs.joined(separator: "|")
            result.append(CurationStory(id: "story-" + MomentContinuity.digest(Data(fingerprint.utf8)),
                start: candidate.story.start, end: candidate.story.end,
                momentIDs: momentIDs, placeID: place, kind: .outing, stops: []))
            claimed.formUnion(momentIDs)
        }
        return result.sorted { $0.start > $1.start }
    }
}

enum JourneyStoryBuilder {
    static func title(homeLabel: String, stops: [JourneyStopEvidence]) -> String {
        // Prefer destinations with more photo support. Secondary Home places and street
        // labels never name the Journey (a 1-photo "Home in Ukraine" ping must not beat
        // a Bucharest stay that still has only street place IDs).
        let labels = stops.sorted { $0.photoCount > $1.photoCount }.compactMap { stop -> String? in
            guard let label = stop.place else { return nil }
            let trimmed = label.split(separator: ",").last.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? label
            guard !trimmed.isEmpty,
                  trimmed.compare(homeLabel, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame,
                  !isSecondaryHomeLabel(trimmed, primaryHome: homeLabel),
                  !PlaceNaming.looksStreetLevel(trimmed) else { return nil }
            return trimmed
        }
            .reduce(into: [String]()) { result, label in
                if !result.contains(where: { existing in
                    existing.compare(label, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }) {
                    result.append(label)
                }
            }
        // Journey kind always uses Journey wording. "Trip to" was confused with day outings.
        switch labels.count {
        case 1: return "Journey to \(labels[0])"
        case 2: return "Journey to \(labels[0]) and \(labels[1])"
        case 3...: return "Journey via \(labels[0]), \(labels[1]), and \(labels[2])"
        default: return "Journey from \(homeLabel)"
        }
    }

    /// Secondary residences (`Home in Ukraine`) are waypoints, not Journey destinations.
    static func isSecondaryHomeLabel(_ label: String, primaryHome: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.compare(primaryHome, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return true
        }
        let lower = trimmed.lowercased()
        return lower == "home" || lower.hasPrefix("home ") || lower.hasPrefix("home\u{00a0}")
    }

    /// Builds only closed home-to-home journeys. Open or weak sequences fall back to place Stories.
    static func stories(_ moments: [PhotoMoment], home: MeaningfulPlace,
                        coordinate: (PhotoMoment) -> CLLocationCoordinate2D?,
                        placeID: (PhotoMoment) -> String?,
                        support: (PhotoMoment) -> Int = { $0.photos.count }) -> [CurationStory] {
        let ordered = moments.sorted { $0.start < $1.start }
        var suppressed = Set<String>()
        for (index, lhs) in ordered.enumerated() {
            guard let left = coordinate(lhs) else { continue }
            for rhs in ordered.dropFirst(index + 1) {
                guard rhs.start.timeIntervalSince(lhs.end) <= 4 * 3600 else { break }
                guard let right = coordinate(rhs),
                      CLLocation(latitude: left.latitude, longitude: left.longitude).distance(
                        from: CLLocation(latitude: right.latitude, longitude: right.longitude)) >= 250_000
                else { continue }
                let leftSupport = max(1, support(lhs)), rightSupport = max(1, support(rhs))
                if leftSupport >= rightSupport * 2 { suppressed.insert(rhs.id) }
                else if rightSupport >= leftSupport * 2 { suppressed.insert(lhs.id) }
            }
        }
        func resolvedPoint(_ moment: PhotoMoment) -> CLLocationCoordinate2D? {
            suppressed.contains(moment.id) ? nil : coordinate(moment)
        }
        var active: [PhotoMoment] = [], locatedAway = 0, distantAway = 0
        var results: [CurationStory] = []

        func isHome(_ coordinate: CLLocationCoordinate2D) -> Bool {
            home.contains(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
        func finish() {
            defer { active = []; locatedAway = 0; distantAway = 0 }
            let distant = active.indices.filter { index in
                guard let point = resolvedPoint(active[index]) else { return false }
                return CLLocation(latitude: home.latitude, longitude: home.longitude).distance(
                    from: CLLocation(latitude: point.latitude, longitude: point.longitude)) >= 50_000
            }
            guard locatedAway >= 2, distantAway >= 2, let firstDistant = distant.first,
                  let lastDistant = distant.last else { return }
            let firstTime = active[firstDistant].start.addingTimeInterval(-86_400)
            let lastTime = active[lastDistant].end.addingTimeInterval(86_400)
            let members = active.filter { $0.end >= firstTime && $0.start <= lastTime }
            guard let first = members.first, let last = members.last,
                  last.end.timeIntervalSince(first.start) >= 36 * 3600 else { return }
            var stops: [JourneyStopEvidence] = []
            for member in members {
                guard let location = resolvedPoint(member), !isHome(location) else { continue }
                let count = max(1, support(member))
                if let previous = stops.last,
                   CLLocation(latitude: previous.latitude, longitude: previous.longitude).distance(
                    from: CLLocation(latitude: location.latitude, longitude: location.longitude)) < 30_000 {
                    let total = previous.photoCount + count
                    stops[stops.count - 1] = JourneyStopEvidence(start: previous.start, end: member.end,
                        latitude: (previous.latitude * Double(previous.photoCount) + location.latitude * Double(count)) / Double(total),
                        longitude: (previous.longitude * Double(previous.photoCount) + location.longitude * Double(count)) / Double(total),
                        momentCount: previous.momentCount + 1, photoCount: total,
                        place: previous.place ?? placeID(member), confidence: total >= 5 ? 1 : 0.7)
                } else {
                    stops.append(JourneyStopEvidence(start: member.start, end: member.end,
                        latitude: location.latitude, longitude: location.longitude,
                        momentCount: 1, photoCount: count, place: placeID(member),
                        confidence: count >= 5 ? 1 : 0.6))
                }
            }
            let title = title(homeLabel: home.label, stops: stops)
            stops = JourneyTransportInference.applying(to: stops)
            let ids = members.map(\.id)
            let fingerprint = "journey|" + ids.joined(separator: "|")
            results.append(CurationStory(id: "story-" + MomentContinuity.digest(Data(fingerprint.utf8)),
                start: first.start, end: last.end, momentIDs: ids, placeID: title,
                kind: .journey, stops: stops))
        }

        var sawHome = false
        for (index, moment) in ordered.enumerated() {
            if let location = resolvedPoint(moment) {
                if isHome(location) {
                    let nearFutureAway = ordered.dropFirst(index + 1).prefix { candidate in
                        candidate.start.timeIntervalSince(moment.end) <= 86_400
                    }.contains { candidate in
                        guard let location = resolvedPoint(candidate) else { return false }
                        return CLLocation(latitude: home.latitude, longitude: home.longitude).distance(
                            from: CLLocation(latitude: location.latitude, longitude: location.longitude)) >= 50_000
                    }
                    if !active.isEmpty, !nearFutureAway { finish() }
                    sawHome = true
                    continue
                }
                guard sawHome else { continue }
                let distance = CLLocation(latitude: home.latitude, longitude: home.longitude)
                    .distance(from: CLLocation(latitude: location.latitude, longitude: location.longitude))
                if !active.isEmpty, moment.start.timeIntervalSince(active.last!.end) > 7 * 86_400 {
                    finish()
                }
                active.append(moment); locatedAway += 1
                if distance >= 50_000 { distantAway += 1 }
            } else if !active.isEmpty {
                active.append(moment)
            }
        }
        return results.sorted { $0.start > $1.start }
    }
}

enum StoryHierarchyBuilder {
    static func stories(_ moments: [PhotoMoment], home: MeaningfulPlace?, calendar: Calendar = .current,
                        coordinate: (PhotoMoment) -> CLLocationCoordinate2D?,
                        placeID: (PhotoMoment) -> String?,
                        support: (PhotoMoment) -> Int = { $0.photos.count }) -> [CurationStory] {
        let journeys = home.map {
            JourneyStoryBuilder.stories(moments, home: $0, coordinate: coordinate,
                placeID: placeID, support: support)
        } ?? []
        let claimed = Set(journeys.flatMap(\.momentIDs))
        let outings = ConservativeStoryBuilder.stories(moments, calendar: calendar, placeID: placeID)
            .filter { claimed.isDisjoint(with: $0.momentIDs) }
        return (journeys + outings).sorted { $0.start > $1.start }
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
