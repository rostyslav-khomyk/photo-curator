import AppKit
import SwiftUI

@MainActor
final class MomentReviewWindowManager: NSObject, NSWindowDelegate {
    static let shared = MomentReviewWindowManager()

    private var openWindows: [String: NSWindow] = [:]
    private var closeCallbacks: [String: () -> Void] = [:]

    override private init() {
        super.init()
    }

    func open(moment: PhotoMoment, decisions: MomentReviewDecisions, curator: CuratorController? = nil, onClose: (() -> Void)? = nil) {
        if let existing = openWindows[moment.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let defaultWidth: CGFloat = 940
        let defaultHeight: CGFloat = 700

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: defaultWidth, height: defaultHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.center()
        window.minSize = NSSize(width: 680, height: 500)
        window.title = "Review: \(MomentPresentation.title(moment, custom: decisions.titles[moment.id]))"
        window.isReleasedWhenClosed = false
        window.level = .floating // Always on top by default for auxiliary reviews
        window.delegate = self

        if let onClose {
            closeCallbacks[moment.id] = onClose
        }

        let reviewView = MomentReviewView(
            moment: moment,
            decisions: decisions,
            curator: curator,
            advancedTools: false,
            window: window,
            onClose: { [weak window] in
                window?.close()
            }
        )

        window.contentView = NSHostingView(rootView: reviewView)
        openWindows[moment.id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        for (id, openWin) in openWindows where openWin === window {
            openWindows.removeValue(forKey: id)
            let callback = closeCallbacks.removeValue(forKey: id)
            callback?()
            NotificationCenter.default.post(name: Notification.Name("PhotoRelayGroupReviewChanged"), object: nil)
            break
        }
    }
}
