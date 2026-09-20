import AppKit
import SwiftUI

/// A local key monitor for the Moments canvas. Controls and text editors retain
/// their normal keyboard handling because unhandled events are returned unchanged.
struct MomentGridKeyHandler: NSViewRepresentable {
    let handle: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(handle: handle) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(for: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.handle = handle }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }

    final class Coordinator {
        var handle: (NSEvent) -> Bool
        private var monitor: Any?
        private weak var view: NSView?
        init(handle: @escaping (NSEvent) -> Bool) { self.handle = handle }
        func install(for view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.view?.window else { return event }
                return self.handle(event) ? nil : event
            }
        }
        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { remove() }
    }
}
