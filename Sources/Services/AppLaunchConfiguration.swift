import AppKit
import SwiftUI

struct AppLaunchConfiguration {
    /// Live read (2026-07-02): honors a mid-session Reduce Motion toggle immediately.
    /// `accessibilityDisplayShouldReduceMotion` is a cheap workspace property — no
    /// caching needed, and the old launch-only snapshot ignored System Settings
    /// changes until restart.
    var animationsEnabled: Bool {
        overriddenAnimationsEnabled ?? !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private let overriddenAnimationsEnabled: Bool?

    static let current = AppLaunchConfiguration()

    init(animationsEnabled: Bool? = nil) {
        self.overriddenAnimationsEnabled = animationsEnabled
    }

    var shouldOpenSettingsOnLaunch: Bool {
        false
    }

    func animation(_ animation: Animation?) -> Animation? {
        animationsEnabled ? animation : nil
    }

    static func performAnimated<Result>(_ animation: Animation?, _ updates: () -> Result) -> Result {
        withAnimation(current.animation(animation), updates)
    }

    @MainActor static func openSettingsWindowIfNeeded() {
    }
}
