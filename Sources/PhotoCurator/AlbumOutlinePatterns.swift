import Foundation

/// Structural album-outline conventions observed in the owner's Photos library
/// (year folders, nested place folders, season buckets, bike outings). Used for
/// candidate scoring and review guidance — never ships Stories by itself.
enum AlbumOutlinePatterns {
    enum Signal: String, Equatable, Sendable {
        case yearFolder
        case nestedPlaceFolder
        case seasonBucket
        case bikeOuting
        case placeLikeTitle
        case technicalSkip
        case peopleLikeTitle
        case eventLikeTitle
    }

    static func signals(title: String, folderNames: [String]) -> Set<Signal> {
        var result = Set<Signal>()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let folders = folderNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if folders.contains(where: isYearLike) { result.insert(.yearFolder) }
        if folders.contains(where: { looksPlaceLike($0) && !isYearLike($0) && !isSeasonBucket($0) }) {
            result.insert(.nestedPlaceFolder)
        }
        if isSeasonBucket(trimmed) { result.insert(.seasonBucket) }
        if isBikeOuting(trimmed) { result.insert(.bikeOuting) }
        if looksPlaceLike(trimmed) && !isSeasonBucket(trimmed) && !isBikeOuting(trimmed) {
            result.insert(.placeLikeTitle)
        }
        if isTechnicalSkip(trimmed) { result.insert(.technicalSkip) }
        if looksPeopleLike(trimmed) { result.insert(.peopleLikeTitle) }
        if looksEventLike(trimmed) { result.insert(.eventLikeTitle) }
        return result
    }

    /// Heuristic score delta for review-gated Story candidacy. Season buckets and
    /// technical albums are down-ranked; place nests and bike outings are up-ranked.
    static func scoreAdjustment(title: String, folderNames: [String]) -> (delta: Double, reasons: [String]) {
        let signals = signals(title: title, folderNames: folderNames)
        var delta = 0.0
        var reasons: [String] = []
        if signals.contains(.yearFolder) {
            delta += 0.15
            reasons.append("year folder")
        }
        if signals.contains(.nestedPlaceFolder) {
            delta += 0.2
            reasons.append("nested under place folder")
        }
        if signals.contains(.placeLikeTitle) {
            delta += 0.2
            reasons.append("place-like title")
        }
        if signals.contains(.bikeOuting) {
            delta += 0.25
            reasons.append("bike outing title")
        }
        if signals.contains(.seasonBucket) {
            delta -= 0.35
            reasons.append("season bucket")
        }
        if signals.contains(.technicalSkip) {
            delta -= 0.5
            reasons.append("technical or utility album")
        }
        if signals.contains(.peopleLikeTitle) {
            delta -= 0.15
            reasons.append("people-like title")
        }
        if signals.contains(.eventLikeTitle) {
            delta -= 0.1
            reasons.append("event-like title")
        }
        return (delta, reasons)
    }

    static func isYearLike(_ value: String) -> Bool {
        value.range(of: #"^(19|20)\d{2}(-\d{2,4})?$"#, options: .regularExpression) != nil
    }

    static func isSeasonBucket(_ value: String) -> Bool {
        let lowered = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let seasons = ["winter", "spring", "summer", "fall", "autumn",
                       "зима", "весна", "лето", "літо", "осень", "осінь"]
        guard seasons.contains(where: { lowered.contains($0) }) else { return false }
        // "Summer 2012 Mariupol" is place+season, not a pure bucket.
        let stripped = seasons.reduce(lowered) { partial, season in
            partial.replacingOccurrences(of: season, with: " ")
        }
        let residual = stripped
            .replacingOccurrences(of: #"\b(19|20)\d{2}\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[&/\-_,.]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .filter { !$0.isEmpty }
        return residual.isEmpty
    }

    static func isBikeOuting(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return lowered.hasPrefix("velosypedy")
            || lowered.hasPrefix("ровери")
            || lowered.contains("velosypedy-")
            || lowered.contains("ровери:")
    }

    static func isTechnicalSkip(_ value: String) -> Bool {
        let lowered = value.lowercased()
        let needles = ["from iphone", "photosfromvideo", "photoframe", "powerbook",
                       "unsorted", "не сортирован", "full size", "calendar -",
                       "backyard tiles", "last favorites"]
        if needles.contains(where: { lowered.contains($0) }) { return true }
        // Address-like apartment labels (e.g. "Скорини 26 кв. 6").
        if lowered.range(of: #"\bкв\.?\s*\d+"#, options: .regularExpression) != nil { return true }
        if lowered.contains("vaartuigenlaan") { return true }
        return false
    }

    static func looksPlaceLike(_ value: String) -> Bool {
        if isSeasonBucket(value) || isTechnicalSkip(value) || isBikeOuting(value) { return false }
        let lowered = value.lowercased()
        let tokens = ["usa", "uk", "france", "italy", "spain", "germany", "ukraine", "lviv",
                      "new york", "chicago", "glasgow", "paris", "rome", "krakow", "kyiv", "kiev",
                      "odessa", "odesa", "mariupol", "bukovel", "буковель", "dragobrat", "slavsko",
                      "frankivsk", "frankovsk", "volovets", "borzhava", "grabovec", "carpath", "карпат",
                      "trip", "travel", "vacation", "holiday", "tour", "city", "поездка", "поїздка",
                      "замки", "море", "горы"]
        if tokens.contains(where: { lowered.contains($0) }) { return true }
        if value.unicodeScalars.contains(where: { $0.value >= 0x0400 && $0.value <= 0x04FF }) {
            // Cyrillic alone is weak; require another place/trip cue or multi-token place folder names.
            if tokens.contains(where: { lowered.contains($0) }) { return true }
        }
        let parts = value.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
        return parts.count >= 2 && parts.contains(where: { part in
            part.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil
        })
    }

    static func looksPeopleLike(_ value: String) -> Bool {
        let lowered = value.lowercased()
        if isSeasonBucket(value) || isBikeOuting(value) || isTechnicalSkip(value) { return false }
        let cues = ["birthday", "день рождения", "день народження", "wedding", "marriage",
                    "кстини", "христини", "hrystyny", "krestiny", "utrennik", "childhood",
                    "white dress"]
        return cues.contains(where: { lowered.contains($0) })
    }

    static func looksEventLike(_ value: String) -> Bool {
        let lowered = value.lowercased()
        let cues = ["new year", "christmas", "easter", "корпоратив", "corporate", "softserve",
                    "wedding", "marriage", "birthday", "шашлик", "shashlyk", "shahlik", "kumpel"]
        return cues.contains(where: { lowered.contains($0) })
    }
}
