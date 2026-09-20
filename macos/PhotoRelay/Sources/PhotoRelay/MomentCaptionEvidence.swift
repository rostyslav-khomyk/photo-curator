import Foundation
import NaturalLanguage

enum CaptionActivity: String, Codable, CaseIterable {
    case dining, gardens, historicInteriors, castle, waterside, city, collectibles, outdoors

    var title: String {
        switch self {
        case .dining: "Food and dining"
        case .gardens: "Flowers and gardens"
        case .historicInteriors: "Art and interiors"
        case .castle: "Castle views"
        case .waterside: "By the water"
        case .city: "Around town"
        case .collectibles: "A collection in detail"
        case .outdoors: "Time outdoors"
        }
    }
}

struct CaptionActivityEvidence: Codable, Equatable {
    let activity: CaptionActivity
    let assets: [String]
}

struct CaptionTextClue: Codable, Equatable {
    let text: String
    let asset: String
    let revision: String
    let confidence: Float
    let kind: String
}

struct MomentCaptionEvidence: Codable, Equatable {
    let inspected: Int
    let total: Int
    let excludedScreenshots: Int
    let mixedTimeline: Bool
    let activities: [CaptionActivityEvidence]
    let textClues: [CaptionTextClue]

    var primary: CaptionActivity? { mixedTimeline ? nil : activities.first?.activity }

    var explanation: String {
        var pieces: [String] = []
        if let clue = textClues.first {
            pieces.append("Includes text seen in photo: \"\(clue.text)\".")
        }
        if let act = activities.first {
            pieces.append("Focuses on \(act.activity.title.lowercased()).")
        }
        if pieces.isEmpty {
            return "Curated on your Mac from \(inspected) photos."
        }
        return pieces.joined(separator: " ")
    }
}

struct CaptionEvidencePhoto: Codable {
    let photo: IndexedPhoto
    let labels: [String]
    let lines: [PhotoTextLine]
}

/// Converts untrusted OCR into bounded activity evidence, never verified places.
enum CaptionEvidenceBuilder {
    static let version = "caption-evidence-v1"
    static let photoLimit = 128

    static func sample(_ photos: [IndexedPhoto]) -> [IndexedPhoto] {
        let ordered = photos.sorted {
            $0.created == $1.created ? $0.id < $1.id : ($0.created ?? .distantPast) < ($1.created ?? .distantPast)
        }
        guard ordered.count > photoLimit else { return ordered }
        return (0..<photoLimit).map { ordered[Int((Double($0) * Double(ordered.count - 1) / Double(photoLimit - 1)).rounded())] }
    }

    private static let businessWords: Set<String> = ["restaurant", "cafe", "cafeteria", "bistro", "brasserie", "tavern", "steakhouse", "ribhouse", "ristorante", "pizzeria"]
    private static let foodWords: Set<String> = ["menu", "menus", "starters", "desserts", "steak", "steaks", "burger", "burgers", "ribs", "soups", "salad", "fries", "appetizers", "dinner", "lunch", "dining", "restaurant", "ribhouse", "steakhouse", "pizzeria"]
    private static let privateWords: Set<String> = ["password", "passcode", "iban", "account", "invoice", "passport", "patient", "insurance", "payment", "balance", "rekening", "wachtwoord", "factuur", "bsn", "address", "phone", "telephone", "instructions", "assistant", "system", "ignore", "token"]

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
    }

    private static func privateText(_ text: String) -> Bool {
        !words(text).isDisjoint(with: privateWords) || text.contains("@")
            || text.range(of: #"\b[A-Z]{2}\d{2}[A-Z0-9 ]{10,}|\+?\d[\d ()-]{7,}\d"#, options: .regularExpression) != nil
    }

    private static func shortClue(_ text: String) -> String? {
        let value = text.replacingOccurrences(of: "®", with: "").replacingOccurrences(of: "™", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (5...60).contains(value.count), !privateText(value),
              value.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || " '-&".unicodeScalars.contains($0) }),
              (1...5).contains(value.split(separator: " ").count) else { return nil }
        // Names on signs/clothing are not person identification or useful automatic titles.
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = value
        var personal = false
        tagger.enumerateTags(in: value.startIndex..<value.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, _ in
            if tag == .personalName { personal = true }
            return !personal
        }
        return personal ? nil : value
    }

    static func build(_ inputs: [CaptionEvidencePhoto], moment: PhotoMoment) -> MomentCaptionEvidence {
        let allowed = Dictionary(moment.photos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var votes: [CaptionActivity: Set<String>] = [:]
        var clues: [CaptionTextClue] = []
        var seen = Set<String>()
        var accepted: [IndexedPhoto] = []
        var excluded = 0
        for input in inputs.prefix(photoLimit) {
            guard let photo = allowed[input.photo.id], photo.analysisRevision == input.photo.analysisRevision,
                  seen.insert(photo.id).inserted else { continue }
            guard photo.similarityCategory != .screenshots else { excluded += 1; continue }
            accepted.append(photo)
            let labels = Set(input.labels.map { $0.lowercased().replacingOccurrences(of: "_", with: " ") })
            let confident = input.lines.prefix(100).filter { $0.confidence.isFinite && $0.confidence >= 0.9 && $0.confidence <= 1 && $0.text.count <= 500 }
            // Unknown category from an old index waits for public PhotoKit metadata refresh.
            let safeOCR = photo.similarityCategory != nil && !confident.contains(where: { privateText($0.text) }) ? confident : []
            let tokens = safeOCR.reduce(into: Set<String>()) { $0.formUnion(words($1.text)) }
            func vote(_ activity: CaptionActivity, _ condition: Bool) {
                if condition { votes[activity, default: []].insert(photo.id) }
            }
            func has(_ values: Set<String>) -> Bool { !labels.isDisjoint(with: values) }
            let menu = tokens.intersection(foodWords).count >= 2
            let businessSign = has(["sign"]) && !tokens.isDisjoint(with: businessWords)
            vote(.dining, menu || businessSign || has(["food", "meal", "restaurant", "dining", "tableware"]))
            vote(.gardens, has(["flower", "flowers", "garden", "blossom", "flower arrangement", "flowerpot"]))
            vote(.historicInteriors, has(["painting", "chandelier", "sculpture"]) || (has(["art"]) && has(["decoration", "frame", "textile"])))
            vote(.castle, has(["castle"]))
            vote(.waterside, has(["boat", "beach", "sea", "ocean", "harbor", "waterfront", "sailboat"]))
            vote(.city, has(["street", "city", "cityscape", "urban", "building"]))
            vote(.collectibles, has(["doll", "figurine", "toy", "dolls"]))
            vote(.outdoors, has(["outdoor", "outdoors"]))

            if menu || businessSign {
                for index in safeOCR.indices where !words(safeOCR[index].text).isDisjoint(with: businessWords) {
                    var text = safeOCR[index].text
                    var confidence = safeOCR[index].confidence
                    // A brand split over two short lines is still attributed to one image.
                    if words(text).count == 1, index + 1 < safeOCR.count,
                       words(safeOCR[index + 1].text).count <= 2,
                       words(safeOCR[index + 1].text).isDisjoint(with: foodWords) {
                        text += " " + safeOCR[index + 1].text
                        confidence = min(confidence, safeOCR[index + 1].confidence)
                    }
                    if let value = shortClue(text) {
                        clues.append(CaptionTextClue(text: value, asset: photo.id, revision: photo.analysisRevision,
                            confidence: confidence, kind: businessSign ? "business sign" : "menu text"))
                        break
                    }
                }
            } else if (1...3).contains(safeOCR.count), has(["outdoor", "building", "sign", "castle", "sculpture"]) {
                for line in safeOCR {
                    if let value = shortClue(line.text), value.split(separator: " ").count <= 2 {
                        clues.append(CaptionTextClue(text: value, asset: photo.id, revision: photo.analysisRevision,
                            confidence: line.confidence, kind: "visible text"))
                    }
                }
            }
        }
        // One generic label is not an event. Retain rare but repeated specific context.
        let support = votes.compactMap { activity, assets -> CaptionActivityEvidence? in
            guard assets.count >= 2 else { return nil }
            return CaptionActivityEvidence(activity: activity, assets: assets.sorted())
        }.sorted {
            if ($0.activity == .outdoors) != ($1.activity == .outdoors) { return $1.activity == .outdoors }
            if $0.assets.count != $1.assets.count { return $0.assets.count > $1.assets.count }
            return $0.activity.rawValue < $1.activity.rawValue
        }
        let dates = accepted.compactMap(\.created).sorted()
        var left = 0, largest = 0
        for right in dates.indices {
            while dates[right].timeIntervalSince(dates[left]) > 60 { left += 1 }
            largest = max(largest, right - left + 1)
        }
        let mixed = moment.groupingKind != .scene && largest >= max(8, Int(ceil(Double(dates.count) * 0.7)))
            && !SceneMomentGrouping.sharedRecordedLocation(accepted)
        let sortedClues = clues.sorted {
            if ($0.kind == "visible text") != ($1.kind == "visible text") { return $1.kind == "visible text" }
            return $0.asset == $1.asset ? $0.text < $1.text : $0.asset < $1.asset
        }
        var unique = Set<String>()
        return MomentCaptionEvidence(inspected: seen.count - excluded, total: moment.photos.count,
            excludedScreenshots: excluded, mixedTimeline: mixed, activities: support,
            textClues: Array(sortedClues.filter { unique.insert($0.text.lowercased()).inserted }.prefix(3)))
    }
}
