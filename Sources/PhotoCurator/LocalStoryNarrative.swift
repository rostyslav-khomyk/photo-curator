import Foundation

/// Evidence for grounded Story title/synopsis candidates. Built only from
/// already-persisted Journey dossier fields — never pixels, people, or invented places.
struct StoryNarrativeMetadata: Codable, Equatable, Sendable {
    let title: String
    let kind: StoryKind
    let dateLabel: String
    let momentCount: Int
    let photoCount: Int
    let stopPlaces: [String]
    let transportModes: [String]
    let uncertainNotes: [String]
}

struct StoryNarrativeText: Codable, Equatable, Sendable {
    let title: String
    let synopsis: String
}

enum StoryNarrativeUncertainty {
    /// Short explainable notes from stop/leg evidence; empty when the Story looks settled.
    static func notes(title: String, stops: [JourneyStopEvidence]) -> [String] {
        var notes: [String] = []
        if title.hasPrefix("Journey from ") {
            notes.append("Destination title is still resolving from stop places.")
        }
        let unnamed = stops.filter {
            ($0.place?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        }.count
        if unnamed > 0 {
            notes.append(unnamed == 1
                ? "One stop still lacks a city or region label."
                : "\(unnamed) stops still lack city or region labels.")
        }
        let weakLegs = stops.compactMap(\.transportFromPrevious).filter {
            $0.mode == .unknown || $0.confidence < 0.5
        }.count
        if weakLegs > 0 {
            notes.append(weakLegs == 1
                ? "One travel leg is unspecified or low-confidence."
                : "\(weakLegs) travel legs are unspecified or low-confidence.")
        }
        return notes
    }

    static func line(title: String, stops: [JourneyStopEvidence]) -> String? {
        let values = notes(title: title, stops: stops)
        guard !values.isEmpty else { return nil }
        return values.joined(separator: " ")
    }
}

/// Deterministic Story narrative candidates; optional on-device model only picks an index.
enum LocalStoryNarrative {
    static let version = "story-narrative-v1"

    static func metadata(for story: StorySummary,
                         dateStyle: Date.FormatStyle = .dateTime.month().day().year()) -> StoryNarrativeMetadata {
        let places = story.stops.compactMap { stop -> String? in
            let place = stop.place?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return place.isEmpty || PlaceNaming.looksStreetLevel(place) ? nil : place
        }
        var uniquePlaces: [String] = []
        for place in places where !uniquePlaces.contains(where: { $0.caseInsensitiveCompare(place) == .orderedSame }) {
            uniquePlaces.append(place)
        }
        let modes = story.stops.compactMap(\.transportFromPrevious).map { leg -> String in
            switch leg.mode {
            case .air: return "air"
            case .overland: return "overland"
            case .unknown: return "unspecified"
            }
        }
        let dateLabel: String
        if Calendar.current.isDate(story.start, inSameDayAs: story.end) {
            dateLabel = story.start.formatted(dateStyle)
        } else {
            dateLabel = "\(story.start.formatted(dateStyle)) – \(story.end.formatted(dateStyle))"
        }
        return StoryNarrativeMetadata(
            title: story.title, kind: story.kind, dateLabel: dateLabel,
            momentCount: story.momentIDs.count, photoCount: story.photoCount,
            stopPlaces: uniquePlaces, transportModes: modes,
            uncertainNotes: StoryNarrativeUncertainty.notes(title: story.title, stops: story.stops))
    }

    static func candidates(_ metadata: StoryNarrativeMetadata) throws -> [StoryNarrativeText] {
        guard !metadata.title.isEmpty, metadata.title.count <= 200,
              metadata.momentCount > 0, metadata.photoCount > 0,
              metadata.stopPlaces.count <= 24,
              metadata.stopPlaces.allSatisfy({ !$0.isEmpty && $0.count <= 80 }) else {
            throw NarrativeFailure.invalidMetadata
        }
        let momentWord = metadata.momentCount == 1 ? "Moment" : "Moments"
        let photoWord = metadata.photoCount == 1 ? "photo" : "photos"
        let counts = "\(metadata.momentCount) \(momentWord) · \(metadata.photoCount) \(photoWord)"
        var options: [StoryNarrativeText] = []

        if metadata.kind == .journey {
            let route: String
            switch metadata.stopPlaces.count {
            case 0:
                route = metadata.title
            case 1:
                route = metadata.stopPlaces[0]
            case 2:
                route = "\(metadata.stopPlaces[0]) → \(metadata.stopPlaces[1])"
            default:
                route = "\(metadata.stopPlaces[0]) → \(metadata.stopPlaces[metadata.stopPlaces.count - 1]) via \(metadata.stopPlaces.count - 2) stops"
            }
            let transport: String
            let air = metadata.transportModes.filter { $0 == "air" }.count
            let overland = metadata.transportModes.filter { $0 == "overland" }.count
            if air > 0 && overland > 0 {
                transport = "Air and overland travel between stops."
            } else if air > 0 {
                transport = "Includes air travel between stops."
            } else if overland > 0 {
                transport = "Overland travel between stops."
            } else {
                transport = "Travel mode between some stops is still unspecified."
            }
            options.append(StoryNarrativeText(
                title: metadata.title,
                synopsis: "\(route) · \(metadata.dateLabel). \(counts). \(transport)"))
            if !metadata.stopPlaces.isEmpty {
                let via = metadata.stopPlaces.prefix(4).joined(separator: ", ")
                options.append(StoryNarrativeText(
                    title: metadata.title,
                    synopsis: "A Journey through \(via) (\(metadata.dateLabel)). \(counts)."))
            }
        } else {
            let place = metadata.stopPlaces.first.map { " around \($0)" } ?? ""
            options.append(StoryNarrativeText(
                title: metadata.title,
                synopsis: "\(metadata.title)\(place) · \(metadata.dateLabel). \(counts)."))
        }

        if !metadata.uncertainNotes.isEmpty {
            options.append(StoryNarrativeText(
                title: metadata.title,
                synopsis: "\(options[0].synopsis) \(metadata.uncertainNotes.joined(separator: " "))"))
        }
        return options
    }

    static func suggest(_ metadata: StoryNarrativeMetadata,
                        model: LocalNarrativeModel) async throws -> StoryNarrativeText {
        let options = try candidates(metadata)
        guard await model.isAvailable() else { return options[0] }
        do {
            let mapped = options.map { MomentNarrativeText(title: $0.title, description: $0.synopsis) }
            let index = try await model.choose(from: mapped)
            guard options.indices.contains(index) else { return options[0] }
            return options[index]
        } catch {
            return options[0]
        }
    }
}
