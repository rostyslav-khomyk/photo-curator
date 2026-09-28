@preconcurrency import AppKit
import SwiftUI

/// A local key monitor for the Moments canvas. Controls and text editors retain
/// their normal keyboard handling because unhandled events are returned unchanged.
struct MomentGridKeyHandler: NSViewRepresentable {
    let handle: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(handle: handle) }
    func makeNSView(context: Context) -> NSView {
        let view = WindowTrackingView(frame: .zero)
        view.windowChanged = { [weak coordinator = context.coordinator] number in
            coordinator?.windowNumber = number
        }
        context.coordinator.install(for: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.handle = handle }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }

    final class Coordinator {
        var handle: (NSEvent) -> Bool
        var windowNumber: Int?
        private var monitor: Any?
        init(handle: @escaping (NSEvent) -> Bool) { self.handle = handle }
        @MainActor func install(for view: NSView) {
            windowNumber = view.window?.windowNumber
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.windowNumber == self.windowNumber else { return event }
                return self.handle(event) ? nil : event
            }
        }
        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { remove() }
    }

    final class WindowTrackingView: NSView {
        var windowChanged: ((Int?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowChanged?(window?.windowNumber)
        }
    }
}
