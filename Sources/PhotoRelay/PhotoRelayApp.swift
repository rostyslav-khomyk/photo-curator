import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The dashboard bridge controls Dock presence; do not override it at launch.
    }

    func applicationWillTerminate(_ notification: Notification) {
        BackendController.shared.stop()
    }
}

@main
struct PhotoRelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var backend = BackendController.shared
    @StateObject private var model: PhotoRelayViewModel
    @StateObject private var curator: CuratorController

    init() {
        let model = PhotoRelayViewModel(backend: BackendController.shared)
        _model = StateObject(wrappedValue: model)
        _curator = StateObject(wrappedValue: CuratorController(model: model))
    }

    var body: some Scene {
        Window("Photo Curator", id: "dashboard") {
            DashboardView(backend: backend, model: model, curator: curator)
                .frame(minWidth: 820, minHeight: 580)
                .background(DashboardActivationBridge())
        }
        .defaultSize(width: 960, height: 660)

        Settings { CuratorSettingsView(curator: curator, model: model) }

        MenuBarExtra {
            MenuContent(backend: backend, model: model, curator: curator)
        } label: {
            Label(
                "Photo Curator",
                systemImage: "photo.stack"
            )
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var backend: BackendController
    @ObservedObject var model: PhotoRelayViewModel
    @ObservedObject var curator: CuratorController

    var body: some View {
        Text(model.activity)
        Text(curator.activity)
        Toggle("Curate While Idle", isOn: Binding(get: { curator.enabled }, set: curator.setEnabled))
        if curator.foregroundActive { Button("Stop Range Scan") { curator.stopForeground() } }
        if let progress = model.transferProgress, progress.isTransferring, model.isWorking {
            Text(progress.transferSummary)
            Text("\(progress.completed ?? 0) of \(progress.total ?? 0) items ready")
        }
        if let error = backend.lastError {
            Text(error).foregroundStyle(.red)
        }
        Divider()
        Button("Open Photo Curator") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }
        if model.canAbortUpload {
            Button(model.isAborting ? "Aborting…" : "Abort Upload") { model.abortUpload() }
                .disabled(model.isAborting)
        }
        Button("Open Logs") {
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Photo Relay", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
        Divider()
        Button("Quit Photo Curator") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Observe only the dashboard, not transient menus, alerts, or OAuth windows.
private struct DashboardActivationBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> DashboardActivationView { DashboardActivationView() }
    func updateNSView(_ nsView: DashboardActivationView, context: Context) {}
}

private final class DashboardActivationView: NSView {
    private var tokens: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        tokens.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
            NSApp.setActivationPolicy(.regular)
        })
        tokens.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            NSApp.setActivationPolicy(.accessory)
        })
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}
