import AppKit
import CoreLocation
import Foundation
import MapKit
import SwiftUI

private let meaningfulPlacesDefaultsKey = "curator.meaningfulPlaces.v1"

struct MeaningfulPlace: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var label: String
    var address: String
    var latitude: Double
    var longitude: Double
    var radius: Double

    init(id: UUID = UUID(), label: String, address: String, latitude: Double, longitude: Double, radius: Double = 200) {
        self.id = id
        self.label = label
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
    }

    func contains(latitude: Double, longitude: Double) -> Bool {
        CLLocation(latitude: self.latitude, longitude: self.longitude)
            .distance(from: CLLocation(latitude: latitude, longitude: longitude)) <= radius
    }
}

@MainActor
final class MeaningfulPlacesStore: ObservableObject {
    static let shared = MeaningfulPlacesStore()
    @Published private(set) var places: [MeaningfulPlace]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        places = Self.read(defaults: defaults)
    }

    func save(_ place: MeaningfulPlace) {
        if let index = places.firstIndex(where: { $0.id == place.id }) {
            places[index] = place
        } else {
            places.append(place)
        }
        persist()
    }

    func remove(at offsets: IndexSet) {
        places.remove(atOffsets: offsets)
        persist()
    }

    func remove(_ place: MeaningfulPlace) {
        places.removeAll { $0.id == place.id }
        persist()
    }

    nonisolated static func snapshot(defaults: UserDefaults = .standard) -> [MeaningfulPlace] {
        read(defaults: defaults)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(places) else { return }
        defaults.set(data, forKey: meaningfulPlacesDefaultsKey)
        NotificationCenter.default.post(name: .meaningfulPlacesChanged, object: nil)
    }

    private nonisolated static func read(defaults: UserDefaults) -> [MeaningfulPlace] {
        guard let data = defaults.data(forKey: meaningfulPlacesDefaultsKey),
              let decoded = try? JSONDecoder().decode([MeaningfulPlace].self, from: data) else { return [] }
        return decoded
    }
}

extension Notification.Name {
    static let meaningfulPlacesChanged = Notification.Name("PhotoCuratorMeaningfulPlacesChanged")
}

@MainActor
final class PlaceSearchModel: NSObject, ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [MKMapItem] = []
    @Published private(set) var searching = false
    @Published var errorMessage: String?
    private var locationManager: CLLocationManager?
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?

    func search() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        searching = true
        errorMessage = nil
        Task {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = value
            request.resultTypes = [.address, .pointOfInterest]
            do {
                results = try await MKLocalSearch(request: request).start().mapItems
                if results.isEmpty { errorMessage = "No matching places found." }
            } catch {
                errorMessage = "Apple Maps could not complete that search."
            }
            searching = false
        }
    }

    func currentLocation() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            locationContinuation = continuation
            let manager = CLLocationManager()
            locationManager = manager
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finishLocation(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorMessage = "Current location is unavailable. You can still search by address."
        finishLocation(nil)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            errorMessage = "Location access is off. You can still search by address."
            finishLocation(nil)
        }
    }

    private func finishLocation(_ location: CLLocation?) {
        locationContinuation?.resume(returning: location)
        locationContinuation = nil
        locationManager = nil
    }
}

extension PlaceSearchModel: @preconcurrency CLLocationManagerDelegate {}

struct MeaningfulPlaceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: MeaningfulPlacesStore
    @StateObject private var search = PlaceSearchModel()
    @State private var labelKind = "Home"
    @State private var customLabel = ""
    @State private var selected: MKMapItem?
    @State private var currentCoordinate: CLLocationCoordinate2D?
    @State private var radius = 200.0
    private let place: MeaningfulPlace?

    init(store: MeaningfulPlacesStore, place: MeaningfulPlace? = nil) {
        self.store = store
        self.place = place
        let knownLabel = place?.label ?? "Home"
        let standardLabel = ["Home", "Work"].contains(knownLabel) ? knownLabel : "Custom"
        _labelKind = State(initialValue: standardLabel)
        _customLabel = State(initialValue: standardLabel == "Custom" ? knownLabel : "")
        _currentCoordinate = State(initialValue: place.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        })
        _radius = State(initialValue: place?.radius ?? 200)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(place == nil ? "Add a Meaningful Place" : "Edit Meaningful Place").font(.title2.bold())
            Text("Give familiar locations a photographer's caption, such as Home, Work, or Studio.")
                .foregroundStyle(.secondary)
            Picker("Label", selection: $labelKind) {
                Text("Home").tag("Home")
                Text("Work").tag("Work")
                Text("Custom").tag("Custom")
            }.pickerStyle(.segmented)
            if labelKind == "Custom" {
                TextField("Place label", text: $customLabel).textFieldStyle(.roundedBorder)
            }
            HStack {
                TextField("Search an address or place", text: $search.query)
                    .textFieldStyle(.roundedBorder).onSubmit { search.search() }
                Button("Search") { search.search() }.disabled(search.query.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Use Current Location") {
                    Task { currentCoordinate = await search.currentLocation()?.coordinate }
                }
            }
            if let place, selected == nil {
                Text("Current address: \(place.address)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if search.searching { ProgressView().controlSize(.small) }
            if let message = search.errorMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            List(search.results, id: \.self, selection: Binding(get: { selected }, set: { selected = $0 })) { item in
                VStack(alignment: .leading) {
                    Text(item.name ?? "Unnamed place")
                    Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary)
                }.tag(item as MKMapItem?)
            }.frame(height: 180)
            if selected == nil, currentCoordinate != nil {
                Label(place == nil ? "Current location selected" : "Saved location retained", systemImage: "location.fill")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Matching radius")
                Slider(value: $radius, in: 50...1000, step: 25)
                Text("\(Int(radius)) m").monospacedDigit().frame(width: 58, alignment: .trailing)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(place == nil ? "Add Place" : "Save Changes") { savePlace() }.buttonStyle(.borderedProminent)
                    .disabled(cleanLabel.isEmpty || (selected == nil && currentCoordinate == nil))
            }
        }.padding(24).frame(width: 620)
            .onAppear {
                if let place, search.query.isEmpty { search.query = place.address }
            }
    }

    private var cleanLabel: String {
        (labelKind == "Custom" ? customLabel : labelKind).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func savePlace() {
        let coordinate = selected?.placemark.coordinate ?? currentCoordinate!
        let address = selected?.placemark.title ?? place?.address ?? "Current location"
        store.save(MeaningfulPlace(id: place?.id ?? UUID(), label: cleanLabel, address: address,
                                  latitude: coordinate.latitude, longitude: coordinate.longitude, radius: radius))
        dismiss()
    }
}
