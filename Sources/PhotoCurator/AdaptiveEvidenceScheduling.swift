import Foundation
import CoreLocation

/// Schedules expensive local Vision/OCR where PhotoKit attributes are thin.
/// Metadata-rich GPS captures are deferred — not merely low-sorted — until thin
/// backlog clears or viewport focus boosts them. Curation is not a global cache fill.
enum AdaptiveEvidenceScheduling {
    /// Viewport / explicit user focus. Always outranks attribute-based scores.
    static let viewportPriority = 100
    /// Priorities at or below this are GPS-rich refinement; claim/OCR skip them while
    /// any higher-priority analysis work remains.
    static let refinementMaxPriority = 35
    /// Pre-consumer-GPS era; geotags are often missing or weak.
    static let preGeotagYear = 2008

    /// Higher values are claimed first (`ORDER BY priority DESC`).
    static func analysisPriority(_ photo: IndexedPhoto, now: Date = Date(),
                                 calendar: Calendar = .current) -> Int {
        if photo.similarityCategory == .screenshots { return 5 }

        let hasGPS = hasValidGPS(photo)
        let year = photo.created.map { calendar.component(.year, from: $0) }
        let undated = photo.created == nil
        let preGeotag = undated || (year.map { $0 < preGeotagYear } ?? false)

        if !hasGPS && preGeotag { return 80 }
        if !hasGPS { return 65 }
        if preGeotag { return 55 }
        // Recent capture with usable GPS: Moments/Journeys already form from metadata.
        // Vision/OCR are refinement only — never starve thin-attribute work for these.
        if isRecent(photo, now: now, calendar: calendar) { return 20 }
        return refinementMaxPriority
    }

    /// OCR/labels for metadata-rich GPS captures are refinement; soak must not run them
    /// while attribute-thin Vision/OCR work remains (viewport boosts still run).
    static func isMetadataRichRefinement(_ photo: IndexedPhoto, now: Date = Date(),
                                         calendar: Calendar = .current) -> Bool {
        analysisPriority(photo, now: now, calendar: calendar) <= refinementMaxPriority
    }

    static func hasValidGPS(_ photo: IndexedPhoto) -> Bool {
        guard let latitude = photo.latitude, let longitude = photo.longitude else { return false }
        return RecordedCoordinate.isValid(latitude: latitude, longitude: longitude)
    }

    private static func isRecent(_ photo: IndexedPhoto, now: Date, calendar: Calendar) -> Bool {
        guard let created = photo.created else { return false }
        let years = calendar.dateComponents([.year], from: created, to: now).year ?? 0
        return years < 8
    }
}
