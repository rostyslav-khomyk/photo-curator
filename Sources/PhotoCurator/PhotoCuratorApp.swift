import AppKit
import ObjectiveC
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The dashboard bridge controls Dock presence; do not override it at launch.
    }

}

@main
struct PhotoCuratorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: PhotoCuratorViewModel
    @StateObject private var curator: CuratorController

    init() {
        PhotosInternalsProbe.runCommandLineIfRequested()
        PhotoCuratorStorageMigration.run()
        CuratorLaunchPerformance.shared.start()
        let bootstrapError: String?
        do {
            _ = try CuratorResetBootstrap.finishLocalResetIfNeeded()
            bootstrapError = nil
        } catch {
            bootstrapError = "Photo Curator could not finish its reset safely: \(error.localizedDescription)"
        }
        let model = PhotoCuratorViewModel()
        let curator = CuratorController(model: model)
        if let bootstrapError { curator.errorMessage = bootstrapError }
        _model = StateObject(wrappedValue: model)
        _curator = StateObject(wrappedValue: curator)
    }

    var body: some Scene {
        Window("Photo Curator", id: "dashboard") {
            WindowSizedFrame {
                DashboardView(model: model, curator: curator)
            }
            .frame(minWidth: 820, minHeight: 580)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DashboardActivationBridge())
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 960, height: 660)

        Settings { CuratorSettingsView(curator: curator, model: model) }

        MenuBarExtra {
            MenuContent(model: model, curator: curator)
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
    @ObservedObject var model: PhotoCuratorViewModel
    @ObservedObject var curator: CuratorController

    var body: some View {
        Text(model.activity)
        Text(curator.activity)
        Toggle("Curate While Idle", isOn: Binding(get: { curator.enabled }, set: { curator.setEnabled($0) }))
        if let progress = model.transferProgress, progress.isTransferring, model.isWorking {
            Text(progress.transferSummary)
            Text("\(progress.completed ?? 0) of \(progress.total ?? 0) items ready")
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
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Photo Curator", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
        Divider()
        Button("Quit Photo Curator") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// One rectangle for the dashboard: the window area below the title bar and
/// toolbar. Apply it only to the SwiftUI hosting view. Split and scroll views
/// then clamp to their parent — never to this rect again, or the top is clipped
/// under the chrome / the UI is centered with empty margins.
private enum WindowChrome {
    static func fillRect(in content: NSView) -> NSRect {
        guard let window = content.window else { return content.bounds }
        let layout = content.convert(window.contentLayoutRect, from: nil)
        guard !layout.isNull, layout.width > 2, layout.height > 2 else { return content.bounds }
        let fill = layout.intersection(content.bounds)
        guard !fill.isNull, fill.width > 2, fill.height > 2 else { return content.bounds }
        return fill
    }
}

/// Keep the dashboard inside the window. SwiftUI otherwise sizes the host to the
/// Moments grid's ideal height and centers it, so the sidebar and grid hang above
/// the window and their scroll views think the content already fits.
struct WindowContentInsetRepair: NSViewRepresentable {
    func makeNSView(context: Context) -> RepairView { RepairView() }
    func updateNSView(_ nsView: RepairView, context: Context) { nsView.repair() }

    final class RepairView: NSView {
        private var correcting = false

        /// A full-size background view must not take clicks or scroll.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isOpaque: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowResized),
                    name: NSWindow.didResizeNotification, object: window)
            }
            repair()
        }

        override func layout() {
            super.layout()
            repair()
        }

        /// SwiftUI assigns the split's frame during the resize pass; fit it after that pass.
        @objc private func windowResized() {
            repair()
            DispatchQueue.main.async { [weak self] in self?.repair() }
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        func repair() {
            guard !correcting, let window, let content = window.contentView else { return }
            correcting = true
            defer { correcting = false }
            var ancestor: NSView? = self
            while let current = ancestor {
                disableIntrinsicSizing(current)
                ancestor = current.superview
            }
            let fill = WindowChrome.fillRect(in: content)
            for subview in content.subviews {
                disableIntrinsicSizing(subview)
                clampNegativeInsets(subview)
                guard isSwiftUIHost(subview) else {
                    // The NavigationSplitView wrapper adopts the list/grid ideal height and is
                    // centered, hanging above the window. It already honors the safe area inside,
                    // so it fills the content view rather than the chrome-free rect.
                    if containsSplitView(subview), subview.frame != content.bounds {
                        subview.frame = content.bounds
                    }
                    continue
                }
                // Only shrink a host that grew past the chrome-free rect.
                // Do not stretch it into the toolbar, and do not move a correctly
                // inset host (that is the empty-margin bug).
                if overflows(subview.frame, fill: fill), subview.frame != fill {
                    subview.frame = fill
                    if #available(macOS 14, *) {
                        subview.clipsToBounds = true
                    }
                }
            }
            clampSplitViews(in: content)
        }

        private func isSwiftUIHost(_ view: NSView) -> Bool {
            NSStringFromClass(type(of: view)).contains("HostingView")
        }

        private func overflows(_ frame: NSRect, fill: NSRect) -> Bool {
            frame.origin.x < fill.minX - 1 || frame.origin.y < fill.minY - 1
                || frame.maxX > fill.maxX + 1 || frame.maxY > fill.maxY + 1
        }

        /// NavigationSplitView's NSSplitView can keep the list's ideal height, which is taller
        /// than the window, so neither column scrolls. Fit it to its parent's current bounds on
        /// every pass; never cache a frame (a cached clamp froze the split at a stale height).
        private func clampSplitViews(in view: NSView) {
            if let split = view as? NSSplitView {
                disableIntrinsicSizing(inColumnsOf: split)
                var chain: [NSView] = []
                var current: NSView = split
                while let parent = current.superview, current !== view.window?.contentView {
                    chain.append(current)
                    current = parent
                }
                // Outermost wrapper first, so each view fits an already-fitted parent.
                var changed = false
                for fitted in chain.reversed() {
                    guard let parent = fitted.superview, parent !== view.window?.contentView,
                          fitted.frame != parent.bounds else { continue }
                    fitted.frame = parent.bounds
                    changed = true
                }
                if changed { split.adjustSubviews() }
                return
            }
            for subview in view.subviews {
                clampSplitViews(in: subview)
            }
        }

        private func containsSplitView(_ view: NSView, depth: Int = 0) -> Bool {
            if view is NSSplitView { return true }
            guard depth < 4 else { return false }
            return view.subviews.contains { containsSplitView($0, depth: depth + 1) }
        }

        /// Column hosting views publish the full List/grid height as intrinsic size, which
        /// becomes the split's fitting size. Stop below nested splits; they get their own pass.
        private func disableIntrinsicSizing(inColumnsOf split: NSSplitView) {
            var pending = split.subviews
            var visited = 0
            while let view = pending.popLast(), visited < 400 {
                visited += 1
                disableIntrinsicSizing(view)
                if !(view is NSSplitView), !(view is NSScrollView) {
                    pending.append(contentsOf: view.subviews)
                }
            }
        }

        /// NSHostingView.sizingOptions is not visible across the generic type.
        /// Zero means the host tracks the window instead of the grid's ideal size.
        private func disableIntrinsicSizing(_ view: NSView) {
            let selector = NSSelectorFromString("setSizingOptions:")
            guard view.responds(to: selector), let imp = view.method(for: selector) else { return }
            typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
            unsafeBitCast(imp, to: Setter.self)(view, selector, 0)
        }

        private func clampNegativeInsets(_ view: NSView) {
            let insets = view.additionalSafeAreaInsets
            if insets.top < 0 || insets.left < 0 || insets.bottom < 0 || insets.right < 0 {
                view.additionalSafeAreaInsets = NSEdgeInsets(
                    top: max(0, insets.top),
                    left: max(0, insets.left),
                    bottom: max(0, insets.bottom),
                    right: max(0, insets.right))
            }
        }
    }
}

/// Fill the hosting view. The window toolbar lives in the title bar, not over the split.
private struct WindowSizedFrame<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct DashboardActivationBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> DashboardActivationView { DashboardActivationView() }
    func updateNSView(_ nsView: DashboardActivationView, context: Context) {}
}

private final class DashboardActivationView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        NotificationCenter.default.addObserver(self, selector: #selector(dashboardBecameKey),
                                               name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(dashboardWillClose),
                                               name: NSWindow.willCloseNotification, object: window)
    }

    @objc private func dashboardBecameKey() { NSApp.setActivationPolicy(.regular) }
    @objc private func dashboardWillClose() { NSApp.setActivationPolicy(.accessory) }

    deinit { NotificationCenter.default.removeObserver(self) }
}
