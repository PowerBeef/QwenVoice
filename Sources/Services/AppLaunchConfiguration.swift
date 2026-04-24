import SwiftUI
import AppKit
import CoreGraphics

struct AppLaunchConfiguration {
#if QW_TEST_SUPPORT
    let isUITest: Bool
    let disableAnimations: Bool
    let fastIdle: Bool
    let initialScreenID: String?
    let debugCaptureEnabled: Bool
    let uiTestWindowSize: CGSize?

    static let current = AppLaunchConfiguration(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment
    )
    @MainActor private static var openedInitialSettingsWindow = false

    init(arguments: [String], environment: [String: String]) {
        let inferredUITest = arguments.contains("--uitest")
            || arguments.contains("--uitest-disable-animations")
            || arguments.contains("--uitest-fast-idle")
            || arguments.contains("--uitest-debug-capture")
            || arguments.contains(where: { $0.hasPrefix("--uitest-screen=") })

        isUITest = inferredUITest
        disableAnimations = inferredUITest && (
            arguments.contains("--uitest") || arguments.contains("--uitest-disable-animations")
        )
        fastIdle = inferredUITest && (
            arguments.contains("--uitest") || arguments.contains("--uitest-fast-idle")
        )
        debugCaptureEnabled = inferredUITest && arguments.contains("--uitest-debug-capture")
        initialScreenID = arguments.first(where: { $0.hasPrefix("--uitest-screen=") })?
            .replacingOccurrences(of: "--uitest-screen=", with: "")
        uiTestWindowSize = Self.parseWindowSize(environment["QWENVOICE_UI_TEST_WINDOW_SIZE"])
    }

    var initialSidebarItem: SidebarItem? {
        guard let initialScreenID else { return nil }
        return SidebarItem(testScreenID: initialScreenID)
    }

    var shouldOpenSettingsOnLaunch: Bool {
        initialScreenID == "preferences"
    }

    var animationsEnabled: Bool {
        !disableAnimations
    }
#else
    let animationsEnabled: Bool

    static let current = AppLaunchConfiguration()

    init(animationsEnabled: Bool = true) {
        self.animationsEnabled = animationsEnabled
    }

    var initialSidebarItem: SidebarItem? {
        nil
    }

    var shouldOpenSettingsOnLaunch: Bool {
        false
    }
#endif

    func animation(_ animation: Animation?) -> Animation? {
        animationsEnabled ? animation : nil
    }

    static func performAnimated<Result>(_ animation: Animation?, _ updates: () -> Result) -> Result {
        withAnimation(current.animation(animation), updates)
    }

    @MainActor static func openSettingsWindowIfNeeded() {
#if QW_TEST_SUPPORT
        guard current.shouldOpenSettingsOnLaunch, !openedInitialSettingsWindow else { return }
        openedInitialSettingsWindow = true
        DispatchQueue.main.async {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
#endif
    }

#if QW_TEST_SUPPORT
    private static func parseWindowSize(_ rawValue: String?) -> CGSize? {
        guard let rawValue else { return nil }

        let parts = rawValue
            .lowercased()
            .split(separator: "x", maxSplits: 1)
            .map(String.init)
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width > 0,
              height > 0 else {
            return nil
        }

        return CGSize(width: width, height: height)
    }
#endif
}
