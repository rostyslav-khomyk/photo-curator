import AppKit
import Foundation

/// Reset leaves local erase/recreate for the next launch (`CuratorResetBootstrap`).
/// The confirmation sheet is modal and blocks `NSApp.terminate` / ⌘Q, so dismiss
/// sheets, schedule a new instance, then quit.
enum PhotoCuratorRelaunch {
    @MainActor
    static func quitAndRelaunch(after delaySeconds: TimeInterval = 0.8) {
        endPresentedSheets()
        scheduleRelaunch(after: delaySeconds)
        // Let SwiftUI tear down the sheet before asking AppKit to terminate.
        DispatchQueue.main.async {
            endPresentedSheets()
            NSApp.terminate(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                endPresentedSheets()
                NSApp.terminate(nil)
                // Last resort if a modal still refuses terminate; relaunch is already scheduled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    exit(EXIT_SUCCESS)
                }
            }
        }
    }

    @MainActor
    private static func endPresentedSheets() {
        for window in NSApp.windows {
            for sheet in window.sheets {
                window.endSheet(sheet)
            }
            if let attached = window.attachedSheet {
                window.endSheet(attached)
            }
        }
    }

    private static func scheduleRelaunch(after delaySeconds: TimeInterval) {
        let path = Bundle.main.bundlePath
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-c",
            "sleep \(String(format: "%.2f", delaySeconds)); /usr/bin/open -n '\(escaped)'"
        ]
        try? process.run()
    }
}
