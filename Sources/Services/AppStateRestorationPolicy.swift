import AppKit
import Foundation

enum AppStateRestorationPolicy {
    static func allowsStateRestoration(isUITestLaunch: Bool) -> Bool {
        !isUITestLaunch
    }
}

@MainActor
final class QwenVoiceApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func application(_ app: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        AppStateRestorationPolicy.allowsStateRestoration(
            isUITestLaunch: AppLaunchConfiguration.current.isUITest
        )
    }

    func application(_ app: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        AppStateRestorationPolicy.allowsStateRestoration(
            isUITestLaunch: AppLaunchConfiguration.current.isUITest
        )
    }
}
