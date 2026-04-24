#if QW_TEST_SUPPORT
import AppKit
import SwiftUI

@MainActor
final class UITestWindowCoordinator {
    static let mainContentWindowIdentifier = NSUserInterfaceItemIdentifier("QwenVoiceMainContentWindow")

    static func trackedMainWindows(in windows: [NSWindow]) -> [NSWindow] {
        windows.filter { window in
            window.identifier == mainContentWindowIdentifier
                && window.canBecomeMain
                && !window.isExcludedFromWindowsMenu
        }
    }
}

@MainActor private enum UITestWindowSizingState {
    static var configuredWindows: Set<ObjectIdentifier> = []
}

struct UITestWindowSizeConfigurator: NSViewRepresentable {
    let contentSize: CGSize?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            applyWindowConfigurationIfNeeded(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            applyWindowConfigurationIfNeeded(for: nsView)
        }
    }

    private func applyWindowConfigurationIfNeeded(for view: NSView) {
        guard let window = view.window else {
            return
        }

        if let forcedAppearance = UITestAutomationSupport.forcedNSAppearance {
            window.appearance = forcedAppearance
        }

        if UITestAutomationSupport.isEnabled {
            window.identifier = UITestWindowCoordinator.mainContentWindowIdentifier
        }

        guard let contentSize else {
            return
        }

        let key = ObjectIdentifier(window)
        guard !UITestWindowSizingState.configuredWindows.contains(key) else { return }

        window.setContentSize(contentSize)
        UITestWindowSizingState.configuredWindows.insert(key)
    }
}
#endif
