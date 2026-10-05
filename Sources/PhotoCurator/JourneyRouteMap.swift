import Foundation
import MapKit
import SwiftUI
import AppKit

/// Pure map model from persisted Journey stop evidence. Straight-line legs are local;
/// optional MKDirections polylines are enrichment only and never required for curation.
struct JourneyRouteMapModel: Sendable {
    struct StopPin: Identifiable, Sendable {
        let id: Int
        let latitude: Double
        let longitude: Double
        let title: String
        let subtitle: String

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    struct LegPath: Sendable {
        let fromIndex: Int
        let toIndex: Int
        let mode: JourneyTransportMode
        let distanceMeters: Double
        let elapsedSeconds: TimeInterval
        let confidence: Double
        /// Geometric endpoints; road geometry may replace these in the map view.
        let latitudeA: Double
        let longitudeA: Double
        let latitudeB: Double
        let longitudeB: Double

        var geometricCoordinates: [CLLocationCoordinate2D] {
            [
                CLLocationCoordinate2D(latitude: latitudeA, longitude: longitudeA),
                CLLocationCoordinate2D(latitude: latitudeB, longitude: longitudeB)
            ]
        }

        var directionsCacheKey: String {
            String(format: "%.4f,%.4f->%.4f,%.4f", latitudeA, longitudeA, latitudeB, longitudeB)
        }

        var prefersRoadRoute: Bool {
            mode == .overland && distanceMeters >= 5_000 && distanceMeters <= 2_000_000
        }
    }

    let pins: [StopPin]
    let legs: [LegPath]

    static func from(stops: [JourneyStopEvidence],
                     homes: [MeaningfulPlace] = MeaningfulPlacesStore.snapshot()) -> JourneyRouteMapModel? {
        // Persisted evidence can still carry messenger GPS junk; clean before drawing.
        // Transport modes come from rebuild (`JourneyTransportInference`); do not re-derive
        // from stop timestamps here or multi-day stays flip air legs to overland.
        let cleaned = JourneyStopSanitizer.removingRouteNoise(stops, homes: homes)
        let located = cleaned.enumerated().compactMap { index, stop -> (Int, JourneyStopEvidence)? in
            guard RecordedCoordinate.isValid(latitude: stop.latitude, longitude: stop.longitude) else {
                return nil
            }
            return (index, stop)
        }
        guard located.count >= 2 else { return nil }

        let pins: [StopPin] = located.map { order, stop in
            let title = stop.place?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "Stop \(order + 1)"
            let range: String
            if Calendar.current.isDate(stop.start, inSameDayAs: stop.end) {
                range = stop.start.formatted(.dateTime.month(.abbreviated).day())
            } else {
                range = "\(stop.start.formatted(.dateTime.month(.abbreviated).day()))–\(stop.end.formatted(.dateTime.month(.abbreviated).day()))"
            }
            let subtitle = "\(range) · \(stop.photoCount) photos"
            return StopPin(id: order, latitude: stop.latitude, longitude: stop.longitude,
                           title: title, subtitle: subtitle)
        }

        var legs: [LegPath] = []
        for index in 1..<located.count {
            let previous = located[index - 1].1
            let stop = located[index].1
            let transport = stop.transportFromPrevious
            let distance = transport?.distanceMeters
                ?? CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                    .distance(from: CLLocation(latitude: stop.latitude, longitude: stop.longitude))
            let elapsed = transport?.elapsedSeconds
                ?? max(0, stop.start.timeIntervalSince(previous.end))
            legs.append(LegPath(
                fromIndex: located[index - 1].0,
                toIndex: located[index].0,
                mode: transport?.mode ?? .unknown,
                distanceMeters: distance,
                elapsedSeconds: elapsed,
                confidence: transport?.confidence ?? 0.25,
                latitudeA: previous.latitude,
                longitudeA: previous.longitude,
                latitudeB: stop.latitude,
                longitudeB: stop.longitude))
        }
        return JourneyRouteMapModel(pins: pins, legs: legs)
    }

    var region: MKCoordinateRegion {
        let latitudes = pins.map(\.latitude)
        let longitudes = pins.map(\.longitude)
        let minLat = latitudes.min() ?? 0
        let maxLat = latitudes.max() ?? 0
        let minLon = longitudes.min() ?? 0
        let maxLon = longitudes.max() ?? 0
        let spanLat = max(0.08, (maxLat - minLat) * 1.45)
        let spanLon = max(0.08, (maxLon - minLon) * 1.45)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon))
    }

    /// Screen-stable ring around the first and last stops, in meters.
    var endpointRadiusMeters: CLLocationDistance {
        let meters = region.span.latitudeDelta * 111_000 * 0.055
        return min(120_000, max(1_200, meters))
    }
}

enum JourneyEndpoint: Sendable {
    case none, start, end
}

/// Moments whose time range overlaps any selected Journey stop. Empty selection keeps the full list.
enum JourneyMomentFilter {
    static func applying(_ moments: [MomentSummary], stops: [JourneyStopEvidence],
                         selected: Set<Int>) -> [MomentSummary] {
        guard !selected.isEmpty else { return moments }
        let chosen = selected.compactMap { index -> JourneyStopEvidence? in
            stops.indices.contains(index) ? stops[index] : nil
        }
        guard !chosen.isEmpty else { return moments }
        return moments.filter { moment in
            chosen.contains { stop in
                moment.end >= stop.start && moment.start <= stop.end
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Bounded Apple Maps road geometries for overland Journey legs. Opt-in; never per-photo.
@MainActor
final class JourneyRoadRouteCache: ObservableObject {
    static let shared = JourneyRoadRouteCache()

    @Published private(set) var polylines: [String: [CLLocationCoordinate2D]] = [:]
    private var inflight = Set<String>()

    func coordinates(for key: String) -> [CLLocationCoordinate2D]? {
        polylines[key]
    }

    func prefetch(legs: [JourneyRouteMapModel.LegPath], enabled: Bool) {
        guard enabled else { return }
        for leg in legs where leg.prefersRoadRoute {
            let key = leg.directionsCacheKey
            guard polylines[key] == nil, !inflight.contains(key) else { continue }
            inflight.insert(key)
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(
                coordinate: CLLocationCoordinate2D(latitude: leg.latitudeA, longitude: leg.longitudeA)))
            request.destination = MKMapItem(placemark: MKPlacemark(
                coordinate: CLLocationCoordinate2D(latitude: leg.latitudeB, longitude: leg.longitudeB)))
            request.transportType = .automobile
            Task {
                defer { inflight.remove(key) }
                do {
                    let response = try await MKDirections(request: request).calculate()
                    guard let route = response.routes.first else { return }
                    var coords = Array(repeating: kCLLocationCoordinate2DInvalid,
                                       count: route.polyline.pointCount)
                    route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: coords.count))
                    let valid = coords.filter {
                        $0.latitude.isFinite && $0.longitude.isFinite
                            && abs($0.latitude) <= 90 && abs($0.longitude) <= 180
                    }
                    guard valid.count >= 2 else { return }
                    polylines[key] = valid
                } catch {
                    // Keep the straight-line fallback; directions are enrichment only.
                }
            }
        }
    }
}

final class JourneyStopAnnotation: MKPointAnnotation {
    var stopID: Int = 0
    var endpoint: JourneyEndpoint = .none
}

final class JourneyEndpointCircle: MKCircle {
    var endpoint: JourneyEndpoint = .start
}

final class JourneyDirectionArrowAnnotation: MKPointAnnotation {
    var mode: JourneyTransportMode = .unknown
    /// Radians, MapKit heading (0 = north, clockwise).
    var bearingRadians: CGFloat = 0
}

enum JourneyRouteStyle {
    static func color(for mode: JourneyTransportMode) -> NSColor {
        switch mode {
        case .air: return NSColor.systemPurple
        case .overland: return NSColor.systemBlue
        case .unknown: return NSColor.systemGray
        }
    }

    static func swiftUIColor(for mode: JourneyTransportMode) -> Color {
        switch mode {
        case .air: return .purple
        case .overland: return .blue
        case .unknown: return .secondary
        }
    }

    static func bearingRadians(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CGFloat {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return CGFloat(atan2(y, x))
    }

    static func midpoint(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D)
        -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2,
                               longitude: (a.longitude + b.longitude) / 2)
    }
}

struct JourneyRouteMapRepresentable: NSViewRepresentable {
    let model: JourneyRouteMapModel
    let roadRoutesEnabled: Bool
    var selectedStopIDs: Set<Int>
    var onToggleStop: (Int) -> Void
    @ObservedObject var roadCache: JourneyRoadRouteCache

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.isZoomEnabled = true
        map.isScrollEnabled = true
        map.isRotateEnabled = false
        map.showsCompass = false
        map.showsZoomControls = true
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.model = model
        context.coordinator.selectedStopIDs = selectedStopIDs
        context.coordinator.onToggleStop = onToggleStop
        roadCache.prefetch(legs: model.legs, enabled: roadRoutesEnabled)

        let pinSignature = model.pins.map { "\($0.id),\($0.latitude),\($0.longitude)" }.joined(separator: "|")
        let routeSignature = model.legs.map { leg in
            let road = roadRoutesEnabled ? (roadCache.coordinates(for: leg.directionsCacheKey)?.count ?? 0) : 0
            return "\(leg.directionsCacheKey)#\(road)#\(leg.mode.rawValue)"
        }.joined(separator: ";")
        if context.coordinator.pinSignature != pinSignature {
            context.coordinator.pinSignature = pinSignature
            context.coordinator.routeSignature = routeSignature
            rebuildAnnotations(map)
            rebuildOverlays(map)
            map.setRegion(model.region, animated: false)
        } else if context.coordinator.routeSignature != routeSignature {
            context.coordinator.routeSignature = routeSignature
            rebuildOverlays(map)
            rebuildDirectionArrows(map)
        }
        refreshFlags(map)
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    private func rebuildAnnotations(_ map: MKMapView) {
        map.removeAnnotations(map.annotations)
        let last = model.pins.count - 1
        for (offset, pin) in model.pins.enumerated() {
            let annotation = JourneyStopAnnotation()
            annotation.coordinate = pin.coordinate
            annotation.title = pin.title
            annotation.subtitle = pin.subtitle
            annotation.stopID = pin.id
            if offset == 0 { annotation.endpoint = .start }
            else if offset == last { annotation.endpoint = .end }
            map.addAnnotation(annotation)
        }
        rebuildDirectionArrows(map)
    }

    private func rebuildDirectionArrows(_ map: MKMapView) {
        let existing = map.annotations.compactMap { $0 as? JourneyDirectionArrowAnnotation }
        map.removeAnnotations(existing)
        for leg in model.legs {
            let coords: [CLLocationCoordinate2D]
            if roadRoutesEnabled, leg.prefersRoadRoute,
               let road = roadCache.coordinates(for: leg.directionsCacheKey), road.count >= 2 {
                coords = road
            } else {
                coords = leg.geometricCoordinates
            }
            guard coords.count >= 2 else { continue }
            let start = coords[0]
            let end = coords[coords.count - 1]
            let mid = coords.count >= 3
                ? coords[coords.count / 2]
                : JourneyRouteStyle.midpoint(from: start, to: end)
            let tangentFrom: CLLocationCoordinate2D
            let tangentTo: CLLocationCoordinate2D
            if coords.count >= 4 {
                let i = coords.count / 2
                tangentFrom = coords[max(0, i - 1)]
                tangentTo = coords[min(coords.count - 1, i + 1)]
            } else {
                tangentFrom = start
                tangentTo = end
            }
            let arrow = JourneyDirectionArrowAnnotation()
            arrow.coordinate = mid
            arrow.mode = leg.mode
            arrow.bearingRadians = JourneyRouteStyle.bearingRadians(from: tangentFrom, to: tangentTo)
            arrow.title = nil
            map.addAnnotation(arrow)
        }
    }

    private func rebuildOverlays(_ map: MKMapView) {
        map.removeOverlays(map.overlays)
        for leg in model.legs {
            let coords: [CLLocationCoordinate2D]
            if roadRoutesEnabled, leg.prefersRoadRoute,
               let road = roadCache.coordinates(for: leg.directionsCacheKey), road.count >= 2 {
                coords = road
            } else {
                coords = leg.geometricCoordinates
            }
            map.addOverlay(JourneyRoutePolyline.make(coordinates: coords, mode: leg.mode), level: .aboveRoads)
        }
        let radius = model.endpointRadiusMeters
        if let start = model.pins.first {
            let circle = JourneyEndpointCircle(center: start.coordinate, radius: radius)
            circle.endpoint = .start
            map.addOverlay(circle, level: .aboveRoads)
        }
        if model.pins.count >= 2, let end = model.pins.last {
            let circle = JourneyEndpointCircle(center: end.coordinate, radius: radius)
            circle.endpoint = .end
            map.addOverlay(circle, level: .aboveRoads)
        }
        rebuildDirectionArrows(map)
    }

    private func refreshFlags(_ map: MKMapView) {
        for annotation in map.annotations {
            guard let pin = annotation as? JourneyStopAnnotation,
                  let view = map.view(for: pin) else { continue }
            let selected = selectedStopIDs.contains(pin.stopID)
            view.image = JourneyFlagArtwork.image(selected: selected)
            view.setAccessibilityLabel(selected
                ? "\(pin.title ?? "Stop"), filter on"
                : "\(pin.title ?? "Stop"), filter off")
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var model: JourneyRouteMapModel
        var selectedStopIDs: Set<Int> = []
        var onToggleStop: (Int) -> Void = { _ in }
        var pinSignature = ""
        var routeSignature = ""
        init(model: JourneyRouteMapModel) { self.model = model }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let arrow = annotation as? JourneyDirectionArrowAnnotation {
                let reuse = "journey-leg-arrow"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuse)
                    ?? MKAnnotationView(annotation: arrow, reuseIdentifier: reuse)
                view.annotation = arrow
                view.canShowCallout = false
                view.image = JourneyFlagArtwork.directionArrow(
                    color: JourneyRouteStyle.color(for: arrow.mode),
                    bearingRadians: arrow.bearingRadians)
                view.displayPriority = .defaultHigh
                view.zPriority = .max
                view.isEnabled = false
                return view
            }
            guard let pin = annotation as? JourneyStopAnnotation else { return nil }
            let reuse = "journey-stop-flag"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuse)
                ?? MKAnnotationView(annotation: pin, reuseIdentifier: reuse)
            view.annotation = pin
            view.canShowCallout = true
            view.centerOffset = .zero
            let selected = selectedStopIDs.contains(pin.stopID)
            view.image = JourneyFlagArtwork.image(selected: selected)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let pin = view.annotation as? JourneyStopAnnotation else { return }
            let id = pin.stopID
            mapView.deselectAnnotation(pin, animated: false)
            onToggleStop(id)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? JourneyEndpointCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.lineWidth = 3
                let stroke = circle.endpoint == .start
                    ? NSColor.systemGreen : NSColor.systemOrange
                renderer.strokeColor = stroke.withAlphaComponent(0.95)
                renderer.fillColor = stroke.withAlphaComponent(0.12)
                return renderer
            }
            guard let line = overlay as? JourneyRoutePolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.lineWidth = line.mode == .air ? 3.25 : 3.75
            renderer.lineDashPattern = line.mode == .air ? [7, 5] : nil
            let base = JourneyRouteStyle.color(for: line.mode)
            renderer.strokeColor = base.withAlphaComponent(line.mode == .unknown ? 0.7 : 0.9)
            return renderer
        }
    }
}

enum JourneyFlagArtwork {
    static func image(selected: Bool) -> NSImage {
        let side: CGFloat = 30
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let inset = rect.insetBy(dx: 1.5, dy: 1.5)
            if selected {
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: inset)
                ring.lineWidth = 2.5
                ring.stroke()
            }
            (selected ? NSColor.systemOrange : NSColor.systemBlue).setFill()
            NSBezierPath(ovalIn: inset.insetBy(dx: selected ? 3 : 2, dy: selected ? 3 : 2)).fill()
            if let symbol = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)) {
                let tinted = symbol.tinted(with: .white)
                let icon = NSRect(x: inset.midX - 7, y: inset.midY - 7, width: 14, height: 14)
                tinted.draw(in: icon)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    static func directionArrow(color: NSColor, bearingRadians: CGFloat) -> NSImage {
        // Draw pointing north (0 = up), then rotate by map bearing.
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byRadians: -bearingRadians)
            transform.translateX(by: -rect.midX, yBy: -rect.midY)
            transform.concat()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.midX, y: rect.maxY - 3))
            path.line(to: NSPoint(x: rect.midX + 6, y: rect.minY + 5))
            path.line(to: NSPoint(x: rect.midX, y: rect.minY + 8))
            path.line(to: NSPoint(x: rect.midX - 6, y: rect.minY + 5))
            path.close()
            color.withAlphaComponent(0.95).setFill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 1
            path.fill()
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let copy = copy() as? NSImage ?? self
        copy.lockFocus()
        color.set()
        NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
        copy.unlockFocus()
        return copy
    }
}

final class JourneyRoutePolyline: MKPolyline {
    var mode: JourneyTransportMode = .unknown

    static func make(coordinates: [CLLocationCoordinate2D], mode: JourneyTransportMode) -> JourneyRoutePolyline {
        let line = JourneyRoutePolyline(coordinates: coordinates, count: coordinates.count)
        line.mode = mode
        return line
    }
}

struct JourneyRoutePanel: View {
    let stops: [JourneyStopEvidence]
    var selectedStopIDs: Set<Int> = []
    var onToggleStop: (Int) -> Void = { _ in }
    var onClearStops: () -> Void = {}
    @AppStorage("curatorJourneyRoadRoutes") private var roadRoutesEnabled = false
    @AppStorage("curator.journeyRouteMapHeight") private var mapHeight: Double = 210
    @ObservedObject private var roadCache = JourneyRoadRouteCache.shared
    @State private var resizeOrigin: Double?

    private static let minMapHeight: Double = 120
    private static let maxMapHeight: Double = 720

    var body: some View {
        if let model = JourneyRouteMapModel.from(stops: stops) {
            VStack(alignment: .leading, spacing: 6) {
                JourneyRouteMapRepresentable(model: model, roadRoutesEnabled: roadRoutesEnabled,
                                             selectedStopIDs: selectedStopIDs, onToggleStop: onToggleStop,
                                             roadCache: roadCache)
                    .frame(height: mapHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                mapResizeHandle
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(model.legs.enumerated()), id: \.offset) { _, leg in
                            legChip(leg, pins: model.pins)
                        }
                    }
                }
                if !selectedStopIDs.isEmpty {
                    HStack(spacing: 8) {
                        Text(filterSummary(model))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Clear", action: onClearStops)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                Text(roadRoutesEnabled
                     ? "Arrows show travel direction. Dashed purple = air, solid blue = overland, gray = unspecified. Green/orange circles mark start and end (often Home). Blue road paths when Apple Maps has them."
                     : "Arrows show travel direction. Dashed purple = air, solid blue = overland, gray = unspecified. Green/orange circles mark start and end (often Home). Enable road routes in Settings for overland paths.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Journey route map")
        }
    }

    private var mapResizeHandle: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 40, height: 4)
                .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 14)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if resizeOrigin == nil { resizeOrigin = mapHeight }
                    let next = (resizeOrigin ?? mapHeight) + value.translation.height
                    mapHeight = min(Self.maxMapHeight, max(Self.minMapHeight, next))
                }
                .onEnded { _ in resizeOrigin = nil }
        )
        .help("Drag to resize the Journey map")
        .accessibilityLabel("Resize Journey map")
        .accessibilityValue("\(Int(mapHeight)) points tall")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                mapHeight = min(Self.maxMapHeight, mapHeight + 40)
            case .decrement:
                mapHeight = max(Self.minMapHeight, mapHeight - 40)
            @unknown default:
                break
            }
        }
    }

    private func filterSummary(_ model: JourneyRouteMapModel) -> String {
        let names = model.pins.filter { selectedStopIDs.contains($0.id) }.map(\.title)
        let list = names.prefix(3).joined(separator: ", ")
        let extra = names.count > 3 ? " +\(names.count - 3)" : ""
        return names.count == 1
            ? "Showing Moments at \(list)"
            : "Showing Moments at \(list)\(extra)"
    }

    private func legChip(_ leg: JourneyRouteMapModel.LegPath, pins: [JourneyRouteMapModel.StopPin]) -> some View {
        let from = pins.first(where: { $0.id == leg.fromIndex })?.title ?? "Stop"
        let to = pins.first(where: { $0.id == leg.toIndex })?.title ?? "Stop"
        return HStack(spacing: 6) {
            Circle()
                .fill(JourneyRouteStyle.swiftUIColor(for: leg.mode))
                .frame(width: 8, height: 8)
            Image(systemName: leg.mode == .air ? "airplane" : (leg.mode == .overland ? "car" : "point.topleft.down.to.point.bottomright.curvepath"))
                .font(.caption)
                .foregroundStyle(JourneyRouteStyle.swiftUIColor(for: leg.mode))
            Text("\(from) → \(to)")
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(distanceLabel(leg.distanceMeters))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .help(modeHelp(leg))
    }

    private func distanceLabel(_ meters: Double) -> String {
        if meters >= 100_000 {
            return String(format: "%.0f km", meters / 1_000)
        }
        if meters >= 1_000 {
            return String(format: "%.1f km", meters / 1_000)
        }
        return String(format: "%.0f m", meters)
    }

    private func modeHelp(_ leg: JourneyRouteMapModel.LegPath) -> String {
        let mode: String
        switch leg.mode {
        case .air: mode = "Plausible air travel"
        case .overland: mode = "Overland travel"
        case .unknown: mode = "Unspecified travel"
        }
        let hours = leg.elapsedSeconds / 3600
        return "\(mode) · \(distanceLabel(leg.distanceMeters)) · \(String(format: "%.1f h", hours))"
    }
}
