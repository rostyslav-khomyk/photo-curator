import AppKit
import Photos
import SwiftUI

extension Notification.Name {
    static let photoCuratorPhotosAccessChanged = Notification.Name("PhotoCuratorPhotosAccessChanged")
}

/// Read authorization afresh on launch and after returning from System Settings.
struct LibraryAccessBanner: View {
    var accessChanged: () -> Void = {}
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var requesting = false
    @State private var lastAnnouncedAuthorized = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized

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
                                        refreshStatus(announceGrant: true)
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
            refreshStatus(announceGrant: true)
            accessChanged()
        }
        .onAppear {
            refreshStatus(announceGrant: false)
            accessChanged()
        }
        .onReceive(NotificationCenter.default.publisher(for: .photoCuratorPhotosAccessChanged)) { _ in
            // Avoid re-broadcast loops; only refresh local UI and album loading.
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            lastAnnouncedAuthorized = status == .authorized
            accessChanged()
        }
    }

    /// System dialogs can fire didBecomeActive before the authorization callback.
    /// Announce a fresh grant so the curator scheduler and Moments refresh wake.
    private func refreshStatus(announceGrant: Bool) {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let authorized = status == .authorized
        if announceGrant, authorized, !lastAnnouncedAuthorized {
            NotificationCenter.default.post(name: .photoCuratorPhotosAccessChanged, object: nil)
        }
        lastAnnouncedAuthorized = authorized
    }
}
