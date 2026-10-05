import Foundation
import CoreLocation
import CryptoKit

struct IndexedPhoto: Equatable, Identifiable, Sendable {
    let id: String
    let created: Date?
    let modified: Date?
    let latitude: Double?
    let longitude: Double?
    let favorite: Bool
    let width: Int
    let height: Int
    var similarityCategory: SimilarityCategory? = nil
    /// Public PhotoKit adjustment presence. Defaults preserve older catalog payloads.
    var hasAdjustments: Bool = false
    var adjustmentTimestamp: Date? = nil
    var adjustmentFormatIdentifier: String? = nil
    /// Library import time when available (macOS 26+). Not a capture date.
    var addedDate: Date? = nil
    /// `PHAsset.Rating.rawValue`; 0 means unset / older OS.
    var rating: Int = 0
    var burstIdentifier: String? = nil
    /// PhotoKit/EXIF camera identity when known. Never a hardcoded family roster —
    /// only a signal for tests and later route reconciliation.
    var cameraMake: String? = nil
    var cameraModel: String? = nil
    /// PhotoKit resource UTI when known (RAW vs JPEG). Used with camera fields to
    /// spot dedicated still cameras that will never grow GPS.
    var sourceUTI: String? = nil

    /// Job and cache identity. Still includes modificationDate until content adoption rebases it.
    var analysisRevision: String {
        "\(modified?.timeIntervalSince1970.description ?? "unknown")-\(width)x\(height)"
    }

    /// Pixel/edit fingerprint that ignores metadata-only modificationDate churn.
    var visualContentRevision: String {
        let adj = hasAdjustments ? "1" : "0"
        let timestamp = adjustmentTimestamp.map { String($0.timeIntervalSince1970) } ?? "none"
        let format = adjustmentFormatIdentifier ?? ""
        return "\(width)x\(height)|\(adj)|\(timestamp)|\(format)"
    }
}

extension IndexedPhoto: Codable {
    enum CodingKeys: String, CodingKey {
        case id, created, modified, latitude, longitude, favorite, width, height
        case similarityCategory, hasAdjustments, adjustmentTimestamp, adjustmentFormatIdentifier
        case addedDate, rating, burstIdentifier, cameraMake, cameraModel, sourceUTI
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        created = try values.decodeIfPresent(Date.self, forKey: .created)
        modified = try values.decodeIfPresent(Date.self, forKey: .modified)
        latitude = try values.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try values.decodeIfPresent(Double.self, forKey: .longitude)
        favorite = try values.decode(Bool.self, forKey: .favorite)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        similarityCategory = try values.decodeIfPresent(SimilarityCategory.self, forKey: .similarityCategory)
        // Older index payloads predate adjustment/import fields; synthesized Codable would throw keyNotFound.
        hasAdjustments = try values.decodeIfPresent(Bool.self, forKey: .hasAdjustments) ?? false
        adjustmentTimestamp = try values.decodeIfPresent(Date.self, forKey: .adjustmentTimestamp)
        adjustmentFormatIdentifier = try values.decodeIfPresent(String.self, forKey: .adjustmentFormatIdentifier)
        addedDate = try values.decodeIfPresent(Date.self, forKey: .addedDate)
        rating = try values.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        burstIdentifier = try values.decodeIfPresent(String.self, forKey: .burstIdentifier)
        cameraMake = try values.decodeIfPresent(String.self, forKey: .cameraMake)
        cameraModel = try values.decodeIfPresent(String.self, forKey: .cameraModel)
        sourceUTI = try values.decodeIfPresent(String.self, forKey: .sourceUTI)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(created, forKey: .created)
        try values.encodeIfPresent(modified, forKey: .modified)
        try values.encodeIfPresent(latitude, forKey: .latitude)
        try values.encodeIfPresent(longitude, forKey: .longitude)
        try values.encode(favorite, forKey: .favorite)
        try values.encode(width, forKey: .width)
        try values.encode(height, forKey: .height)
        try values.encodeIfPresent(similarityCategory, forKey: .similarityCategory)
        try values.encode(hasAdjustments, forKey: .hasAdjustments)
        try values.encodeIfPresent(adjustmentTimestamp, forKey: .adjustmentTimestamp)
        try values.encodeIfPresent(adjustmentFormatIdentifier, forKey: .adjustmentFormatIdentifier)
        try values.encodeIfPresent(addedDate, forKey: .addedDate)
        try values.encode(rating, forKey: .rating)
        try values.encodeIfPresent(burstIdentifier, forKey: .burstIdentifier)
        try values.encodeIfPresent(cameraMake, forKey: .cameraMake)
        try values.encodeIfPresent(cameraModel, forKey: .cameraModel)
        try values.encodeIfPresent(sourceUTI, forKey: .sourceUTI)
    }
}

struct PhotoMoment: Identifiable, Codable, Sendable {
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

enum MomentGroupingState: String, Codable, Sendable {
    case preparing, conservative, ready, reviewed
}

enum MomentGrouping {
    /// Day-level candidates only. This does not perform aesthetic ranking.
    static func group(_ photos: [IndexedPhoto], calendar: Calendar = .current) -> [PhotoMoment] {
        let dated = photos.filter { $0.created != nil }.sorted {
            if $0.created == $1.created { return $0.id < $1.id }
            return $0.created! < $1.created!
        }
        let cadence = AdaptiveDayCadence.thresholds(dated, calendar: calendar)
        var groups: [[IndexedPhoto]] = []
        for photo in dated {
            if let previous = groups.last?.last,
               let date = photo.created, let previousDate = previous.created {
                let sameDay = calendar.isDate(date, inSameDayAs: previousDate)
                let gapLimit = AdaptiveDayCadence.gap(for: previousDate, thresholds: cadence, calendar: calendar)
                let closeInTime = date.timeIntervalSince(previousDate) <= gapLimit
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

enum CuratorPolicy {
    static func automaticPublicationEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "curatorAutoPublish") as? Bool ?? false
    }

    static func shouldContinueAnalysis(caughtUp: Bool, failedBeforeClaim: Bool) -> Bool {
        !caughtUp && !failedBeforeClaim
    }

    static func shouldRunMetadata(metadataReady: Bool, reconciliationNeeded: Bool,
                                  reconciliationDue: Bool) -> Bool {
        if !metadataReady { return true }
        return reconciliationNeeded && reconciliationDue
    }

    static func mayRunAutomaticPublication(idleSeconds: Double) -> Bool {
        idleSeconds.isFinite && idleSeconds >= 120
    }
}
