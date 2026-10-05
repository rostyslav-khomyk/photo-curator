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
            repair()
        }

        override func layout() {
            super.layout()
            repair()
        }

        func repair() {
            guard !correcting, let window, let content = window.contentView else { return }
            correcting = true
            defer { correcting = false }
            SplitViewFrameClamp.install()
            var ancestor: NSView? = self
            while let current = ancestor {
                disableIntrinsicSizing(current)
                ancestor = current.superview
            }
            let fill = WindowChrome.fillRect(in: content)
            for subview in content.subviews {
                disableIntrinsicSizing(subview)
                clampNegativeInsets(subview)
                guard isSwiftUIHost(subview) else { continue }
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

        /// NavigationSplitView's NSSplitView adopts the list's ideal height, which is
        /// taller than the window, so neither column scrolls. Keep every split inside
        /// its parent and let it resize its columns to that height.
        private func clampSplitViews(in view: NSView) {
            if let split = view as? NSSplitView {
                SplitViewFrameClamp.install(on: split)
                let fitted = SplitViewFrameClamp.visibleFrame(for: split, requested: split.frame)
                if fitted != split.frame {
                    split.frame = fitted
                    split.adjustSubviews()
                }
                SplitViewFrameClamp.fitColumns(split)
            }
            for subview in view.subviews {
                clampSplitViews(in: subview)
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

/// SwiftUI sizes the Moments split view to the list's ideal height, which is
/// taller than the window, so the columns never scroll. `NSSplitView` may not
/// implement `setFrame:` itself, and Key-Value Observing can sit in front of it.
/// Clamp every class in that chain.
private enum SplitViewFrameClamp {
    private typealias SetFrame = @convention(c) (AnyObject, Selector, NSRect) -> Void
    private static var installed: Set<ObjectIdentifier> = []
    private static let selector = #selector(setter: NSView.frame)
    private static let encoding = "v@:{CGRect={CGPoint=dd}{CGSize=dd}}"
    private static var depth = 0
    /// Re-entrant `setFrame:` calls must hit `NSView`'s implementation. Looking the
    /// method up again returns this hook and overflows the stack.
    private static let viewSetFrame: SetFrame = {
        let method = class_getInstanceMethod(NSView.self, #selector(setter: NSView.frame))
        return unsafeBitCast(method_getImplementation(method!), to: SetFrame.self)
    }()
    private static var computing: Set<ObjectIdentifier> = []
    private static var locks: [ObjectIdentifier: NSRect] = [:]

    static func install() {
        install(on: NSSplitView.self)
    }

    static func install(on view: NSSplitView) {
        var current: AnyClass? = object_getClass(view)
        while let cls = current, cls != NSView.self {
            install(on: cls)
            current = class_getSuperclass(cls)
        }
    }

    /// Keep the split inside its parent. Do not clamp NSScrollView frames —
    /// that clips List/grid content from the top.
    static func visibleFrame(for split: NSSplitView, requested: NSRect) -> NSRect {
        guard let parent = split.superview else { return requested }
        return clampPreservingTop(requested, to: parent.bounds)
    }

    /// Shrink a too-tall frame without moving its top edge. AppKit y=0 is the
    /// bottom; keeping minY clips the title and All Moments under the chrome.
    private static func clampPreservingTop(_ requested: NSRect, to limit: NSRect) -> NSRect {
        guard !limit.isNull, limit.width > 2, limit.height > 2 else { return requested }
        var frame = requested
        if frame.minX < limit.minX { frame.origin.x = limit.minX }
        if frame.width > limit.width { frame.size.width = limit.width }
        if frame.maxX > limit.maxX { frame.origin.x = limit.maxX - frame.width }
        if frame.height > limit.height {
            let top = min(frame.maxY, limit.maxY)
            frame.size.height = limit.height
            frame.origin.y = top - frame.size.height
        }
        if frame.maxY > limit.maxY { frame.origin.y = limit.maxY - frame.height }
        if frame.minY < limit.minY {
            frame.origin.y = limit.minY
            if frame.maxY > limit.maxY { frame.size.height = limit.height }
        }
        return frame
    }

    /// Column wrappers follow the split. Leave NSScrollView frames to SwiftUI.
    static func fitColumns(_ split: NSSplitView) {
        guard depth < 6 else { return }
        depth += 1
        defer { depth -= 1 }
        for subview in split.subviews {
            let fitted = clampPreservingTop(subview.frame, to: split.bounds)
            if fitted != subview.frame { subview.frame = fitted }
        }
    }

    private static func install(on cls: AnyClass) {
        let key = ObjectIdentifier(cls)
        guard installed.insert(key).inserted else { return }
        let block: @convention(block) (NSSplitView, NSRect) -> Void = { split, rect in
            let id = ObjectIdentifier(split)
            if computing.contains(id) {
                viewSetFrame(split, selector, locks[id] ?? rect)
                return
            }
            computing.insert(id)
            defer {
                locks[id] = nil
                computing.remove(id)
            }
            let next = visibleFrame(for: split, requested: rect)
            if next != rect { locks[id] = next }
            viewSetFrame(split, selector, next)
        }
        let imp = imp_implementationWithBlock(block)
        if classImplements(selector, on: cls), let method = class_getInstanceMethod(cls, selector) {
            _ = method_setImplementation(method, imp)
        } else {
            _ = class_addMethod(cls, selector, imp, encoding)
        }
    }

    private static func classImplements(_ selector: Selector, on cls: AnyClass) -> Bool {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return false }
        defer { free(methods) }
        for index in 0..<Int(count) where method_getName(methods[index]) == selector {
            return true
        }
        return false
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
