import AppKit
import Foundation

enum AppStateRestorationPolicy {
    static func allowsStateRestoration() -> Bool {
#if QW_TEST_SUPPORT
        allowsStateRestoration(isUITestLaunch: AppLaunchConfiguration.current.isUITest)
#else
        true
#endif
    }

#if QW_TEST_SUPPORT
    static func allowsStateRestoration(isUITestLaunch: Bool) -> Bool {
        !isUITestLaunch
    }
#endif
}

@MainActor
final class QwenVoiceApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func application(_ app: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        AppStateRestorationPolicy.allowsStateRestoration()
    }

    func application(_ app: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        AppStateRestorationPolicy.allowsStateRestoration()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
#if QW_TEST_SUPPORT
        guard AppLaunchConfiguration.current.isUITest else { return }

        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
#endif
    }
}
