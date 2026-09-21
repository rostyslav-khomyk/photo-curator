import Foundation
import os

enum CuratorPerformance {
    private static let signposter = OSSignposter(
        subsystem: "com.photorrelay.app",
        category: "Performance"
    )

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}

@MainActor
final class CuratorLaunchPerformance {
    static let shared = CuratorLaunchPerformance()

    private var interval: OSSignpostIntervalState?

    private init() {}

    func start() {
        guard interval == nil else { return }
        interval = CuratorPerformance.begin("Launch to interactive")
    }

    func finish() {
        guard let interval else { return }
        CuratorPerformance.end("Launch to interactive", interval)
        self.interval = nil
    }
}
