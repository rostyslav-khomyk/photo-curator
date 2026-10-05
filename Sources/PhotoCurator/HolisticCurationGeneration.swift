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
        AdaptiveDayCadence.thresholds(photos, calendar: calendar)
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

    /// Vision labels that support an air geometric candidate (AND with OCR phrases).
    static let airLabels: Set<String> = ["airplane", "aircraft", "airport", "jet"]
    /// Vision labels that support an overland geometric candidate (car/rail/ferry/bus).
    static let overlandLabels: Set<String> = [
        "car", "vehicle", "train", "railway", "highway", "bus", "subway", "metro",
        "ferry", "boat", "tram", "ship"
    ]
    static let airPhrases = [
        "boarding pass", "boarding gate", "boardingkaart", "carte d'embarquement", "bordkarte",
        "e-ticket", "eticket", "baggage claim", "gate open", "departure gate", "boarding"
    ]
    static let overlandPhrases = [
        "railway station", "train ticket", "motorway", "autoroute", "autobahn", "platform",
        "bahnhof", "gare", "treinkaartje", "eurostar", "ferry", "veerdienst", "péage", "peage",
        "toll booth", "boot ticket"
    ]

    mutating func inspect(labels: [String], lines: [PhotoTextLine]) {
        inspectedPhotos += 1
        let labels = Set(labels.map { $0.lowercased() })
        let text = lines.filter { $0.confidence >= 0.8 }.map { $0.text.lowercased() }
        let airVisual = !labels.isDisjoint(with: Self.airLabels)
        let landVisual = !labels.isDisjoint(with: Self.overlandLabels)
        if airVisual && text.contains(where: { line in Self.airPhrases.contains(where: { line.contains($0) }) }) {
            airPhotos += 1
        }
        if landVisual && text.contains(where: { line in Self.overlandPhrases.contains(where: { line.contains($0) }) }) {
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

/// Drops messenger/GPS junk that kinks a Journey (mid-ocean pins, mid-route Home
/// anchors from the other phone, weak detours between two real stays).
enum JourneyStopSanitizer {
    /// A→outlier→B is discarded when the detour is much longer than A→B and the outlier is weak.
    static let maxDetourRatio = 2.5
    static let outlierPhotoShare = 0.35
    static let minDirectMeters: CLLocationDistance = 80_000

    static func removingRouteNoise(_ stops: [JourneyStopEvidence],
                                   homes: [MeaningfulPlace],
                                   homeLabel: String = "Home") -> [JourneyStopEvidence] {
        guard stops.count >= 2 else { return stops }
        // Fake “Home” labels that are not near a mapped residence.
        var kept = stops.filter { stop in
            guard let place = stop.place,
                  JourneyStoryBuilder.isSecondaryHomeLabel(place, primaryHome: homeLabel) else {
                return true
            }
            // Merge/rebuild without Homes still keeps endpoints; interior strip drops mid-route.
            if homes.isEmpty { return true }
            return nearHome(stop, homes: homes)
        }
        // Mid-journey Home pins from a parallel household phone — keep only first/last Home.
        kept = strippingInteriorHomes(kept, homeLabel: homeLabel)
        var changed = true
        while changed, kept.count >= 3 {
            changed = false
            var next: [JourneyStopEvidence] = [kept[0]]
            var index = 1
            while index < kept.count - 1 {
                let previous = next[next.count - 1]
                let candidate = kept[index]
                let following = kept[index + 1]
                if isDetourOutlier(previous: previous, outlier: candidate, following: following) {
                    changed = true
                    index += 1
                    continue
                }
                next.append(candidate)
                index += 1
            }
            next.append(kept[kept.count - 1])
            kept = next
        }
        kept = mergingNearbyStops(kept)
        kept = strippingInteriorForest(kept)
        return strippingInteriorTransit(kept)
    }

    /// Stanicki Las: 99 photos in a forest between Ukraine Home and Berlin is not a
    /// civil-airport hop. Drop interior forest pins that are not next to a passenger airport.
    private static func strippingInteriorForest(_ stops: [JourneyStopEvidence]) -> [JourneyStopEvidence] {
        guard stops.count >= 3 else { return stops }
        return stops.enumerated().compactMap { index, stop in
            if index == 0 || index == stops.count - 1 { return stop }
            if PlaceNaming.looksAirport(stop.place)
                || PlaceNaming.CivilAirports.near(latitude: stop.latitude, longitude: stop.longitude) {
                return stop
            }
            guard PlaceNaming.looksForest(stop.place) else { return stop }
            let richBefore = stops[..<index].contains { isForestAnchor($0) }
            let richAfter = stops[(index + 1)...].contains { isForestAnchor($0) }
            return richBefore && richAfter ? nil : stop
        }
    }

    /// Motel / petrol / A7 snaps between two real stays. Owner France 2026: Meyreuil 4
    /// photos and Bollène 2 photos sat on the drive from Sainte-Maxime to Reims; the
    /// overnight was around Mâcon with no GPS, and must not become titled stops.
    static let transitMaxPhotos = 4
    static let substantialStayPhotos = 20
    /// Hub / arrival airports (DTW, ATL) are 1–2 photos but still real route vertices.
    static let airConnectionMeters: CLLocationDistance = 400_000
    static let arrivalAirportSeparationMeters: CLLocationDistance = 80_000

    private static func strippingInteriorTransit(_ stops: [JourneyStopEvidence]) -> [JourneyStopEvidence] {
        guard stops.count >= 3 else { return stops }
        return stops.enumerated().compactMap { index, stop in
            if index == 0 || index == stops.count - 1 { return stop }
            if isAirConnection(in: stops, index: index) { return stop }
            if let place = stop.place,
               JourneyStoryBuilder.isSecondaryHomeLabel(place, primaryHome: "Home"),
               !JourneyStoryBuilder.isPrimaryHomeLabel(place, primaryHome: "Home") {
                return stop
            }
            if isBriefDepartureNoise(in: stops, index: index) { return nil }
            let highway = PlaceNaming.looksHighwayOrTransitPin(stop.place)
            if highway && stop.photoCount < substantialStayPhotos { return nil }
            guard stop.photoCount <= transitMaxPhotos else { return stop }
            let richBefore = stops[..<index].contains { isSubstantialStay($0) }
            let richAfter = stops[(index + 1)...].contains { isSubstantialStay($0) }
            return richBefore && richAfter ? nil : stop
        }
    }

    /// Steigra: 13 photos / 1 h in Germany on the afternoon you flew to Rhodes.
    /// Not an airport, not a stay — drop. Schiphol stays (Home-orbit airport).
    private static func isBriefDepartureNoise(in stops: [JourneyStopEvidence], index: Int) -> Bool {
        guard stops.indices.contains(index) else { return false }
        let stop = stops[index]
        guard stop.photoCount < substantialStayPhotos,
              stop.end.timeIntervalSince(stop.start) <= 4 * 3600,
              !PlaceNaming.looksAirport(stop.place) else { return false }
        guard let previous = stops[..<index].last(where: { isSubstantialStay($0) }),
              let next = stops[(index + 1)...].first(where: { isSubstantialStay($0) }) else {
            return false
        }
        guard JourneyStoryBuilder.isSecondaryHomeLabel(previous.place ?? "", primaryHome: "Home") else {
            return false
        }
        func distance(_ a: JourneyStopEvidence, _ b: JourneyStopEvidence) -> CLLocationDistance {
            CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }
        // Next hop must be a flight (Steigra → Rhodes). A same-day German
        // lunch stop on a drive to Bavaria (Neustadt → Bad Wiessee ~450 km) stays.
        return distance(previous, stop) >= JourneyStoryBuilder.localOrbitMeters
            && distance(stop, next) >= JourneyTransportInference.intercontinentalAirMeters
    }

    /// Detroit after Home, Atlanta between Michigan and Panama: keep. Meyreuil between
    /// Sainte-Maxime and Reims: drop (short road side).
    static func isAirConnection(in stops: [JourneyStopEvidence], index: Int) -> Bool {
        guard stops.indices.contains(index) else { return false }
        let stop = stops[index]
        func distance(_ a: JourneyStopEvidence, _ b: JourneyStopEvidence) -> CLLocationDistance {
            CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }
        if let previous = stops[..<index].last(where: { isSubstantialStay($0) }),
           let next = stops[(index + 1)...].first(where: { isSubstantialStay($0) }) {
            let left = distance(previous, stop)
            let right = distance(stop, next)
            let previousIsHome = JourneyStoryBuilder.isSecondaryHomeLabel(previous.place ?? "", primaryHome: "Home")
            let nextIsHome = JourneyStoryBuilder.isSecondaryHomeLabel(next.place ?? "", primaryHome: "Home")
            // Schiphol is 25 km from Home — still the departure airport before Barcelona.
            if previousIsHome && right >= airConnectionMeters
                && left < JourneyStoryBuilder.localOrbitMeters {
                return true
            }
            // Thin Berlin before Home after Viechtach (~370 km) is the flight city.
            // A 14-photo Berlin stay on the 2018 Ukraine drive is not a hub.
            if stop.photoCount <= transitMaxPhotos,
               JourneyRegionNames.isBerlinMetro(latitude: stop.latitude, longitude: stop.longitude),
               (previousIsHome && left >= airConnectionMeters)
                || (nextIsHome && right >= airConnectionMeters) {
                return true
            }
            // Paris/Barcelona are real stays, not hubs, even with Home on both sides.
            guard stop.photoCount <= transitMaxPhotos || PlaceNaming.looksAirport(stop.place) else {
                return false
            }
            if left >= airConnectionMeters && right >= airConnectionMeters { return true }
            if previousIsHome && right >= arrivalAirportSeparationMeters && left >= airConnectionMeters {
                return true
            }
        }
        return false
    }

    private static func isSubstantialStay(_ stop: JourneyStopEvidence) -> Bool {
        stop.photoCount >= substantialStayPhotos
            || JourneyStoryBuilder.isSecondaryHomeLabel(stop.place ?? "", primaryHome: "Home")
    }

    private static func isForestAnchor(_ stop: JourneyStopEvidence) -> Bool {
        guard !PlaceNaming.looksForest(stop.place) else { return false }
        return isSubstantialStay(stop)
            || JourneyRegionNames.isBerlinMetro(latitude: stop.latitude, longitude: stop.longitude)
            || PlaceNaming.looksAirport(stop.place)
            || PlaceNaming.CivilAirports.near(latitude: stop.latitude, longitude: stop.longitude)
    }

    /// After dropping junk, fold consecutive stays that are the same place (two Panama City
    /// pins a few km apart left a meaningless 2 km “leg”).
    private static func mergingNearbyStops(_ stops: [JourneyStopEvidence]) -> [JourneyStopEvidence] {
        guard let first = stops.first else { return stops }
        var result = [first]
        for stop in stops.dropFirst() {
            let previous = result[result.count - 1]
            let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: stop.latitude, longitude: stop.longitude))
            if distance < 30_000 {
                let previousHome = JourneyStoryBuilder.isSecondaryHomeLabel(previous.place ?? "", primaryHome: "Home")
                let nextHome = JourneyStoryBuilder.isSecondaryHomeLabel(stop.place ?? "", primaryHome: "Home")
                if previousHome != nextHome {
                    result.append(stop)
                    continue
                }
                let total = max(1, previous.photoCount + stop.photoCount)
                result[result.count - 1] = JourneyStopEvidence(
                    start: min(previous.start, stop.start),
                    end: max(previous.end, stop.end),
                    latitude: (previous.latitude * Double(previous.photoCount)
                               + stop.latitude * Double(stop.photoCount)) / Double(total),
                    longitude: (previous.longitude * Double(previous.photoCount)
                                + stop.longitude * Double(stop.photoCount)) / Double(total),
                    momentCount: previous.momentCount + stop.momentCount,
                    photoCount: total,
                    place: previous.place ?? stop.place,
                    confidence: max(previous.confidence, stop.confidence),
                    transportFromPrevious: previous.transportFromPrevious)
            } else {
                result.append(stop)
            }
        }
        return result
    }

    /// Home is a trip endpoint, not a waypoint. Merging two Journeys otherwise draws
    /// Home → Michigan → Home → Panama as if the traveler flew home between legs.
    private static func strippingInteriorHomes(_ stops: [JourneyStopEvidence],
                                               homeLabel: String) -> [JourneyStopEvidence] {
        guard stops.count >= 3 else { return stops }
        return stops.enumerated().compactMap { index, stop in
            if index == 0 || index == stops.count - 1 { return stop }
            guard let place = stop.place,
                  JourneyStoryBuilder.isSecondaryHomeLabel(place, primaryHome: homeLabel) else {
                return stop
            }
            // Drop interior *primary* Home (NL household / other-phone). Keep a
            // second residence (Home in Ukraine) as a real stay on a road circuit.
            if JourneyStoryBuilder.isPrimaryHomeLabel(place, primaryHome: homeLabel) {
                return nil
            }
            return stop
        }
    }

    private static func nearHome(_ stop: JourneyStopEvidence, homes: [MeaningfulPlace]) -> Bool {
        homes.contains { home in
            home.contains(latitude: stop.latitude, longitude: stop.longitude)
                || CLLocation(latitude: home.latitude, longitude: home.longitude).distance(
                    from: CLLocation(latitude: stop.latitude, longitude: stop.longitude))
                    < JourneyStoryBuilder.localOrbitMeters
        }
    }

    private static func isDetourOutlier(previous: JourneyStopEvidence,
                                        outlier: JourneyStopEvidence,
                                        following: JourneyStopEvidence) -> Bool {
        let left = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
        let mid = CLLocation(latitude: outlier.latitude, longitude: outlier.longitude)
        let right = CLLocation(latitude: following.latitude, longitude: following.longitude)
        let direct = left.distance(from: right)
        let via = left.distance(from: mid) + mid.distance(from: right)
        // Nearby A→B with a far mid pin (messenger mid-ocean between two Panama City days)
        // must still count as a kink — do not require A→B itself to be a long leg.
        let baseline = max(direct, minDirectMeters / 8) // ≥10 km floor
        guard via > maxDetourRatio * baseline else { return false }
        // A 50-photo drive to Gorzów between two Berlin-area days is a real excursion,
        // not a messenger kink (May 2016).
        if isSubstantialStay(outlier) { return false }
        let neighbor = max(previous.photoCount, following.photoCount)
        return outlier.photoCount < max(1, Int(Double(neighbor) * outlierPhotoShare))
            || outlier.momentCount <= 1
    }
}

enum JourneyTransportInference {
    /// Multi-day gap on ocean/intercontinental legs still counts as air — photos rarely
    /// capture the flight itself. European road hops (Home → Fontainebleau ~400 km with
    /// overnight stops) must NOT use this path.
    static let airGapCeilingSeconds: TimeInterval = 5 * 86_400
    static let intercontinentalAirMeters: CLLocationDistance = 2_000_000
    /// California → Lviv can sit 3 weeks after the last Bay Area photo (Dec 2013).
    static let intercontinentalHomeGapSeconds: TimeInterval = 28 * 86_400

    static func applying(to stops: [JourneyStopEvidence]) -> [JourneyStopEvidence] {
        stops.enumerated().map { index, stop in
            guard index > 0 else { return stop }
            let previous = stops[index - 1]
            let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: stop.latitude, longitude: stop.longitude))
            let elapsed = max(0, stop.start.timeIntervalSince(previous.end))
            let speed = elapsed > 0 ? distance / elapsed * 3.6 : 0
            let leg: JourneyLegEvidence
            if isIrelandOrUKHomeHop(previous, stop, distance: distance)
                || isHomeBoundLongHop(previous: previous, next: stop, distance: distance,
                                      elapsed: elapsed, speed: speed, route: stops)
                || isCompactBerlinHomeHop(previous, stop, distance: distance,
                                         elapsed: elapsed, route: stops)
                || isMunichHomeHop(previous, stop, distance: distance, route: stops) {
                // Island hops, Home ↔ Spain/Romania/Ivano ≥1,000 km, flight-shaped
                // Home ↔ Berlin, and Lviv ↔ Munich when the US is on the route.
                let island = isIrelandOrUKHomeHop(previous, stop, distance: distance)
                let berlin = isCompactBerlinHomeHop(previous, stop, distance: distance,
                                                    elapsed: elapsed, route: stops)
                let munich = isMunichHomeHop(previous, stop, distance: distance, route: stops)
                leg = .init(mode: .air, distanceMeters: distance, elapsedSeconds: elapsed,
                            confidence: island || berlin || munich ? 0.75 : 0.5)
            } else if distance >= 400_000, elapsed >= 30 * 60, elapsed <= 12 * 3600,
               speed >= 180, speed <= 1_100,
               awayEndPlausibleForAir(previous, stop) {
                // Fast hops still need a civil airport / Berlin metro on the away end.
                // Stanicki Las is a forest, not a passenger airport.
                leg = .init(mode: .air, distanceMeters: distance, elapsedSeconds: elapsed, confidence: 0.8)
            } else if distance >= 20_000, distance < homeBoundAirMeters,
                      elapsed >= 10 * 60, elapsed <= 36 * 3600, speed <= 160 {
                // 1,200 km Barcelona → Home in 18 h looks like a long drive by speed,
                // but the owner flew (Spain Feb 2026). Keep overland under 1,000 km.
                leg = .init(mode: .overland, distanceMeters: distance, elapsedSeconds: elapsed, confidence: 0.65)
            } else if homeAndAway(previous, stop), distance >= 20_000, distance < homeBoundAirMeters,
                      elapsed >= 10 * 60, elapsed <= homeBoundAirGapSeconds, speed <= 160 {
                // Pampelonne → Home 986 km six days later is still the France drive home.
                leg = .init(mode: .overland, distanceMeters: distance, elapsedSeconds: elapsed, confidence: 0.6)
            } else if bothMappedHomes(previous, stop) || isUkraineRoadHop(previous, stop, route: stops),
                      distance >= 20_000,
                      elapsed >= 10 * 60, elapsed <= homeBoundAirGapSeconds, speed <= 160 {
                // NL Home ↔ Home in Ukraine / Pylypets on a second-home circuit is a drive.
                leg = .init(mode: .overland, distanceMeters: distance, elapsedSeconds: elapsed, confidence: 0.6)
            } else if distance >= intercontinentalAirMeters, elapsed >= 30 * 60,
                      elapsed <= intercontinentalHomeGapSeconds, speed <= 1_100 {
                // Panama → Home, Bay Area ↔ Austin the same day, or California →
                // Home in Ukraine 5–6 days later. Not NL → Fontainebleau by car.
                leg = .init(mode: .air, distanceMeters: distance, elapsedSeconds: elapsed, confidence: 0.55)
            } else if distance >= 20_000, distance < homeBoundAirMeters,
                      elapsed <= homeBoundAirGapSeconds, speed <= 160 {
                // Lyon → Pampelonne over a quiet week is still the France road trip.
                leg = .init(mode: .overland, distanceMeters: distance, elapsedSeconds: elapsed, confidence: 0.55)
            } else if distance >= 20_000, elapsed <= airGapCeilingSeconds, speed <= 160 {
                // Multi-day road trip with overnight gaps (Summer holidays in France).
                leg = .init(mode: .overland, distanceMeters: distance, elapsedSeconds: elapsed, confidence: 0.55)
            } else if distance >= 20_000, distance < 400_000, speed <= 160 {
                // Redwood City → Monterey after a quiet month is still the California stay.
                leg = .init(mode: .overland, distanceMeters: distance, elapsedSeconds: elapsed, confidence: 0.5)
            } else {
                leg = .init(mode: .unknown, distanceMeters: distance, elapsedSeconds: elapsed, confidence: 0.25)
            }
            return JourneyStopEvidence(start: stop.start, end: stop.end,
                latitude: stop.latitude, longitude: stop.longitude,
                momentCount: stop.momentCount, photoCount: stop.photoCount,
                place: stop.place, confidence: stop.confidence, transportFromPrevious: leg)
        }
    }

    /// Last abroad stop → Home, or Home → first abroad stop, at flight distance with a
    /// quiet week of no photos. Owner Bucharest Jun 2026: flew both ways; Home GPS only
    /// showed up 7 days after the last Romanian photo.
    static let homeBoundAirMeters: CLLocationDistance = 1_000_000
    static let homeBoundAirGapSeconds: TimeInterval = 14 * 86_400

    private static func homeAndAway(_ previous: JourneyStopEvidence, _ next: JourneyStopEvidence) -> Bool {
        let homeish: (String?) -> Bool = { label in
            guard let label else { return false }
            return JourneyStoryBuilder.isSecondaryHomeLabel(label, primaryHome: "Home")
        }
        return homeish(previous.place) != homeish(next.place)
    }

    private static func bothMappedHomes(_ previous: JourneyStopEvidence, _ next: JourneyStopEvidence) -> Bool {
        let homeish: (String?) -> Bool = { label in
            guard let label else { return false }
            return JourneyStoryBuilder.isSecondaryHomeLabel(label, primaryHome: "Home")
        }
        return homeish(previous.place) && homeish(next.place)
    }

    private static func isHomeBoundLongHop(previous: JourneyStopEvidence, next: JourneyStopEvidence,
                                           distance: CLLocationDistance, elapsed: TimeInterval,
                                           speed: Double, route: [JourneyStopEvidence]) -> Bool {
        guard elapsed <= homeBoundAirGapSeconds, speed <= 1_100 else { return false }
        let homeish: (String?) -> Bool = { label in
            guard let label else { return false }
            return JourneyStoryBuilder.isSecondaryHomeLabel(label, primaryHome: "Home")
        }
        guard homeish(previous.place) || homeish(next.place) else { return false }
        // Two residences (NL ↔ Ukraine) are a drive. Bucharest → NL is still air.
        if homeish(previous.place) && homeish(next.place) { return false }
        // Barcelona / Bucharest / Ivano-Frankivsk / Antalya ↔ Home ≥1,000 km
        // is a flight (May 2015; Aug 2014 Turkey from Home in Ukraine).
        // France road hops stay under 1,000 km.
        // A second-home / Carpathian circuit that already visited Home in Ukraine
        // stays a drive (Bukovel, Pylypets).
        if distance >= homeBoundAirMeters {
            return !isUkraineRoadHop(previous, next, route: route)
        }
        guard elapsed > 12 * 3600 else { return false }
        return isIrelandOrUKHomeHop(previous, next, distance: distance)
    }

    /// Owner Ireland Oct 2025 and London Jun 2019: the Channel / Irish Sea hop is a flight,
    /// not a France-style drive, even at 350 km the same afternoon.
    /// Road trips that include Home in Ukraine stay overland. A weekend NL ↔
    /// Ivano-Frankivsk with no second-home stop is a flight (May 2015).
    private static func isUkraineRoadHop(_ previous: JourneyStopEvidence, _ next: JourneyStopEvidence,
                                         route: [JourneyStopEvidence]) -> Bool {
        guard homeAndAway(previous, next) else { return false }
        let homeish: (String?) -> Bool = { label in
            guard let label else { return false }
            return JourneyStoryBuilder.isSecondaryHomeLabel(label, primaryHome: "Home")
        }
        let other = homeish(next.place) ? previous : next
        guard JourneyRegionNames.country(latitude: other.latitude, longitude: other.longitude) == "Ukraine" else {
            return false
        }
        if isMappedUkraineHome(other) { return true }
        // Kyiv is the flight city on a one-way Lviv → Kyiv → NL hop (Nov 2014).
        if JourneyRegionNames.isKyivMetro(latitude: other.latitude, longitude: other.longitude) {
            return false
        }
        return route.contains(where: isMappedUkraineHome)
    }

    private static func isMappedUkraineHome(_ stop: JourneyStopEvidence) -> Bool {
        guard let place = stop.place,
              JourneyStoryBuilder.isSecondaryHomeLabel(place, primaryHome: "Home"),
              !JourneyStoryBuilder.isPrimaryHomeLabel(place, primaryHome: "Home") else {
            return false
        }
        return JourneyRegionNames.country(latitude: stop.latitude, longitude: stop.longitude) == "Ukraine"
            || place.localizedCaseInsensitiveContains("ukraine")
    }

    /// Same-travel-day / thin Berlin bookend: flew NL ↔ Berlin (May 2016 Gorzów,
    /// Jan 2016 Viechtach). A 35-hour Berlin → Home hop with a real Berlin stay
    /// is the June 2015 drive. Assumed departing Home (no GPS) is not flight evidence.
    /// 2018/2019 Ukraine road trips that pass Berlin stay overland.
    /// Ukraine Home → Berlin with no NL bookend is still a flight (Aug 2015).
    static let compactBerlinAirSeconds: TimeInterval = 18 * 3600

    private static func isCompactBerlinHomeHop(_ previous: JourneyStopEvidence, _ next: JourneyStopEvidence,
                                               distance: CLLocationDistance,
                                               elapsed: TimeInterval,
                                               route: [JourneyStopEvidence]) -> Bool {
        guard distance >= 400_000, homeAndAway(previous, next) else { return false }
        let hasUkraine = route.contains {
            JourneyRegionNames.country(latitude: $0.latitude, longitude: $0.longitude) == "Ukraine"
        }
        let hasPrimaryHome = route.contains {
            ($0.place ?? "").compare("Home", options: [.caseInsensitive]) == .orderedSame
        }
        // NL → Berlin → Ukraine is a drive. Ukraine Home → Berlin alone is a flight (2015).
        if hasUkraine && hasPrimaryHome { return false }
        let homeish: (String?) -> Bool = { label in
            guard let label else { return false }
            return JourneyStoryBuilder.isSecondaryHomeLabel(label, primaryHome: "Home")
        }
        let other = homeish(next.place) ? previous : next
        guard JourneyRegionNames.isBerlinMetro(latitude: other.latitude, longitude: other.longitude) else {
            return false
        }
        if hasUkraine && !hasPrimaryHome { return true }
        // Assumed Home start is always ~12 h before the first abroad pin — that
        // is not a measured flight (June 2015 drove, departing GPS missing).
        if previous.confidence < 0.5 || next.confidence < 0.5 { return false }
        if other.photoCount <= JourneyStopSanitizer.transitMaxPhotos { return true }
        return elapsed <= compactBerlinAirSeconds
    }

    private static func isIrelandOrUKHomeHop(_ previous: JourneyStopEvidence, _ next: JourneyStopEvidence,
                                             distance: CLLocationDistance) -> Bool {
        guard distance >= 200_000, homeAndAway(previous, next) else { return false }
        let homeish: (String?) -> Bool = { label in
            guard let label else { return false }
            return JourneyStoryBuilder.isSecondaryHomeLabel(label, primaryHome: "Home")
        }
        let other = homeish(next.place) ? previous : next
        guard let country = JourneyRegionNames.country(latitude: other.latitude, longitude: other.longitude) else {
            return false
        }
        return ["Ireland", "United Kingdom"].contains(country)
    }

    /// Jan 2014: Lviv → Munich → California → Munich → Lviv. Munich is the
    /// transatlantic via — Bukovel is not an ocean airport.
    private static func isMunichHomeHop(_ previous: JourneyStopEvidence, _ next: JourneyStopEvidence,
                                        distance: CLLocationDistance,
                                        route: [JourneyStopEvidence]) -> Bool {
        guard distance >= 400_000, homeAndAway(previous, next) else { return false }
        let homeish: (String?) -> Bool = { label in
            guard let label else { return false }
            return JourneyStoryBuilder.isSecondaryHomeLabel(label, primaryHome: "Home")
        }
        let other = homeish(next.place) ? previous : next
        guard JourneyRegionNames.isMunichMetro(latitude: other.latitude, longitude: other.longitude) else {
            return false
        }
        return route.contains {
            JourneyRegionNames.country(latitude: $0.latitude, longitude: $0.longitude) == "USA"
        }
    }

    /// Fast air still needs a passenger airport on the away end. A forest (Stanicki Las)
    /// between Ukraine Home and Berlin is not one.
    private static func awayEndPlausibleForAir(_ previous: JourneyStopEvidence,
                                               _ next: JourneyStopEvidence) -> Bool {
        let homeish: (String?) -> Bool = { label in
            guard let label else { return false }
            return JourneyStoryBuilder.isSecondaryHomeLabel(label, primaryHome: "Home")
        }
        let other: JourneyStopEvidence
        if homeish(previous.place) != homeish(next.place) {
            other = homeish(next.place) ? previous : next
        } else {
            return plausibleAirEndpoint(previous) && plausibleAirEndpoint(next)
        }
        return plausibleAirEndpoint(other)
    }

    private static func plausibleAirEndpoint(_ stop: JourneyStopEvidence) -> Bool {
        PlaceNaming.looksAirport(stop.place)
            || PlaceNaming.CivilAirports.near(latitude: stop.latitude, longitude: stop.longitude)
            || JourneyRegionNames.isBerlinMetro(latitude: stop.latitude, longitude: stop.longitude)
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

/// Coarse country boxes for Journey titles. A point that hits more than one box stays unnamed
/// so a border city is not given the wrong country.
enum JourneyRegionNames {
    struct Box {
        let name: String
        let minLat: Double
        let maxLat: Double
        let minLon: Double
        let maxLon: Double

        func contains(latitude: Double, longitude: Double) -> Bool {
            latitude >= minLat && latitude <= maxLat && longitude >= minLon && longitude <= maxLon
        }
    }

    static let boxes: [Box] = [
        // minLat stays low for Corsica/Côte d'Azur; overlap with Spain is resolved in country().
        Box(name: "France", minLat: 41.3, maxLat: 51.1, minLon: -5.2, maxLon: 7.45),
        Box(name: "Italy", minLat: 36.6, maxLat: 47.05, minLon: 7.5, maxLon: 18.6),
        Box(name: "Austria", minLat: 46.35, maxLat: 47.99, minLon: 9.55, maxLon: 17.15),
        Box(name: "Germany", minLat: 48.0, maxLat: 55.1, minLon: 5.87, maxLon: 15.03),
        Box(name: "Germany", minLat: 47.27, maxLat: 47.99, minLon: 5.87, maxLon: 9.5),
        Box(name: "Netherlands", minLat: 50.75, maxLat: 53.6, minLon: 3.3, maxLon: 7.22),
        Box(name: "Belgium", minLat: 49.5, maxLat: 51.5, minLon: 2.5, maxLon: 6.4),
        Box(name: "Switzerland", minLat: 45.82, maxLat: 47.81, minLon: 5.96, maxLon: 10.49),
        Box(name: "Spain", minLat: 36.0, maxLat: 43.8, minLon: -9.4, maxLon: 3.3),
        Box(name: "Portugal", minLat: 36.95, maxLat: 42.15, minLon: -9.5, maxLon: -6.19),
        Box(name: "United Kingdom", minLat: 49.9, maxLat: 58.7, minLon: -8.2, maxLon: 1.76),
        Box(name: "Ireland", minLat: 51.4, maxLat: 55.4, minLon: -10.5, maxLon: -5.99),
        Box(name: "Greece", minLat: 34.8, maxLat: 41.75, minLon: 19.3, maxLon: 28.25),
        Box(name: "Crete", minLat: 34.85, maxLat: 35.72, minLon: 23.45, maxLon: 26.35),
        Box(name: "Romania", minLat: 43.6, maxLat: 48.25, minLon: 22.3, maxLon: 29.7),
        // Yaremche / Vorokhta sit just under the old 48.3 line and leaked into Romania.
        Box(name: "Ukraine", minLat: 47.85, maxLat: 52.4, minLon: 22.1, maxLon: 40.2),
        Box(name: "Ukraine", minLat: 44.3, maxLat: 48.25, minLon: 29.75, maxLon: 40.2),
        Box(name: "Poland", minLat: 49.0, maxLat: 54.9, minLon: 14.1, maxLon: 23.9),
        Box(name: "Czechia", minLat: 48.55, maxLat: 51.06, minLon: 12.09, maxLon: 18.86),
        Box(name: "Hungary", minLat: 45.74, maxLat: 48.58, minLon: 16.11, maxLon: 22.9),
        Box(name: "Slovakia", minLat: 47.7, maxLat: 49.62, minLon: 16.83, maxLon: 22.57),
        Box(name: "Croatia", minLat: 42.4, maxLat: 46.55, minLon: 13.5, maxLon: 19.45),
        Box(name: "Bulgaria", minLat: 41.24, maxLat: 44.22, minLon: 22.36, maxLon: 28.6),
        Box(name: "Turkey", minLat: 36.0, maxLat: 42.1, minLon: 26.0, maxLon: 44.8),
        Box(name: "Denmark", minLat: 54.5, maxLat: 57.75, minLon: 8.0, maxLon: 15.2),
        Box(name: "Sweden", minLat: 55.3, maxLat: 69.1, minLon: 11.1, maxLon: 24.2),
        Box(name: "Norway", minLat: 57.9, maxLat: 71.2, minLon: 4.5, maxLon: 31.1),
        Box(name: "Panama", minLat: 7.2, maxLat: 9.7, minLon: -83.0, maxLon: -77.1),
        Box(name: "Costa Rica", minLat: 8.0, maxLat: 11.25, minLon: -86.0, maxLon: -82.5),
        Box(name: "Colombia", minLat: -4.3, maxLat: 13.5, minLon: -79.1, maxLon: -66.8),
        Box(name: "USA", minLat: 24.5, maxLat: 49.4, minLon: -125.0, maxLon: -66.9)
    ]

    static func country(latitude: Double, longitude: Double) -> String? {
        let matches = boxes.filter { $0.contains(latitude: latitude, longitude: longitude) }
        let names = Set(matches.map(\.name))
        if names.count == 1 { return names.first }
        // Coarse boxes overlap on the Pyrenees; south of the ridge is Spain.
        if names == ["France", "Spain"] {
            return latitude < 42.45 ? "Spain" : "France"
        }
        // Ireland is also inside the broad UK box.
        if names == ["Ireland", "United Kingdom"] {
            return "Ireland"
        }
        // France's north edge and the NL box both cover Brussels. Keep
        // Breda/Maastricht as Netherlands and Lille as France.
        if names.contains("Belgium") && names.contains("Netherlands") {
            return latitude < 51.4 && longitude < 5.6 ? "Belgium" : "Netherlands"
        }
        if names == ["Belgium", "France"] {
            return latitude >= 50.68 && longitude >= 3.5 ? "Belgium" : "France"
        }
        // Crete sits inside the Greece box. Owner Jul 2023: Summer holidays in Crete.
        if names == ["Greece", "Crete"] {
            return "Crete"
        }
        // Košice sits above the Hungary box; the south of this Slovakia box overlaps Hungary.
        if names == ["Hungary", "Slovakia"] {
            return latitude >= 48.55 ? "Slovakia" : "Hungary"
        }
        // Spain's west edge covers Lisbon/Caparica. Guadiana (~-7.4) splits Portugal / Spain.
        if names == ["Portugal", "Spain"] {
            return longitude < -7.4 ? "Portugal" : "Spain"
        }
        // Colombia's coarse box covers eastern Panama (San Blas). Prefer the Panama box.
        if names == ["Panama", "Colombia"] {
            return "Panama"
        }
        // Romania's coarse NE corner covers Yaremche (48.24, 24.25). East of 24° is Ukraine.
        if names == ["Romania", "Ukraine"] {
            return longitude >= 24.0 ? "Ukraine" : "Romania"
        }
        return nil
    }

    /// Berlin city + nearby Oranienburg. Used to keep thin arrival/departure pins
    /// on a Bavaria drive and to mark flight-shaped Home ↔ Berlin hops air.
    static func isBerlinMetro(latitude: Double, longitude: Double) -> Bool {
        CLLocation(latitude: latitude, longitude: longitude).distance(
            from: CLLocation(latitude: 52.52, longitude: 13.405)) < 80_000
    }

    /// Kyiv city. Nov 2014 left Home in Ukraine via Kyiv, then flew to NL.
    static func isKyivMetro(latitude: Double, longitude: Double) -> Bool {
        CLLocation(latitude: latitude, longitude: longitude).distance(
            from: CLLocation(latitude: 50.45, longitude: 30.523)) < 50_000
    }

    /// Munich city + MUC. Jan 2014 flew Lviv ↔ Munich on the way to California.
    static func isMunichMetro(latitude: Double, longitude: Double) -> Bool {
        CLLocation(latitude: latitude, longitude: longitude).distance(
            from: CLLocation(latitude: 48.14, longitude: 11.58)) < 50_000
    }
}

enum JourneySeason: String, Sendable {
    case winter = "Winter"
    case spring = "Spring"
    case summer = "Summer"
    case autumn = "Autumn"

    static func northern(month: Int) -> JourneySeason {
        switch month {
        case 12, 1, 2: return .winter
        case 3, 4, 5: return .spring
        case 6, 7, 8: return .summer
        default: return .autumn
        }
    }
}

struct JourneyMergeRecord: Equatable, Sendable {
    let id: String
    let momentIDs: [String]
    let title: String
}

/// Collapses rebuilt Journeys that the owner has merged. Exact Moment-set match only.
enum JourneyMergePlan {
    static func id(momentIDs: [String]) -> String {
        let fingerprint = "journey-merge|" + momentIDs.sorted().joined(separator: "|")
        return "story-" + MomentContinuity.digest(Data(fingerprint.utf8))
    }

    static func applying(_ stories: [CurationStory], merges: [JourneyMergeRecord]) -> [CurationStory] {
        var remaining = stories
        var produced: [CurationStory] = []
        for merge in merges {
            let members = Set(merge.momentIDs)
            guard members.count >= 2 else { continue }
            let matched = remaining.filter { story in
                story.kind == .journey
                    && !Set(story.momentIDs).isDisjoint(with: members)
                    && Set(story.momentIDs).isSubset(of: members)
            }
            let union = Set(matched.flatMap(\.momentIDs))
            guard matched.count >= 2, union == members else { continue }
            let ordered = matched.sorted { $0.start < $1.start }
            var seen = Set<String>()
            let momentIDs = ordered.flatMap(\.momentIDs).filter { seen.insert($0).inserted }
            let rawStops = ordered.flatMap(\.stops).sorted { $0.start < $1.start }
            let stops = JourneyTransportInference.applying(
                to: JourneyStopSanitizer.removingRouteNoise(rawStops, homes: [], homeLabel: "Home"))
            let start = ordered.map(\.start).min() ?? ordered[0].start
            let end = ordered.map(\.end).max() ?? ordered[0].end
            // Prefer a country/season title from cleaned stops. A plain owner draft like
            // "Journey to USA" is kept only when it already looks finalized and specific.
            let trimmed = merge.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let grounded = JourneyStoryBuilder.title(homeLabel: "Home", stops: stops)
            let placeID: String
            if trimmed.isEmpty {
                placeID = grounded
            } else if trimmed.hasPrefix("Journey from ") {
                placeID = grounded
            } else {
                placeID = String(trimmed.prefix(200))
            }
            produced.append(CurationStory(id: merge.id, start: start, end: end,
                momentIDs: momentIDs, placeID: placeID, kind: .journey, stops: stops))
            let matchedIDs = Set(matched.map(\.id))
            remaining.removeAll { matchedIDs.contains($0.id) }
        }
        return (remaining + produced).sorted { $0.start > $1.start }
    }
}

enum JourneyStoryBuilder {
    /// Travel destinations must clear the local Home orbit (day trips / concerts stay outings).
    static let distantTravelMeters: CLLocationDistance = 100_000
    /// Inside this radius of Home is still "home region" even when the geofence is tiny.
    static let localOrbitMeters: CLLocationDistance = 80_000
    /// One thin messenger/export ping must not name a Journey beside real stays.
    static let titleMinPhotos = 2
    /// Distant travel resuming within this window keeps one Journey open across a Home touch
    /// (Grand Rapids → household Home photos → Panama two days later is one Americas trip).
    static let homeLayoverBridgeSeconds: TimeInterval = 3 * 86_400
    /// Home photos this thin, while distant GPS was recent, are treated as the other phone —
    /// not a real return that ends the Journey.
    static let parallelHomeMaxPhotos = 2
    static let recentDistantSeconds: TimeInterval = 36 * 3600
    /// Quiet days before departure still count (Crete 2023: last NL GPS five days earlier).
    static let homeDepartLookbackSeconds: TimeInterval = 7 * 86_400
    /// Quiet days after an island flight still close at Home (Crete 2023: 11 days).
    static let homeReturnLookaheadSeconds: TimeInterval = 14 * 86_400
    /// A stay at Home in Ukraine does not end a summer road trip if travel resumes (Jul–Aug 2021).
    static let secondaryHomeBridgeSeconds: TimeInterval = 40 * 86_400
    /// Carpathian weekends sit just past the 100 km distant line but still belong
    /// to the Ukraine-home stay (Jul–Aug 2019 → Berlin drive home).
    static let secondaryHomeTheaterMeters: CLLocationDistance = 250_000
    /// Kraków is a Lviv car outing (~295 km), just past the Carpathian theater.
    static let secondaryHomeDriveMeters: CLLocationDistance = 350_000
    /// Island / region names that beat a single village (Ravdoucha → Crete).
    private static let preferRegionTitle: Set<String> = ["Crete"]

    static func title(homeLabel: String, stops: [JourneyStopEvidence],
                      calendar: Calendar = .current) -> String {
        // Prefer destinations with more photo support. Secondary Home places and thin
        // pings never name the Journey when richer stops exist. Country titles use
        // coordinates, so stuck landmark labels still collapse to France / Greece.
        let maxPhotos = stops.map(\.photoCount).max() ?? 0
        let substantial = stops.enumerated().compactMap { index, stop -> JourneyStopEvidence? in
            if stop.photoCount < titleMinPhotos && maxPhotos >= titleMinPhotos { return nil }
            guard stop.photoCount >= 1 else { return nil }
            if let label = stop.place {
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.compare(homeLabel, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                    || isSecondaryHomeLabel(trimmed, primaryHome: homeLabel) {
                    return nil
                }
            }
            if PlaceNaming.looksAirport(stop.place) { return nil }
            if JourneyStopSanitizer.isAirConnection(in: stops, index: index) { return nil }
            return stop
        }
        // Country titles need real travel spread — two GPS points in the same city must not
        // become "Journey to France" before a city label exists.
        if substantial.count >= 2, travelSpreadMeters(substantial) >= 50_000,
           let countryTitle = countryTitle(for: substantial, calendar: calendar) {
            return countryTitle
        }
        if let regionTitle = preferredRegionTitle(for: substantial, calendar: calendar) {
            return regionTitle
        }
        // Mini-Europe / park pins: use the country (Belgium), not the attraction.
        if !substantial.isEmpty,
           substantial.allSatisfy({ PlaceNaming.shouldReplaceJourneyStopLabel($0.place) }),
           !substantial.contains(where: { PlaceNaming.looksRetail($0.place) }),
           let countryTitle = countryTitle(for: substantial, calendar: calendar) {
            return countryTitle
        }
        let destinations = substantial.sorted { $0.photoCount > $1.photoCount }.compactMap { stop -> (String, JourneyStopEvidence)? in
            guard let label = stop.place else { return nil }
            let trimmed = label.split(separator: ",").last.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? label
            guard !trimmed.isEmpty,
                  !PlaceNaming.looksStreetLevel(trimmed),
                  !PlaceNaming.looksLandmarkOrTransit(trimmed),
                  !PlaceNaming.labelConflictsWithCoordinates(trimmed, latitude: stop.latitude,
                                                             longitude: stop.longitude) else { return nil }
            return (trimmed, stop)
        }
            .reduce(into: [(String, JourneyStopEvidence)]()) { result, item in
                if !result.contains(where: { existing in
                    existing.0.compare(item.0, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }) {
                    result.append(item)
                }
            }
        let labels = destinations.map(\.0)
        // Brisbane, California must not become "Spring in Brisbane" — use the USA box.
        if labels.isEmpty, let countryTitle = countryTitle(for: substantial, calendar: calendar) {
            return countryTitle
        }
        guard !labels.isEmpty else { return "Journey from \(homeLabel)" }
        return humanTitle(labels: labels, destinations: destinations, calendar: calendar)
            ?? listedTitle(labels)
    }

    private static func travelSpreadMeters(_ stops: [JourneyStopEvidence]) -> CLLocationDistance {
        guard stops.count >= 2 else { return 0 }
        var maximum: CLLocationDistance = 0
        for index in stops.indices {
            let left = CLLocation(latitude: stops[index].latitude, longitude: stops[index].longitude)
            for other in stops[(index + 1)...] {
                let distance = left.distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
                if distance > maximum { maximum = distance }
            }
        }
        return maximum
    }

    /// Crete (and later island regions) beat a single village name.
    private static func preferredRegionTitle(for stops: [JourneyStopEvidence],
                                             calendar: Calendar) -> String? {
        guard !stops.isEmpty,
              let names = countryNames(stops.map { ("", $0) }),
              names.count == 1, let name = names.first,
              preferRegionTitle.contains(name) else { return nil }
        return countryTitle(for: stops, calendar: calendar)
    }

    /// Country / season / year from stop coordinates alone.
    private static func countryTitle(for stops: [JourneyStopEvidence],
                                     calendar: Calendar) -> String? {
        let destinations = stops.map { ("", $0) }
        guard var names = countryNames(destinations) else { return nil }
        names = droppingEuropeanOceanVia(names, stops: stops)
        guard let first = names.first else { return nil }
        let days = spanDays(stops, calendar: calendar)
        let season = season(of: stops, calendar: calendar)
        let year = calendarYear(of: stops, calendar: calendar)
        if let americas = americasRegionTitle(names: names, year: year) {
            return americas
        }
        if names.count == 1 {
            if let season, days >= 5, days <= 24 {
                return "\(season.rawValue) holidays in \(first)"
            }
            if let year { return "Journey to \(first) in \(year)" }
            return "Journey to \(first)"
        }
        if names.count == 2 {
            if let year { return "Journey to \(names[0]) and \(names[1]) in \(year)" }
            return "Journey to \(names[0]) and \(names[1])"
        }
        let listed = names.prefix(3)
        if listed.count >= 3 {
            return "Journey through \(listed[0]), \(listed[1]), and \(listed[2])"
        }
        return nil
    }

    /// Country, season, and year when the stops support them. Home is already dropped from
    /// destination stops, so a multi-city trip can be "Summer holidays in France" instead of
    /// a list of every town.
    private static func humanTitle(labels: [String],
                                   destinations: [(String, JourneyStopEvidence)],
                                   calendar: Calendar) -> String? {
        guard labels.count >= 2 else {
            if let season = season(of: destinations.map(\.1), calendar: calendar),
               spanDays(destinations.map(\.1), calendar: calendar) >= 10 {
                return "\(season.rawValue) in \(labels[0])"
            }
            return "Journey to \(labels[0])"
        }
        guard var names = countryNames(destinations) else { return nil }
        names = droppingEuropeanOceanVia(names, stops: destinations.map(\.1))
        let days = spanDays(destinations.map(\.1), calendar: calendar)
        let season = season(of: destinations.map(\.1), calendar: calendar)
        let year = calendarYear(of: destinations.map(\.1), calendar: calendar)
        if let americas = americasRegionTitle(names: names, year: year) {
            return americas
        }
        if names.count == 1, let country = names.first {
            if let season, days >= 5, days <= 24 {
                return "\(season.rawValue) holidays in \(country)"
            }
            if let year { return "Journey to \(country) in \(year)" }
            return "Journey to \(country)"
        }
        if names.count == 2 {
            if let year { return "Journey to \(names[0]) and \(names[1]) in \(year)" }
            return "Journey to \(names[0]) and \(names[1])"
        }
        let listed = names.prefix(3)
        if listed.count >= 3 {
            return "Journey through \(listed[0]), \(listed[1]), and \(listed[2])"
        }
        return nil
    }

    /// USA/Canada + Latin America (Grand Rapids → Panama) is one Americas circuit, not a
    /// two-country laundry list. Prefer traveler "Americas" over NORAM/LATAM jargon.
    private static let noramCountries: Set<String> = ["USA", "Canada"]
    private static let latamCountries: Set<String> = [
        "Panama", "Costa Rica", "Colombia", "Mexico"
    ]

    /// Munich on a California circuit is the ocean via, not a Germany holiday
    /// (Jan 2014 Lviv → Munich → USA → Munich → Lviv).
    private static func droppingEuropeanOceanVia(_ names: [String],
                                                 stops: [JourneyStopEvidence]) -> [String] {
        guard names.contains("USA"), names.contains("Germany") else { return names }
        let germany = stops.filter {
            JourneyRegionNames.country(latitude: $0.latitude, longitude: $0.longitude) == "Germany"
        }
        guard !germany.isEmpty,
              germany.allSatisfy({
                  JourneyRegionNames.isMunichMetro(latitude: $0.latitude, longitude: $0.longitude)
              }) else { return names }
        return names.filter { $0 != "Germany" }
    }

    private static func americasRegionTitle(names: [String], year: Int?) -> String? {
        let set = Set(names)
        guard !set.isDisjoint(with: noramCountries),
              !set.isDisjoint(with: latamCountries) else { return nil }
        if let year { return "Journey to Americas in \(year)" }
        return "Journey to Americas"
    }

    private static func listedTitle(_ labels: [String]) -> String {
        switch labels.count {
        case 1: return "Journey to \(labels[0])"
        case 2: return "Journey to \(labels[0]) and \(labels[1])"
        default: return "Journey via \(labels[0]), \(labels[1]), and \(labels[2])"
        }
    }

    /// Photo-weighted country names. Ambiguous or unboxed coordinates are skipped so a
    /// border town does not force the older city/landmark list for the whole Journey.
    private static func countryNames(_ destinations: [(String, JourneyStopEvidence)]) -> [String]? {
        var totals: [String: Int] = [:]
        var order: [String] = []
        var knownWeight = 0
        var totalWeight = 0
        for item in destinations {
            let weight = max(1, item.1.photoCount)
            totalWeight += weight
            guard let name = JourneyRegionNames.country(latitude: item.1.latitude, longitude: item.1.longitude) else {
                continue
            }
            if totals[name] == nil { order.append(name) }
            totals[name, default: 0] += weight
            knownWeight += weight
        }
        guard !order.isEmpty, totalWeight > 0, knownWeight * 2 >= totalWeight else { return nil }
        return order.sorted { lhs, rhs in
            let left = totals[lhs] ?? 0
            let right = totals[rhs] ?? 0
            if left != right { return left > right }
            if let leftIndex = order.firstIndex(of: lhs), let rightIndex = order.firstIndex(of: rhs) {
                return leftIndex < rightIndex
            }
            return lhs < rhs
        }
    }

    private static func spanDays(_ stops: [JourneyStopEvidence], calendar: Calendar) -> Int {
        guard let start = stops.map(\.start).min(), let end = stops.map(\.end).max() else { return 0 }
        return max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                              to: calendar.startOfDay(for: end)).day ?? 0)
    }

    private static func season(of stops: [JourneyStopEvidence], calendar: Calendar) -> JourneySeason? {
        guard let start = stops.map(\.start).min(), let end = stops.map(\.end).max() else { return nil }
        var day = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        var seen = Set<JourneySeason>()
        var guardCount = 0
        while day <= last && guardCount < 400 {
            let month = calendar.component(.month, from: day)
            seen.insert(JourneySeason.northern(month: month))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            guardCount += 1
        }
        return seen.count == 1 ? seen.first : nil
    }

    private static func calendarYear(of stops: [JourneyStopEvidence], calendar: Calendar) -> Int? {
        guard let start = stops.map(\.start).min(), let end = stops.map(\.end).max() else { return nil }
        let startYear = calendar.component(.year, from: start)
        let endYear = calendar.component(.year, from: end)
        return startYear == endYear ? startYear : nil
    }

    /// Exact primary pin only (`Home`). `Home in Ukraine` is a different residence.
    static func isPrimaryHomeLabel(_ label: String, primaryHome: String) -> Bool {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(primaryHome, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// Primary or secondary residence labels (`Home`, `Home in Ukraine`).
    static func isSecondaryHomeLabel(_ label: String, primaryHome: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.compare(primaryHome, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return true
        }
        let lower = trimmed.lowercased()
        return lower == "home" || lower.hasPrefix("home ") || lower.hasPrefix("home\u{00a0}")
    }

    /// Builds only closed home-to-home journeys. Open or weak sequences fall back to place Stories.
    /// `homes` may include several residences (Netherlands Home and Home in Ukraine); any of them
    /// can start or end a Journey. Thin messenger pings do not become route stops.
    static func stories(_ moments: [PhotoMoment], home: MeaningfulPlace,
                        coordinate: (PhotoMoment) -> CLLocationCoordinate2D?,
                        placeID: (PhotoMoment) -> String?,
                        support: (PhotoMoment) -> Int = { $0.photos.count }) -> [CurationStory] {
        stories(moments, homes: [home], coordinate: coordinate, placeID: placeID, support: support)
    }

    static func stories(_ moments: [PhotoMoment], homes: [MeaningfulPlace],
                        coordinate: (PhotoMoment) -> CLLocationCoordinate2D?,
                        placeID: (PhotoMoment) -> String?,
                        support: (PhotoMoment) -> Int = { $0.photos.count }) -> [CurationStory] {
        guard let primaryHome = homes.first(where: {
            $0.label.compare("Home", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) ?? homes.first else { return [] }
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
        func matchingHome(_ coordinate: CLLocationCoordinate2D) -> MeaningfulPlace? {
            homes.first { $0.contains(latitude: coordinate.latitude, longitude: coordinate.longitude) }
        }
        func distanceFromNearestHome(_ coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
            homes.map {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(
                    from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            }.min() ?? .greatestFiniteMagnitude
        }
        func inHomeGeofence(_ coordinate: CLLocationCoordinate2D) -> Bool {
            matchingHome(coordinate) != nil
        }
        func isSecondaryResidence(_ location: CLLocationCoordinate2D) -> Bool {
            homes.contains { home in
                guard !isPrimaryHomeLabel(home.label, primaryHome: primaryHome.label) else {
                    return false
                }
                return home.contains(latitude: location.latitude, longitude: location.longitude)
                    || CLLocation(latitude: home.latitude, longitude: home.longitude).distance(
                        from: CLLocation(latitude: location.latitude, longitude: location.longitude))
                        < 8_000
            }
        }
        /// Drive-back GPS 20–80 km from Home in Ukraine is still the Ukraine stay,
        /// not an NL-style local outing that should close the Journey.
        func inSecondaryHomeOrbit(_ location: CLLocationCoordinate2D) -> Bool {
            homes.contains { home in
                guard !isPrimaryHomeLabel(home.label, primaryHome: primaryHome.label) else {
                    return false
                }
                return CLLocation(latitude: home.latitude, longitude: home.longitude).distance(
                    from: CLLocation(latitude: location.latitude, longitude: location.longitude))
                    < localOrbitMeters
            }
        }
        func nearSecondaryHomeTheater(_ location: CLLocationCoordinate2D) -> Bool {
            homes.contains { home in
                guard !isPrimaryHomeLabel(home.label, primaryHome: primaryHome.label) else {
                    return false
                }
                return CLLocation(latitude: home.latitude, longitude: home.longitude).distance(
                    from: CLLocation(latitude: location.latitude, longitude: location.longitude))
                    < secondaryHomeTheaterMeters
            }
        }
        func nearSecondaryHomeDrive(_ location: CLLocationCoordinate2D) -> Bool {
            homes.contains { home in
                guard !isPrimaryHomeLabel(home.label, primaryHome: primaryHome.label) else {
                    return false
                }
                return CLLocation(latitude: home.latitude, longitude: home.longitude).distance(
                    from: CLLocation(latitude: location.latitude, longitude: location.longitude))
                    < secondaryHomeDriveMeters
            }
        }
        func isOceanCoordinate(_ location: CLLocationCoordinate2D) -> Bool {
            homes.allSatisfy {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(
                    from: CLLocation(latitude: location.latitude, longitude: location.longitude))
                    >= JourneyTransportInference.intercontinentalAirMeters
            }
        }
        func upcomingOceanResume(after index: Int, from end: Date) -> Bool {
            ordered.dropFirst(index + 1).contains { candidate in
                candidate.start.timeIntervalSince(end) <= 90 * 86_400
                    && (resolvedPoint(candidate).map { isDistantTravel($0) && isOceanCoordinate($0) } ?? false)
            }
        }
        func activeIsOceanStay() -> Bool {
            active.contains {
                resolvedPoint($0).map { isDistantTravel($0) && isOceanCoordinate($0) } ?? false
            }
        }
        func isFarUkraineCity(_ location: CLLocationCoordinate2D) -> Bool {
            JourneyRegionNames.country(latitude: location.latitude, longitude: location.longitude) == "Ukraine"
                && !nearSecondaryHomeDrive(location)
        }
        func inLocalOrbit(_ coordinate: CLLocationCoordinate2D) -> Bool {
            distanceFromNearestHome(coordinate) < localOrbitMeters
        }
        func isDistantTravel(_ coordinate: CLLocationCoordinate2D) -> Bool {
            // Far from every mapped home — a stay at the Ukraine residence is not travel.
            homes.allSatisfy {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(
                    from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
                    >= distantTravelMeters
            }
        }
        func upcomingDistantTravel(after index: Int, from end: Date,
                                   within: TimeInterval = homeLayoverBridgeSeconds) -> Bool {
            ordered.dropFirst(index + 1).prefix { candidate in
                candidate.start.timeIntervalSince(end) <= within
            }.contains { candidate in
                guard let location = resolvedPoint(candidate) else { return false }
                return isDistantTravel(location)
            }
        }
        func recentlyDistant(before end: Date) -> Bool {
            active.reversed().contains { moment in
                guard let location = resolvedPoint(moment), isDistantTravel(location) else { return false }
                return end.timeIntervalSince(moment.end) <= recentDistantSeconds
            }
        }
        /// Keep the Journey open across household Home noise or a short Home layover.
        /// A real Home-orbit outing (Badhoevedorp after Greece) still ends the prior trip when
        /// the touch is not at/near a mapped Home pin — even if distant travel resumes soon.
        func nearHomePin(_ moment: PhotoMoment, maxMeters: CLLocationDistance = 8_000) -> Bool {
            guard let location = resolvedPoint(moment) else { return false }
            return homes.contains { home in
                home.contains(latitude: location.latitude, longitude: location.longitude)
                    || CLLocation(latitude: home.latitude, longitude: home.longitude).distance(
                        from: CLLocation(latitude: location.latitude, longitude: location.longitude))
                        < maxMeters
            }
        }
        func shouldKeepJourneyOpen(_ moment: PhotoMoment, at index: Int, geofence: Bool) -> Bool {
            let photos = max(1, support(moment))
            if photos <= parallelHomeMaxPhotos && recentlyDistant(before: moment.start) {
                return true
            }
            // Tiny Home geofences leave most household shots a few km outside the pin.
            // Treat geofence or near-pin orbit as a layover when distant travel resumes soon.
            // Named local outings farther out (Badhoevedorp) still finish Greece before Bucharest.
            if let location = resolvedPoint(moment),
               (isSecondaryResidence(location) || inSecondaryHomeOrbit(location)),
               upcomingDistantTravel(after: index, from: moment.end, within: secondaryHomeBridgeSeconds) {
                return true
            }
            let closeHome = geofence || nearHomePin(moment)
            return closeHome && upcomingDistantTravel(after: index, from: moment.end)
        }
        func homeAnchor(among members: [PhotoMoment], around boundary: Date, departing: Bool,
                        minPhotos: Int = titleMinPhotos)
            -> JourneyStopEvidence? {
            struct Score {
                var photos = 0
                var start = Date.distantFuture
                var end = Date.distantPast
            }
            var scores: [UUID: Score] = [:]
            for member in members {
                guard let location = resolvedPoint(member),
                      let home = homes.first(where: {
                          $0.contains(latitude: location.latitude, longitude: location.longitude)
                              || CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(
                                from: CLLocation(latitude: location.latitude, longitude: location.longitude))
                              < 8_000
                      }) else { continue }
                // Ignore decades-old library dates when anchoring Home around a trip boundary.
                let inWindow: Bool
                if departing {
                    inWindow = member.end <= boundary.addingTimeInterval(6 * 3600)
                        && member.start >= boundary.addingTimeInterval(-homeDepartLookbackSeconds)
                } else {
                    // Return: first Home photos after the last abroad stop. One thin phone
                    // ping the day after landing is enough to draw Panama → Home — do not
                    // wait for a multi-photo Home day that may land outside a tight window.
                    inWindow = member.start >= boundary.addingTimeInterval(-2 * 3600)
                        && member.start <= boundary.addingTimeInterval(homeReturnLookaheadSeconds)
                }
                guard inWindow,
                      abs(member.start.timeIntervalSince(boundary)) < 40 * 86_400,
                      abs(member.end.timeIntervalSince(boundary)) < 40 * 86_400 else { continue }
                var score = scores[home.id] ?? Score()
                score.photos += max(1, support(member))
                score.start = min(score.start, member.start)
                score.end = max(score.end, member.end)
                scores[home.id] = score
            }
            guard let best = scores.max(by: { lhs, rhs in
                if lhs.value.photos != rhs.value.photos { return lhs.value.photos < rhs.value.photos }
                return lhs.value.end < rhs.value.end
            }), best.value.photos >= minPhotos,
                  let home = homes.first(where: { $0.id == best.key }) else { return nil }
            return JourneyStopEvidence(start: best.value.start, end: best.value.end,
                latitude: home.latitude, longitude: home.longitude,
                momentCount: 1, photoCount: best.value.photos, place: home.label, confidence: 1)
        }

        /// Traveler maps start at Home even when the departing phone never geotagged
        /// (Bucharest Jun 2026: flew from NL, first GPS is already in Romania).
        func assumedHomeEndpoint(around boundary: Date, firstDistant: CLLocationCoordinate2D)
            -> JourneyStopEvidence? {
            let away = CLLocation(latitude: firstDistant.latitude, longitude: firstDistant.longitude)
                .distance(from: CLLocation(latitude: primaryHome.latitude, longitude: primaryHome.longitude))
            guard away >= distantTravelMeters else { return nil }
            let stamp = boundary.addingTimeInterval(-12 * 3600)
            return JourneyStopEvidence(start: stamp, end: stamp,
                latitude: primaryHome.latitude, longitude: primaryHome.longitude,
                momentCount: 1, photoCount: 1, place: primaryHome.label, confidence: 0.4)
        }

        var active: [PhotoMoment] = [], distantAway = 0
        var sawSecondaryOnRoute = false
        var excursion: [PhotoMoment] = []
        var results: [CurationStory] = []

        func finish() {
            defer { active = []; distantAway = 0; sawSecondaryOnRoute = false }
            let distantIndexes = active.indices.filter { index in
                guard let point = resolvedPoint(active[index]) else { return false }
                return isDistantTravel(point)
            }
            let oceanStay = distantIndexes.contains {
                resolvedPoint(active[$0]).map(isOceanCoordinate) ?? false
            }
            let theaterStay = distantIndexes.contains {
                resolvedPoint(active[$0]).map {
                    nearSecondaryHomeTheater($0) || nearSecondaryHomeDrive($0)
                } ?? false
            }
            let substantialSingle = distantIndexes.count == 1
                && support(active[distantIndexes[0]]) >= 10
            let farUkraineStay = distantIndexes.count == 1
                && support(active[distantIndexes[0]]) >= 3
                && (resolvedPoint(active[distantIndexes[0]]).map(isFarUkraineCity) ?? false)
            guard (distantIndexes.count >= 2 || oceanStay || (theaterStay && substantialSingle)
                    || farUkraineStay),
                  let firstDistant = distantIndexes.first,
                  let lastDistant = distantIndexes.last else { return }
            let firstTime = active[firstDistant].start.addingTimeInterval(-86_400)
            let lastTime = active[lastDistant].end.addingTimeInterval(86_400)
            let members = active.filter { $0.end >= firstTime && $0.start <= lastTime }
            // Home Moments are not appended to `active`; still use them for start/end circles.
            let homeFirst = active[firstDistant].start.addingTimeInterval(-homeDepartLookbackSeconds)
            // Return-home photos can land up to two weeks after the last distant stop
            // (Crete 2023: first Home unlock 11 days later). An ocean hop may take
            // longer (Dec 2013 California → Lviv, Kraków split off in between).
            let returnLookahead = oceanStay
                ? JourneyTransportInference.intercontinentalHomeGapSeconds
                : homeReturnLookaheadSeconds
            let homeLast = active[lastDistant].end.addingTimeInterval(returnLookahead)
            let homeWindow = ordered.filter { $0.end >= homeFirst && $0.start <= homeLast }
            // A week already at Home in Ukraine sits outside the 7-day NL depart
            // lookback (Jul 2019). Still pull those pins onto the route.
            let secondaryWindowFirst = active[firstDistant].start
                .addingTimeInterval(-secondaryHomeBridgeSeconds)
            let secondaryWindow = ordered.filter { $0.end >= secondaryWindowFirst && $0.start <= homeLast }
            guard let first = members.first, let last = members.last else { return }
            if last.end.timeIntervalSince(first.start) < 36 * 3600,
               !oceanStay, !(theaterStay && substantialSingle), !farUkraineStay {
                return
            }
            func isHomeOrbitAirBridge(_ member: PhotoMoment, location: CLLocationCoordinate2D) -> Bool {
                guard inLocalOrbit(location), !inHomeGeofence(location), !nearHomePin(member) else {
                    return false
                }
                for other in members where other.id != member.id {
                    guard let otherLocation = resolvedPoint(other), isDistantTravel(otherLocation) else {
                        continue
                    }
                    let hop = CLLocation(latitude: location.latitude, longitude: location.longitude)
                        .distance(from: CLLocation(latitude: otherLocation.latitude,
                                                   longitude: otherLocation.longitude))
                    guard hop >= 400_000 else { continue }
                    let departGap = other.start.timeIntervalSince(member.end)
                    let arriveGap = member.start.timeIntervalSince(other.end)
                    if (departGap >= 0 && departGap <= 6 * 3600)
                        || (arriveGap >= 0 && arriveGap <= 6 * 3600) {
                        return true
                    }
                }
                return false
            }
            let airportBridges = homeWindow.filter { candidate in
                guard let location = resolvedPoint(candidate) else { return false }
                return isHomeOrbitAirBridge(candidate, location: location)
                    && !members.contains(where: { $0.id == candidate.id })
            }
            let secondaryStays = secondaryWindow.filter { candidate in
                guard let location = resolvedPoint(candidate) else { return false }
                return isSecondaryResidence(location)
                    && !members.contains(where: { $0.id == candidate.id })
            }
            let routeMembers = (members + airportBridges + secondaryStays).sorted { $0.start < $1.start }
            var stops: [JourneyStopEvidence] = []
            for member in routeMembers {
                // Local Home-orbit Moments are not destinations — except a departure
                // airport (Schiphol) a few km from Home right before a flight.
                guard let location = resolvedPoint(member) else { continue }
                if inHomeGeofence(location) && !isSecondaryResidence(location) { continue }
                if inLocalOrbit(location) && !isHomeOrbitAirBridge(member, location: location)
                    && !isSecondaryResidence(location) {
                    continue
                }
                let count = max(1, support(member))
                let labeled = placeID(member) ?? homes.first(where: {
                    $0.contains(latitude: location.latitude, longitude: location.longitude)
                        || CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(
                            from: CLLocation(latitude: location.latitude, longitude: location.longitude))
                            < 8_000
                })?.label
                if let previous = stops.last,
                   CLLocation(latitude: previous.latitude, longitude: previous.longitude).distance(
                    from: CLLocation(latitude: location.latitude, longitude: location.longitude)) < 30_000 {
                    let total = previous.photoCount + count
                    stops[stops.count - 1] = JourneyStopEvidence(start: previous.start, end: member.end,
                        latitude: (previous.latitude * Double(previous.photoCount) + location.latitude * Double(count)) / Double(total),
                        longitude: (previous.longitude * Double(previous.photoCount) + location.longitude * Double(count)) / Double(total),
                        momentCount: previous.momentCount + 1, photoCount: total,
                        place: previous.place ?? labeled, confidence: total >= 5 ? 1 : 0.7)
                } else {
                    stops.append(JourneyStopEvidence(start: member.start, end: member.end,
                        latitude: location.latitude, longitude: location.longitude,
                        momentCount: 1, photoCount: count, place: labeled,
                        confidence: count >= 5 ? 1 : 0.6))
                }
            }
            // One messenger ping must not bend the route when real stays exist.
            // Keep thin air connections (DTW / ATL) even at 1 photo.
            if stops.contains(where: { $0.photoCount >= titleMinPhotos }) {
                stops = stops.enumerated().compactMap { index, stop in
                    if stop.photoCount >= titleMinPhotos { return stop }
                    if JourneyStopSanitizer.isAirConnection(in: stops, index: index) { return stop }
                    // First GPS is often the arrival airport (DTW) before the city stay.
                    if index == 0, let next = stops.dropFirst().first(where: { $0.photoCount >= titleMinPhotos }) {
                        let gap = CLLocation(latitude: stop.latitude, longitude: stop.longitude)
                            .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
                        if gap >= JourneyStopSanitizer.arrivalAirportSeparationMeters { return stop }
                    }
                    return nil
                }
            }
            // Retail / transit POIs are not travel destinations (no “Journey to Woodland Mall”).
            let nonHomeStops = stops.filter { stop in
                guard let place = stop.place else { return true }
                return !isSecondaryHomeLabel(place, primaryHome: primaryHome.label)
            }
            let hasRealDestination = nonHomeStops.contains { stop in
                guard let place = stop.place?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !place.isEmpty else { return true }
                return !PlaceNaming.looksLandmarkOrTransit(place) && !PlaceNaming.looksStreetLevel(place)
            }
            if hasRealDestination {
                stops = stops.compactMap { stop -> JourneyStopEvidence? in
                    guard let place = stop.place else { return stop }
                    if isSecondaryHomeLabel(place, primaryHome: primaryHome.label) {
                        let atHome = homes.contains {
                            $0.contains(latitude: stop.latitude, longitude: stop.longitude)
                                || CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(
                                    from: CLLocation(latitude: stop.latitude, longitude: stop.longitude))
                                    < localOrbitMeters
                        }
                        return atHome ? stop : nil
                    }
                    // A forest between two real stays is not a civil-airport hop.
                    if PlaceNaming.looksForest(place),
                       !PlaceNaming.CivilAirports.near(latitude: stop.latitude, longitude: stop.longitude) {
                        return nil
                    }
                    // Keep the stay; wipe street/landmark/highway names so geocode can put
                    // Givors / Reims on the pin instead of Cours Charlemagne / Basilique.
                    if PlaceNaming.shouldReplaceJourneyStopLabel(place)
                        || PlaceNaming.labelConflictsWithCoordinates(place, latitude: stop.latitude,
                                                                     longitude: stop.longitude) {
                        return JourneyStopEvidence(start: stop.start, end: stop.end,
                            latitude: stop.latitude, longitude: stop.longitude,
                            momentCount: stop.momentCount, photoCount: stop.photoCount,
                            place: nil, confidence: stop.confidence,
                            transportFromPrevious: stop.transportFromPrevious)
                    }
                    return stop
                }
            } else if nonHomeStops.allSatisfy({ stop in
                PlaceNaming.looksLandmarkOrTransit(stop.place ?? "")
            }) {
                // Woodland Mall is not a Journey. Mini-Europe in Brussels is — wipe the
                // park name and keep the distant stay so the country title can fire.
                if nonHomeStops.contains(where: { PlaceNaming.looksRetail($0.place) }) {
                    return
                }
                stops = stops.map { stop in
                    guard let place = stop.place, PlaceNaming.shouldReplaceJourneyStopLabel(place) else {
                        return stop
                    }
                    return JourneyStopEvidence(start: stop.start, end: stop.end,
                        latitude: stop.latitude, longitude: stop.longitude,
                        momentCount: stop.momentCount, photoCount: stop.photoCount,
                        place: nil, confidence: stop.confidence,
                        transportFromPrevious: stop.transportFromPrevious)
                }
            }
            stops = JourneyStopSanitizer.removingRouteNoise(stops, homes: homes, homeLabel: primaryHome.label)
            guard !stops.isEmpty else { return }
            let primaryWindow = homeWindow.filter { member in
                guard let location = resolvedPoint(member) else { return false }
                return homes.contains { home in
                    isPrimaryHomeLabel(home.label, primaryHome: primaryHome.label)
                        && (home.contains(latitude: location.latitude, longitude: location.longitude)
                            || CLLocation(latitude: home.latitude, longitude: home.longitude).distance(
                                from: CLLocation(latitude: location.latitude, longitude: location.longitude))
                                < 8_000)
                }
            }
            let departBoundary = ([active[firstDistant].start] + secondaryStays.map(\.start)).min()
                ?? active[firstDistant].start
            let observedPrimaryStart = homeAnchor(among: primaryWindow, around: departBoundary,
                                                  departing: true, minPhotos: 1)
            let secondarySpan: TimeInterval = {
                let prior = secondaryStays.filter { $0.end <= active[firstDistant].start }
                guard let first = prior.map(\.start).min(),
                      let last = prior.map(\.end).max() else { return 0 }
                return last.timeIntervalSince(first)
            }()
            // Already based at Home in Ukraine for a week+ (Hungary 2021): do not invent
            // an NL → Ukraine hop. A two-day Ukraine arrival before Bukovel still gets NL.
            let viaKyiv = (members + secondaryStays).contains { member in
                resolvedPoint(member).map {
                    JourneyRegionNames.isKyivMetro(latitude: $0.latitude, longitude: $0.longitude)
                } ?? false
            }
            // One-way Lviv → Kyiv → NL (Nov 2014): do not invent an NL start.
            let assumePrimary = secondarySpan < 5 * 86_400 && !viaKyiv
            let endHome = homeAnchor(among: primaryWindow, around: active[lastDistant].end,
                                     departing: false, minPhotos: 1)
            // Week+ already at the second home: do not bolt on an NL start just because
            // a prior NL return sits inside a 40-day lookback (Ukraine 2019).
            // Ukraine → Berlin with no NL return (2015) must not invent a Home start.
            let startHome = assumePrimary
                ? (observedPrimaryStart ?? (endHome != nil
                    ? resolvedPoint(active[firstDistant]).flatMap {
                        assumedHomeEndpoint(around: departBoundary, firstDistant: $0)
                    } : nil))
                : observedPrimaryStart
            if let startHome,
               !(stops.first.map { isPrimaryHomeLabel($0.place ?? "", primaryHome: primaryHome.label) } ?? false) {
                stops.insert(startHome, at: 0)
            }
            // One-way Ukraine → NL via Kyiv, or a Carpathian weekend that already
            // returns to Lviv (Slavs'ka Jun 2014): draw the Ukraine Home start.
            let firstIsUkraineHome = stops.first.map {
                isSecondaryHomeLabel($0.place ?? "", primaryHome: primaryHome.label)
                    && !isPrimaryHomeLabel($0.place ?? "", primaryHome: primaryHome.label)
            } ?? false
            let endsAtUkraineHome = stops.last.map {
                isSecondaryHomeLabel($0.place ?? "", primaryHome: primaryHome.label)
                    && !isPrimaryHomeLabel($0.place ?? "", primaryHome: primaryHome.label)
            } ?? false
            let firstDistantInUkraine = resolvedPoint(active[firstDistant]).map {
                JourneyRegionNames.country(latitude: $0.latitude, longitude: $0.longitude) == "Ukraine"
                    || nearSecondaryHomeTheater($0)
                    || nearSecondaryHomeDrive($0)
            } ?? false
            let ukraineHomePlace = homes.first(where: {
                !isPrimaryHomeLabel($0.label, primaryHome: primaryHome.label)
                    && ($0.label.localizedCaseInsensitiveContains("ukraine")
                        || JourneyRegionNames.country(latitude: $0.latitude, longitude: $0.longitude) == "Ukraine")
            })
            if !firstIsUkraineHome, let ukraineHome = ukraineHomePlace,
               (viaKyiv && endHome != nil) || (endsAtUkraineHome && firstDistantInUkraine && startHome == nil) {
                let stamp = departBoundary.addingTimeInterval(-12 * 3600)
                stops.insert(JourneyStopEvidence(start: stamp, end: stamp,
                    latitude: ukraineHome.latitude, longitude: ukraineHome.longitude,
                    momentCount: 1, photoCount: 1, place: ukraineHome.label, confidence: 0.4), at: 0)
            }
            // A leftover Carpathian day (Jun 2013) has no return GPS before California.
            // Still draw Home in Ukraine start/end — it is not an ocean hop.
            let nearLvivOuting = !oceanStay && theaterStay && startHome == nil && endHome == nil
            if nearLvivOuting, let ukraineHome = ukraineHomePlace {
                let firstIsUA = stops.first.map {
                    isSecondaryHomeLabel($0.place ?? "", primaryHome: primaryHome.label)
                        && !isPrimaryHomeLabel($0.place ?? "", primaryHome: primaryHome.label)
                } ?? false
                if !firstIsUA {
                    let stamp = departBoundary.addingTimeInterval(-12 * 3600)
                    stops.insert(JourneyStopEvidence(start: stamp, end: stamp,
                        latitude: ukraineHome.latitude, longitude: ukraineHome.longitude,
                        momentCount: 1, photoCount: 1, place: ukraineHome.label, confidence: 0.4), at: 0)
                }
                let lastIsUA = stops.last.map {
                    isSecondaryHomeLabel($0.place ?? "", primaryHome: primaryHome.label)
                        && !isPrimaryHomeLabel($0.place ?? "", primaryHome: primaryHome.label)
                } ?? false
                if !lastIsUA {
                    let stamp = active[lastDistant].end.addingTimeInterval(12 * 3600)
                    stops.append(JourneyStopEvidence(start: stamp, end: stamp,
                        latitude: ukraineHome.latitude, longitude: ukraineHome.longitude,
                        momentCount: 1, photoCount: 1, place: ukraineHome.label, confidence: 0.4))
                }
            }
            if let endHome,
               !(stops.last.map { isPrimaryHomeLabel($0.place ?? "", primaryHome: primaryHome.label) } ?? false),
               stops.last.map({
                   CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(
                    from: CLLocation(latitude: endHome.latitude, longitude: endHome.longitude)) > 30_000
               }) ?? true {
                stops.append(endHome)
            }
            stops = JourneyStopSanitizer.removingRouteNoise(stops, homes: homes, homeLabel: primaryHome.label)
            let titled = title(homeLabel: primaryHome.label, stops: stops)
            // Named destinations preferred; GPS-only closed trips still qualify as shells.
            guard titled.hasPrefix("Journey ") || titled.contains(" holidays in ")
                || titled.hasPrefix("Summer in ") || titled.hasPrefix("Winter in ")
                || titled.hasPrefix("Spring in ") || titled.hasPrefix("Autumn in ") else { return }
            // Living in California and flying to Azov (Jun–Aug 2013): keep the USA
            // title, but mark the Ukraine week as air from the ocean stay.
            let farUkraine = !oceanStay && members.contains { member in
                guard let pin = resolvedPoint(member) else { return false }
                return JourneyRegionNames.country(latitude: pin.latitude, longitude: pin.longitude) == "Ukraine"
                    && !nearSecondaryHomeDrive(pin)
            }
            if farUkraine {
                let firstStart = active[firstDistant].start
                let lastEnd = active[lastDistant].end
                if let before = ordered.last(where: { candidate in
                    candidate.end <= firstStart
                        && firstStart.timeIntervalSince(candidate.end)
                            <= JourneyTransportInference.intercontinentalHomeGapSeconds
                        && (resolvedPoint(candidate).map { isDistantTravel($0) && isOceanCoordinate($0) } ?? false)
                }), let location = resolvedPoint(before) {
                    stops.insert(JourneyStopEvidence(start: before.start, end: before.end,
                        latitude: location.latitude, longitude: location.longitude,
                        momentCount: 1, photoCount: max(1, support(before)),
                        place: placeID(before), confidence: 0.4), at: 0)
                }
                if let after = ordered.first(where: { candidate in
                    candidate.start >= lastEnd
                        && candidate.start.timeIntervalSince(lastEnd)
                            <= JourneyTransportInference.intercontinentalHomeGapSeconds
                        && (resolvedPoint(candidate).map { isDistantTravel($0) && isOceanCoordinate($0) } ?? false)
                }), let location = resolvedPoint(after) {
                    stops.append(JourneyStopEvidence(start: after.start, end: after.end,
                        latitude: location.latitude, longitude: location.longitude,
                        momentCount: 1, photoCount: max(1, support(after)),
                        place: placeID(after), confidence: 0.4))
                }
            }
            let enriched = JourneyTransportInference.applying(to: stops)
            let ids = routeMembers.map(\.id)
            let fingerprint = "journey|" + ids.joined(separator: "|")
            results.append(CurationStory(id: "story-" + MomentContinuity.digest(Data(fingerprint.utf8)),
                start: first.start, end: last.end, momentIDs: ids, placeID: titled,
                kind: .journey, stops: enriched))
        }

        func finishExcursion() {
            guard !excursion.isEmpty else { return }
            let savedActive = active
            let savedDistant = distantAway
            let savedSecondary = sawSecondaryOnRoute
            active = excursion
            finish()
            excursion = []
            active = savedActive
            distantAway = savedDistant
            sawSecondaryOnRoute = savedSecondary
        }

        var sawHome = false
        for (index, moment) in ordered.enumerated() {
            if let location = resolvedPoint(moment) {
                let homeGeofence = inHomeGeofence(location)
                let localOrbit = inLocalOrbit(location)
                if homeGeofence || localOrbit {
                    if !active.isEmpty {
                        let atSecondHome = isSecondaryResidence(location) || inSecondaryHomeOrbit(location)
                        if atSecondHome { sawSecondaryOnRoute = true }
                        let returnedFromOcean = active.reversed().contains { member in
                            guard let pin = resolvedPoint(member), isDistantTravel(pin) else { return false }
                            return CLLocation(latitude: location.latitude, longitude: location.longitude)
                                .distance(from: CLLocation(latitude: pin.latitude, longitude: pin.longitude))
                                >= JourneyTransportInference.intercontinentalAirMeters
                        }
                        // Bukovel is not a transatlantic airport: a Carpathian weekend
                        // that returns to Lviv must not absorb the next California hop.
                        let nextIsOcean = ordered.dropFirst(index + 1).prefix { candidate in
                            candidate.start.timeIntervalSince(moment.end) <= secondaryHomeBridgeSeconds
                        }.contains { candidate in
                            guard let pin = resolvedPoint(candidate), isDistantTravel(pin) else { return false }
                            return CLLocation(latitude: location.latitude, longitude: location.longitude)
                                .distance(from: CLLocation(latitude: pin.latitude, longitude: pin.longitude))
                                >= JourneyTransportInference.intercontinentalAirMeters
                        }
                        let secondaryKeep = atSecondHome
                            && !returnedFromOcean
                            && !nextIsOcean
                            && upcomingDistantTravel(after: index, from: moment.end,
                                                     within: secondaryHomeBridgeSeconds)
                        let bridgeHome = homeGeofence
                            && distantAway < 2
                            && upcomingDistantTravel(after: index, from: moment.end)
                        // After real travel, only a sustained primary Home return ends it.
                        // One Berlin weekend then weeks at Home in Ukraine (DSLR, little GPS)
                        // still continues when the mountains resume within 40 days.
                        // California → Lviv is a real return: do not keep open for a later Kyiv ping.
                        if secondaryKeep {
                            // Keep open across the second-home stay.
                        } else if atSecondHome && (returnedFromOcean || nextIsOcean) {
                            finish()
                        } else if atSecondHome && distantAway < 2 && !secondaryKeep {
                            // Living in Lviv after a thin leftover (Sep 2010 Berlin)
                            // is not a 4-month Journey into a later Yaremche ski trip.
                            finish()
                        } else if distantAway >= 2 {
                            if shouldKeepJourneyOpen(moment, at: index, geofence: homeGeofence) {
                                // Keep open: other-phone Home shots or geofence layover before
                                // the next far stop (Grand Rapids → Panama).
                            } else {
                                finish()
                            }
                        } else if homeGeofence && !bridgeHome {
                            finish()
                        } else if localOrbit && !homeGeofence && !inSecondaryHomeOrbit(location)
                                    && distantAway >= 1 {
                            // Local outing while a thin abroad ping is open — close it out.
                            finish()
                        }
                    }
                    sawHome = true
                    continue
                }
                guard sawHome else { continue }
                let distant = isDistantTravel(location)
                let incomingOcean = isOceanCoordinate(location)
                let thinKyivLeftover = JourneyRegionNames.isKyivMetro(
                    latitude: location.latitude, longitude: location.longitude)
                    && support(moment) < 5
                    && (activeIsOceanStay() || !excursion.isEmpty)
                    && upcomingOceanResume(after: index, from: moment.end)
                if thinKyivLeftover { continue }
                if !active.isEmpty, moment.start.timeIntervalSince(active.last!.end) >= 7 * 86_400 {
                    let gapStart = active.last!.end
                    let gapEnd = moment.start
                    let bridged = ordered.contains { candidate in
                        guard candidate.end >= gapStart, candidate.start <= gapEnd,
                              let pin = resolvedPoint(candidate) else { return false }
                        return isSecondaryResidence(pin) || inSecondaryHomeOrbit(pin)
                    }
                    // Quiet weeks at Home in Ukraine often have no GPS (2019 Carpathians
                    // → Berlin). Keep the circuit open when the last distant stop is
                    // still in that home's theater and travel resumes within 40 days.
                    let quietSecondaryStay = gapEnd.timeIntervalSince(gapStart) <= secondaryHomeBridgeSeconds
                        && !incomingOcean
                        && !isFarUkraineCity(location)
                        && (sawSecondaryOnRoute
                            || active.reversed().contains { member in
                                guard let pin = resolvedPoint(member) else { return false }
                                return isDistantTravel(pin) && nearSecondaryHomeTheater(pin)
                            })
                    // Bay Area → Austin with a quiet fortnight is still one US trip
                    // (Apr 2014). Both ends are an ocean away from every Home.
                    let sameOceanTrip = gapEnd.timeIntervalSince(gapStart) <= 90 * 86_400
                        && isDistantTravel(location)
                        && active.reversed().contains { member in
                            guard let pin = resolvedPoint(member), isDistantTravel(pin) else { return false }
                            return homes.allSatisfy { home in
                                CLLocation(latitude: home.latitude, longitude: home.longitude).distance(
                                    from: CLLocation(latitude: pin.latitude, longitude: pin.longitude))
                                    >= JourneyTransportInference.intercontinentalAirMeters
                            } && homes.allSatisfy { home in
                                CLLocation(latitude: home.latitude, longitude: home.longitude).distance(
                                    from: CLLocation(latitude: location.latitude, longitude: location.longitude))
                                    >= JourneyTransportInference.intercontinentalAirMeters
                            }
                        }
                    if incomingOcean { finishExcursion() }
                    if !bridged && !quietSecondaryStay && !sameOceanTrip {
                        // Living in California: a Ukraine week in the middle (Azov 2013)
                        // is its own flight, not the end of the USA stay.
                        if activeIsOceanStay() && !incomingOcean
                            && upcomingOceanResume(after: index, from: moment.end) {
                            excursion.append(moment)
                            continue
                        }
                        finishExcursion()
                        finish()
                    }
                } else if !excursion.isEmpty && !incomingOcean {
                    excursion.append(moment)
                    continue
                } else if incomingOcean {
                    finishExcursion()
                }
                active.append(moment)
                if distant { distantAway += 1 }
            } else if !active.isEmpty {
                // Unlocated weeks at Home must not glue a thin leftover to a later outing.
                // A real road trip (2018 Berlin → DSLR weeks → Pylypets) still keeps
                // no-GPS members when travel resumes within 40 days.
                if let lastLocated = active.last(where: { resolvedPoint($0) != nil }),
                   moment.start.timeIntervalSince(lastLocated.end) >= 7 * 86_400 {
                    let lastDistant = active.reversed().first {
                        resolvedPoint($0).map(isDistantTravel) ?? false
                    }
                    let lastSupport = lastDistant.map(support) ?? 0
                    let lastTheater = lastDistant.flatMap(resolvedPoint).map(nearSecondaryHomeTheater) ?? false
                    let keepUnlocated = upcomingDistantTravel(after: index, from: moment.end,
                                                              within: secondaryHomeBridgeSeconds)
                        && (distantAway >= 2 || lastSupport >= 10 || lastTheater || sawSecondaryOnRoute)
                    if !keepUnlocated {
                        finish()
                        continue
                    }
                }
                active.append(moment)
            }
        }
        finishExcursion()
        if !active.isEmpty { finish() }
        return results.sorted { $0.start > $1.start }
    }
}

enum StoryHierarchyBuilder {
    static func stories(_ moments: [PhotoMoment], home: MeaningfulPlace?, calendar: Calendar = .current,
                        coordinate: (PhotoMoment) -> CLLocationCoordinate2D?,
                        placeID: (PhotoMoment) -> String?,
                        support: (PhotoMoment) -> Int = { $0.photos.count }) -> [CurationStory] {
        stories(moments, homes: home.map { [$0] } ?? [], calendar: calendar,
                coordinate: coordinate, placeID: placeID, support: support)
    }

    static func stories(_ moments: [PhotoMoment], homes: [MeaningfulPlace], calendar: Calendar = .current,
                        coordinate: (PhotoMoment) -> CLLocationCoordinate2D?,
                        placeID: (PhotoMoment) -> String?,
                        support: (PhotoMoment) -> Int = { $0.photos.count },
                        leftoverMoments: [UnlocatedAlbumStoryBuilder.MomentMembership] = [],
                        leftoverPhotos: [ExperimentalUnlocatedJourneyBuilder.Photo] = []) -> [CurationStory] {
        let journeys = homes.isEmpty ? [] : JourneyStoryBuilder.stories(
            moments, homes: homes, coordinate: coordinate, placeID: placeID, support: support)
        // A Moment can belong to only one Story (`story_moments.moment_id` is unique).
        // Adjacent Journeys often share a Home-in-Ukraine circle; keep the newer Story.
        var claimed = Set<String>()
        let exclusiveJourneys = journeys.map { story in
            let ids = story.momentIDs.filter { claimed.insert($0).inserted }
            return CurationStory(id: story.id, start: story.start, end: story.end,
                momentIDs: ids, placeID: story.placeID, kind: story.kind, stops: story.stops)
        }
        let outings = ConservativeStoryBuilder.stories(moments, calendar: calendar, placeID: placeID)
            .filter { claimed.isDisjoint(with: $0.momentIDs) }
        claimed.formUnion(outings.flatMap(\.momentIDs))
        let experimental = ExperimentalUnlocatedJourneyBuilder.stories(
            moments: leftoverMoments,
            photos: leftoverPhotos,
            claimedMomentIDs: claimed)
        return (exclusiveJourneys + outings + experimental).sorted { $0.start > $1.start }
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
