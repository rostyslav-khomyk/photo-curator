import Foundation
import CoreLocation
import CryptoKit

struct IndexedPhoto: Codable, Equatable, Identifiable {
    let id: String
    let created: Date?
    let modified: Date?
    let latitude: Double?
    let longitude: Double?
    let favorite: Bool
    let width: Int
    let height: Int
    var similarityCategory: SimilarityCategory? = nil

    var analysisRevision: String {
        "\(modified?.timeIntervalSince1970.description ?? "unknown")-\(width)x\(height)"
    }
}

struct PhotoMoment: Identifiable, Codable {
    let id: String
    let start: Date
    let end: Date
    let photos: [IndexedPhoto]
    var selection: MomentSelection? = nil
    var narrative: MomentNarrative? = nil
    var contextSource: String? = nil
    var reviewedGroupTitle: String? = nil
    var groupingSource: String? = nil
    var groupingReason: String? = nil
    var groupingState: MomentGroupingState? = nil
    var groupingKind: AutomaticMomentSegmentKind? = nil
    var displayEvidence: [String: PhotoDisplayEvidence]? = nil
    var continuityReason: String? = nil
    var publishedAlbumID: String? = nil
    var publishedDate: Date? = nil

    var hasLocation: Bool { photos.contains { $0.latitude != nil && $0.longitude != nil } }
    var favorites: Int { photos.filter(\.favorite).count }
}

enum MomentGroupingState: String, Codable {
    case preparing, conservative, ready, reviewed
}

enum MomentGrouping {
    /// Day-level candidates only. This does not perform aesthetic ranking.
    static func group(_ photos: [IndexedPhoto], calendar: Calendar = .current) -> [PhotoMoment] {
        let dated = photos.filter { $0.created != nil }.sorted {
            if $0.created == $1.created { return $0.id < $1.id }
            return $0.created! < $1.created!
        }
        var groups: [[IndexedPhoto]] = []
        for photo in dated {
            if let previous = groups.last?.last,
               let date = photo.created, let previousDate = previous.created {
                let sameDay = calendar.isDate(date, inSameDayAs: previousDate)
                let closeInTime = date.timeIntervalSince(previousDate) <= 2 * 3600
                let distance: Double? = {
                    guard let lat = photo.latitude, let lon = photo.longitude,
                          let otherLat = previous.latitude, let otherLon = previous.longitude else { return nil }
                    return CLLocation(latitude: lat, longitude: lon).distance(
                        from: CLLocation(latitude: otherLat, longitude: otherLon))
                }()
                if sameDay && closeInTime && (distance == nil || distance! <= 10_000) {
                    groups[groups.count - 1].append(photo)
                    continue
                }
            }
            groups.append([photo])
        }
        return groups.map { members in
            // A deterministic candidate ID, not yet a durable published-album identity.
            let anchor = members.map(\.id).min()!
            let id = SHA256.hash(data: Data(anchor.utf8)).map { String(format: "%02x", $0) }.joined()
            return PhotoMoment(id: id, start: members.first!.created!, end: members.last!.created!, photos: members)
        }.reversed()
    }
}

enum CuratorPeriod: String, CaseIterable, Identifiable {
    case lastWeek, lastMonth, thisSpring, custom
    var id: Self { self }
    var title: String {
        switch self {
        case .lastWeek: "Last 7 days"
        case .lastMonth: "Last 30 days"
        case .thisSpring: "This spring"
        case .custom: "Custom dates"
        }
    }

    func interval(now: Date, calendar: Calendar = .current, customStart: Date, customEnd: Date) -> DateInterval? {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        switch self {
        case .lastWeek, .lastMonth:
            let start = calendar.date(byAdding: .day, value: self == .lastWeek ? -7 : -30, to: tomorrow)!
            return DateInterval(start: start, end: tomorrow)
        case .thisSpring:
            let year = calendar.component(.year, from: now)
            let start = calendar.date(from: DateComponents(year: year, month: 3, day: 1))!
            let end = calendar.date(from: DateComponents(year: year, month: 6, day: 1))!
            return DateInterval(start: start, end: end)
        case .custom:
            let start = calendar.startOfDay(for: customStart)
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: customEnd))!
            return start < end ? DateInterval(start: start, end: end) : nil
        }
    }
}

enum CuratorPolicy {
    static func shouldContinueAnalysis(caughtUp: Bool, failedBeforeClaim: Bool) -> Bool {
        !caughtUp && !failedBeforeClaim
    }

    static func shouldRunMetadata(foreground: Bool, metadataReady: Bool, reconciliationNeeded: Bool,
                                  reconciliationDue: Bool) -> Bool {
        if !metadataReady { return true }
        return !foreground && reconciliationNeeded && reconciliationDue
    }

    static func mayRunAutomaticPublication(idleSeconds: Double, foreground: Bool) -> Bool {
        foreground || (idleSeconds.isFinite && idleSeconds >= 120)
    }

    static func waitingReason(idleSeconds: Double, lowPower: Bool, hot: Bool, syncBusy: Bool, foreground: Bool) -> String? {
        if syncBusy { return "Waiting for your export or Google sync to finish." }
        if hot { return "Paused while your Mac is running hot." }
        if lowPower { return "Paused while Low Power Mode is on." }
        if !foreground && (!idleSeconds.isFinite || idleSeconds < 120) {
            return "Waiting until your Mac has been idle for 2 minutes."
        }
        return nil
    }
}
