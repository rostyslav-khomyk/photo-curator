import AppKit
import Photos
import SwiftUI

extension Notification.Name {
    static let photoRelayPhotosAccessChanged = Notification.Name("PhotoRelayPhotosAccessChanged")
}

/// Read authorization afresh on launch and after returning from System Settings.
struct LibraryAccessBanner: View {
    var accessChanged: () -> Void = {}
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var requesting = false

    var body: some View {
        Group {
            if status != .authorized {
                HStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Allow access to your full Photos library").font(.headline)
                        Text(status == .restricted
                             ? "Photos access is restricted by this Mac's settings."
                             : "Moments needs all photos to discover your trips. Analysis does not change your Photos library.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if status != .restricted {
                        Button(status == .notDetermined ? "Allow Photos Access" : "Open Photos Privacy Settings") {
                            if status == .notDetermined {
                                requesting = true
                                PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
                                    Task { @MainActor in
                                        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                                        requesting = false
                                        accessChanged()
                                    }
                                }
                            } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                                NSWorkspace.shared.open(url)
                            }
                        }.disabled(requesting)
                    }
                }.padding()
                Divider()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            accessChanged()
        }
        .onAppear { accessChanged() }
        .onReceive(NotificationCenter.default.publisher(for: .photoRelayPhotosAccessChanged)) { _ in
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            accessChanged()
        }
    }
}
