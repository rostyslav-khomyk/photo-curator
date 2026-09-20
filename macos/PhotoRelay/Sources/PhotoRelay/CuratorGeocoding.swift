import Foundation
import CoreLocation
import Contacts
import MapKit

struct ResolvedPlace: Codable, Equatable, Sendable {
    let locality: String
    let subLocality: String?
    let administrativeArea: String?
    let country: String?
    var venueName: String?
    var meaningfulLabel: String?
    var address: String?
    var isExtrapolated: Bool
    var extrapolationDetails: String?

    init(locality: String, subLocality: String? = nil, administrativeArea: String? = nil, country: String? = nil,
         venueName: String? = nil, meaningfulLabel: String? = nil, address: String? = nil,
         isExtrapolated: Bool = false, extrapolationDetails: String? = nil) {
        self.locality = locality
        self.subLocality = subLocality
        self.administrativeArea = administrativeArea
        self.country = country
        self.venueName = venueName
        self.meaningfulLabel = meaningfulLabel
        self.address = address
        self.isExtrapolated = isExtrapolated
        self.extrapolationDetails = extrapolationDetails
    }

    var friendlyName: String {
        if let meaningfulLabel, !meaningfulLabel.isEmpty { return meaningfulLabel }
        if let venueName, !venueName.isEmpty { return venueName }
        if let sub = subLocality, !sub.isEmpty, sub != locality {
            return "\(sub), \(locality)"
        }
        return locality
    }
}

protocol GeocodingProvider: Sendable {
    func reverseGeocode(latitude: Double, longitude: Double) async -> ResolvedPlace?
}

final class AppleGeocodingProvider: GeocodingProvider {
    init() {}

    func reverseGeocode(latitude: Double, longitude: Double) async -> ResolvedPlace? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let top = placemarks.first, let locality = top.locality ?? top.name ?? top.subLocality else {
                return nil
            }
            var venue = top.areasOfInterest?.first
            if venue == nil { venue = await nearbyVenue(latitude: latitude, longitude: longitude) }
            return ResolvedPlace(
                locality: locality,
                subLocality: top.subLocality,
                administrativeArea: top.administrativeArea,
                country: top.country,
                venueName: venue,
                address: top.postalAddress.map { CNPostalAddressFormatter.string(from: $0, style: .mailingAddress) }
            )
        } catch {
            return nil
        }
    }

    /// Accept only a very close, clearly best POI. Large attractions normally arrive
    /// through `areasOfInterest`; this fallback avoids guessing among nearby businesses.
    private func nearbyVenue(latitude: Double, longitude: Double) async -> String? {
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let request = MKLocalPointsOfInterestRequest(center: center, radius: 250)
        do {
            let items = try await MKLocalSearch(request: request).start().mapItems.compactMap { item -> (MKMapItem, Double)? in
                guard let location = item.placemark.location else { return nil }
                return (item, location.distance(from: CLLocation(latitude: latitude, longitude: longitude)))
            }.sorted { $0.1 < $1.1 }
            guard let first = items.first, first.1 <= 100 else { return nil }
            if items.count > 1, items[1].1 - first.1 < 50 { return nil }
            return first.0.name
        } catch {
            return nil
        }
    }
}

/// Thread-safe reverse geocoding service with in-memory cache.
actor CuratorGeocodingService {
    static let shared = CuratorGeocodingService()

    private let provider: GeocodingProvider
    private let meaningfulPlaces: @Sendable () -> [MeaningfulPlace]
    private var cache: [String: ResolvedPlace] = [:]
    private var activeLookups: [String: Task<ResolvedPlace?, Never>] = [:]

    init(provider: GeocodingProvider = AppleGeocodingProvider(),
         meaningfulPlaces: @escaping @Sendable () -> [MeaningfulPlace] = { MeaningfulPlacesStore.snapshot() }) {
        self.provider = provider
        self.meaningfulPlaces = meaningfulPlaces
    }

    /// Generates a cache key rounded to ~100m (3 decimal places) to group nearby queries.
    private func cacheKey(lat: Double, lon: Double) -> String {
        String(format: "%.3f,%.3f", lat, lon)
    }

    func place(for latitude: Double, longitude: Double) async -> ResolvedPlace? {
        let meaningful = meaningfulPlaces().filter { $0.contains(latitude: latitude, longitude: longitude) }
            .min { lhs, rhs in
                CLLocation(latitude: lhs.latitude, longitude: lhs.longitude).distance(from: CLLocation(latitude: latitude, longitude: longitude)) <
                CLLocation(latitude: rhs.latitude, longitude: rhs.longitude).distance(from: CLLocation(latitude: latitude, longitude: longitude))
            }
        let key = cacheKey(lat: latitude, lon: longitude)
        if let cached = cache[key] {
            return applying(meaningful, to: cached)
        }
        if let existing = activeLookups[key] {
            return await existing.value
        }

        let task = Task<ResolvedPlace?, Never> {
            let result = await provider.reverseGeocode(latitude: latitude, longitude: longitude)
            return result
        }
        activeLookups[key] = task
        let resolved = await task.value
        activeLookups.removeValue(forKey: key)
        if let resolved {
            cache[key] = resolved
        }
        return resolved.map { applying(meaningful, to: $0) }
    }

    private func applying(_ meaningful: MeaningfulPlace?, to place: ResolvedPlace) -> ResolvedPlace {
        guard let meaningful else { return place }
        var result = place
        result.meaningfulLabel = meaningful.label
        result.address = meaningful.address
        return result
    }

    func place(for moment: PhotoMoment, allDayPhotos: [IndexedPhoto] = []) async -> ResolvedPlace? {
        // Find the median coordinate among photos that have GPS
        let gpsPhotos = moment.photos.compactMap { photo -> (lat: Double, lon: Double)? in
            guard let lat = photo.latitude, let lon = photo.longitude else { return nil }
            return (lat, lon)
        }
        if !gpsPhotos.isEmpty {
            let sortedLat = gpsPhotos.map(\.lat).sorted()
            let sortedLon = gpsPhotos.map(\.lon).sorted()
            let medianLat = sortedLat[sortedLat.count / 2]
            let medianLon = sortedLon[sortedLon.count / 2]
            guard let base = await place(for: medianLat, longitude: medianLon) else { return nil }
            let partial = gpsPhotos.count < moment.photos.count
            return ResolvedPlace(
                locality: base.locality,
                subLocality: base.subLocality,
                administrativeArea: base.administrativeArea,
                country: base.country,
                venueName: base.venueName,
                meaningfulLabel: base.meaningfulLabel,
                address: base.address,
                isExtrapolated: false,
                extrapolationDetails: partial ? "\(gpsPhotos.count) of \(moment.photos.count) photos have recorded GPS" : nil
            )
        }

        // If no GPS on moment photos, attempt extrapolation from other photos on the same day
        if !allDayPhotos.isEmpty,
           let extra = CuratorLocationExtrapolator.extrapolate(moment: moment, allDayPhotos: allDayPhotos),
           let base = await place(for: extra.latitude, longitude: extra.longitude) {
            return ResolvedPlace(
                locality: base.locality,
                subLocality: base.subLocality,
                administrativeArea: base.administrativeArea,
                country: base.country,
                venueName: base.venueName,
                meaningfulLabel: base.meaningfulLabel,
                address: base.address,
                isExtrapolated: true,
                extrapolationDetails: extra.reason
            )
        }

        return nil
    }
}

struct ExtrapolatedLocation: Equatable {
    let latitude: Double
    let longitude: Double
    let confidence: Double
    let sourceAssetId: String
    let reason: String

    init(latitude: Double, longitude: Double, confidence: Double, sourceAssetId: String, reason: String) {
        self.latitude = latitude
        self.longitude = longitude
        self.confidence = confidence
        self.sourceAssetId = sourceAssetId
        self.reason = reason
    }
}

/// Extrapolates GPS coordinates to photos/moments lacking direct GPS based on same-day signals.
enum CuratorLocationExtrapolator {
    static let confidenceThreshold = 0.70

    /// Attempts to extrapolate a location for a photo from other photos on the same day.
    static func extrapolate(
        target: IndexedPhoto,
        in moment: PhotoMoment,
        allDayPhotos: [IndexedPhoto],
        calendar: Calendar = .current
    ) -> ExtrapolatedLocation? {
        guard target.latitude == nil || target.longitude == nil,
              let targetDate = target.created else { return nil }

        // Signal 1: Intra-moment agreement
        let momentGPS = moment.photos.filter { $0.latitude != nil && $0.longitude != nil }
        if !momentGPS.isEmpty {
            let anchor = momentGPS[0]
            let anchorLoc = CLLocation(latitude: anchor.latitude!, longitude: anchor.longitude!)
            let allAgree = momentGPS.allSatisfy {
                let loc = CLLocation(latitude: $0.latitude!, longitude: $0.longitude!)
                return loc.distance(from: anchorLoc) <= 1000
            }
            if allAgree {
                var score = 0.50
                // Proximity to nearest GPS photo in the moment
                let nearest = momentGPS.min(by: {
                    abs($0.created?.timeIntervalSince(targetDate) ?? .infinity) <
                    abs($1.created?.timeIntervalSince(targetDate) ?? .infinity)
                })
                if let nearest, let diff = nearest.created?.timeIntervalSince(targetDate) {
                    let absDiff = abs(diff)
                    if absDiff <= 45 * 60 { score += 0.35 }
                    else if absDiff <= 2 * 3600 { score += 0.25 }
                    else if absDiff <= 4 * 3600 { score += 0.10 }
                } else {
                    score += 0.25
                }

                if score >= confidenceThreshold {
                    return ExtrapolatedLocation(
                        latitude: anchor.latitude!,
                        longitude: anchor.longitude!,
                        confidence: min(score, 0.95),
                        sourceAssetId: anchor.id,
                        reason: "Shared location from moment (\(momentGPS.count) photos with GPS agree within 1 km)"
                    )
                }
            }
        }

        // Signal 2 & 3: Inter-moment same-day timestamp proximity & bracketing
        let sameDayGPS = allDayPhotos.filter {
            guard let created = $0.created, $0.latitude != nil, $0.longitude != nil else { return false }
            return calendar.isDate(created, inSameDayAs: targetDate)
        }.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }

        guard !sameDayGPS.isEmpty else { return nil }

        let before = sameDayGPS.last(where: { ($0.created ?? .distantPast) <= targetDate })
        let after = sameDayGPS.first(where: { ($0.created ?? .distantFuture) >= targetDate })

        var score = 0.0
        var chosenAnchor: IndexedPhoto?

        // Check sandwich bracketing
        if let b = before, let a = after,
           let bCreated = b.created, let aCreated = a.created {
            let bLoc = CLLocation(latitude: b.latitude!, longitude: b.longitude!)
            let aLoc = CLLocation(latitude: a.latitude!, longitude: a.longitude!)
            let distanceBetween = bLoc.distance(from: aLoc)

            if distanceBetween <= 2000 {
                score += 0.25 // Confirmed no city-hopping between before and after
            } else if distanceBetween > 15_000 {
                // Conflicting distant locations; in transit, do not extrapolate
                return nil
            }

            let bDiff = abs(targetDate.timeIntervalSince(bCreated))
            let aDiff = abs(targetDate.timeIntervalSince(aCreated))
            chosenAnchor = bDiff <= aDiff ? b : a
            let minDiff = min(bDiff, aDiff)

            if minDiff <= 45 * 60 { score += 0.50 }
            else if minDiff <= 2 * 3600 { score += 0.45 }
            else if minDiff <= 4 * 3600 { score += 0.20 }
        } else if let single = before ?? after, let sCreated = single.created {
            chosenAnchor = single
            let diff = abs(targetDate.timeIntervalSince(sCreated))
            if diff <= 45 * 60 { score += 0.70 }
            else if diff <= 2 * 3600 { score += 0.40 }
            else if diff <= 4 * 3600 { score += 0.15 }
        }

        guard let anchor = chosenAnchor,
              let lat = anchor.latitude,
              let lon = anchor.longitude,
              score >= confidenceThreshold else {
            return nil
        }

        return ExtrapolatedLocation(
            latitude: lat,
            longitude: lon,
            confidence: min(score, 0.90),
            sourceAssetId: anchor.id,
            reason: "Extrapolated from nearby photos on the same day"
        )
    }

    /// Extrapolates a location for an entire moment if all photos lack GPS.
    static func extrapolate(
        moment: PhotoMoment,
        allDayPhotos: [IndexedPhoto],
        calendar: Calendar = .current
    ) -> ExtrapolatedLocation? {
        // If moment already has GPS, no extrapolation needed
        if moment.hasLocation {
            return nil
        }
        guard let first = moment.photos.first else { return nil }
        return extrapolate(target: first, in: moment, allDayPhotos: allDayPhotos, calendar: calendar)
    }
}
