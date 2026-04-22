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

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AppLaunchConfiguration.current.isUITest else { return }

        // Force a .regular activation policy and bring the app to the
        // foreground explicitly. Under XCUITest's test-runner activation
        // model on macOS 26, the SwiftUI window otherwise fails to
        // register in the accessibility tree because the app starts in an
        // "inactive" process state and the runner snapshots the tree
        // before any implicit activation happens. `ignoringOtherApps`
        // makes sure we take focus even when the test runner is the
        // current frontmost process.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
