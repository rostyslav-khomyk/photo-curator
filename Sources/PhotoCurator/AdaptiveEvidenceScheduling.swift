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
    /// Pre-consumer-GPS era in this library; geotags are often missing or weak.
    /// Matches the experimental unlocated Journey cutoff (2010-01-01).
    static let preGeotagYear = 2010

    /// Higher values are claimed first (`ORDER BY priority DESC`).
    static func analysisPriority(_ photo: IndexedPhoto, now: Date = Date(),
                                 calendar: Calendar = .current) -> Int {
        if photo.similarityCategory == .screenshots { return 5 }

        let hasGPS = hasValidGPS(photo)
        let year = photo.created.map { calendar.component(.year, from: $0) }
        let undated = photo.created == nil
        let preGeotag = undated || (year.map { $0 < preGeotagYear } ?? false)

        if !hasGPS && (preGeotag || looksDedicatedCamera(photo)) { return 80 }
        if !hasGPS {
            // Mid-band: burst/animated/live without GPS still beat GPS-rich refinement (≤35)
            // but sort under ordinary modern no-GPS photos (65) and pre-geotag / DSLR (80).
            if isMidBandThin(photo) { return 45 }
            return 65
        }
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

    /// Dedicated still cameras rarely geotag. Class signal only — not a family roster.
    static func looksDedicatedCamera(_ photo: IndexedPhoto) -> Bool {
        if looksPhoneCamera(photo.cameraMake, photo.cameraModel) { return false }
        if looksCameraRaw(photo.sourceUTI) { return true }
        let make = photo.cameraMake?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = photo.cameraModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !make.isEmpty || !model.isEmpty
    }

    static func looksPhoneCamera(_ make: String?, _ model: String?) -> Bool {
        let text = [make, model].compactMap { $0?.lowercased() }.joined(separator: " ")
        guard !text.isEmpty else { return false }
        let hints = ["iphone", "ipad", "ipod", "pixel", "galaxy", "android", "xiaomi",
                     "redmi", "huawei", "oneplus", "motorola", "xperia"]
        return hints.contains { text.contains($0) }
    }

    static func looksCameraRaw(_ uti: String?) -> Bool {
        guard let uti, !uti.isEmpty else { return false }
        let lower = uti.lowercased()
        return lower.contains("raw") || lower.contains("cr2") || lower.contains("cr3")
            || lower.contains("nef") || lower.contains("arw") || lower.contains("raf")
            || lower.contains("orf") || lower.contains("dng") || lower.contains("rw2")
    }

    /// Modern no-GPS captures that are weak Journey/OCR evidence relative to ordinary photos.
    static func isMidBandThin(_ photo: IndexedPhoto) -> Bool {
        if photo.burstIdentifier != nil { return true }
        switch photo.similarityCategory {
        case .bursts, .animated, .livePhotos: return true
        default: return false
        }
    }

    private static func isRecent(_ photo: IndexedPhoto, now: Date, calendar: Calendar) -> Bool {
        guard let created = photo.created else { return false }
        let years = calendar.dateComponents([.year], from: created, to: now).year ?? 0
        return years < 8
    }
}

/// Per-day Moment gap thresholds from within-day capture cadence (median × 8, clamped).
enum AdaptiveDayCadence {
    /// Used when a calendar day has no within-day consecutive pairs.
    static let fallbackGap: TimeInterval = 2 * 3600

    static func thresholds(_ photos: [IndexedPhoto], calendar: Calendar = .current) -> [Date: TimeInterval] {
        var gaps: [Date: [TimeInterval]] = [:]
        let dated = photos.filter { $0.created != nil }
        for pair in zip(dated, dated.dropFirst()) {
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

    static func gap(for date: Date, thresholds: [Date: TimeInterval],
                    calendar: Calendar = .current) -> TimeInterval {
        thresholds[calendar.startOfDay(for: date)] ?? fallbackGap
    }
}

/// Cadence for reverse-geocoding Journey stops on the analysis scheduler.
/// Normal soak interleaves geocode every 15th step; after a title wipe the sidebar
/// stays empty until cities refill, so recovery runs every step with a larger batch.
enum JourneyEnrichmentScheduling {
    static let normalCadence = 15
    static let recoveryCadence = 1
    static let normalLookups = 4
    static let recoveryLookups = 8
    static let recoveryMinShells = 8

    /// Sidebar looks empty while most Journey rows are still `Journey from Home` shells.
    static func needsTitleRecovery(journeyCount: Int, finalizedCount: Int) -> Bool {
        let shells = journeyCount - finalizedCount
        guard shells >= recoveryMinShells, journeyCount > 0 else { return false }
        return finalizedCount * 2 < journeyCount
    }

    static func cadence(journeyCount: Int, finalizedCount: Int) -> Int {
        needsTitleRecovery(journeyCount: journeyCount, finalizedCount: finalizedCount)
            ? recoveryCadence : normalCadence
    }

    static func maximumLookups(journeyCount: Int, finalizedCount: Int) -> Int {
        needsTitleRecovery(journeyCount: journeyCount, finalizedCount: finalizedCount)
            ? recoveryLookups : normalLookups
    }
}

/// How many Vision/thumbnail lanes may run in one analysis step.
/// One scheduler and one SQLite writer stay; only image evidence fans out.
enum AnalysisLaneBudget {
    static let maxLanes = 3

    static func lanes(process: ProcessInfo = .processInfo,
                      processorCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        capacity(lowPower: process.isLowPowerModeEnabled, thermal: process.thermalState,
                 processorCount: processorCount)
    }

    static func capacity(lowPower: Bool, thermal: ProcessInfo.ThermalState, processorCount: Int) -> Int {
        if lowPower { return 1 }
        switch thermal {
        case .serious, .critical: return 1
        case .fair: return min(2, maxLanes)
        default:
            return min(maxLanes, max(1, processorCount / 4))
        }
    }
}
