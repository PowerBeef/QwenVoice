import XCTest

enum UITestLaunchPolicy {
    case sharedPerClass
    case freshPerTest
}

enum UITestScreen: String {
    case customVoice
    case voiceCloning
    case history
    case voices
    case models
    case preferences

    var rootIdentifier: String {
        "screen_\(rawValue)"
    }

    var sidebarIdentifier: String {
        "sidebar_\(rawValue)"
    }
}

final class QwenVoiceUITestSession {
    static let shared = QwenVoiceUITestSession()

    private var sharedApp: XCUIApplication?

    private init() { }

    func launchSharedApp(initialScreen: UITestScreen?, debugCapture: Bool) -> XCUIApplication {
        if let sharedApp, sharedApp.state != .notRunning {
            sharedApp.activate()
            return sharedApp
        }

        let app = makeApplication(initialScreen: initialScreen, debugCapture: debugCapture)
        app.launch()
        sharedApp = app
        return app
    }

    func sharedApplication(initialScreen: UITestScreen?, debugCapture: Bool) -> XCUIApplication {
        launchSharedApp(initialScreen: initialScreen, debugCapture: debugCapture)
    }

    func launchFreshApp(initialScreen: UITestScreen?, debugCapture: Bool) -> XCUIApplication {
        let app = makeApplication(initialScreen: initialScreen, debugCapture: debugCapture)
        app.launch()
        return app
    }

    func terminateSharedApp() {
        guard let sharedApp else { return }
        if sharedApp.state != .notRunning {
            sharedApp.terminate()
        }
        self.sharedApp = nil
    }

    private func makeApplication(initialScreen: UITestScreen?, debugCapture: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        var launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--uitest",
            "--uitest-disable-animations",
            "--uitest-fast-idle",
        ]
        if let initialScreen {
            launchArguments.append("--uitest-screen=\(initialScreen.rawValue)")
        }
        if debugCapture {
            launchArguments.append("--uitest-debug-capture")
        }
        app.launchArguments = launchArguments
        app.launchEnvironment["QWENVOICE_UI_TEST"] = "1"
        return app
    }
}

/// Base class for all QwenVoice UI tests.
/// Uses a shared app session per class by default to reduce launch overhead.
class QwenVoiceUITestBase: XCTestCase {
    private(set) var app: XCUIApplication!

    class var launchPolicy: UITestLaunchPolicy { .sharedPerClass }
    class var initialScreen: UITestScreen? { nil }

    private var debugCaptureEnabled: Bool {
        let flag = ProcessInfo.processInfo.environment["QWENVOICE_DEBUG_ON_FAIL"] ?? ""
        return flag == "1" || flag == "true"
    }

    override class func setUp() {
        super.setUp()
        if launchPolicy == .sharedPerClass {
            _ = QwenVoiceUITestSession.shared.launchSharedApp(
                initialScreen: initialScreen,
                debugCapture: ProcessInfo.processInfo.environment["QWENVOICE_DEBUG_ON_FAIL"] == "1"
                    || ProcessInfo.processInfo.environment["QWENVOICE_DEBUG_ON_FAIL"] == "true"
            )
        }
    }

    override class func tearDown() {
        if launchPolicy == .sharedPerClass {
            QwenVoiceUITestSession.shared.terminateSharedApp()
        }
        super.tearDown()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false

        switch type(of: self).launchPolicy {
        case .sharedPerClass:
            app = QwenVoiceUITestSession.shared.sharedApplication(
                initialScreen: type(of: self).initialScreen,
                debugCapture: debugCaptureEnabled
            )
        case .freshPerTest:
            app = QwenVoiceUITestSession.shared.launchFreshApp(
                initialScreen: type(of: self).initialScreen,
                debugCapture: debugCaptureEnabled
            )
        }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "App window should appear")

        dismissTransientUI()

        if let initialScreen = type(of: self).initialScreen {
            resetToScreen(initialScreen)
        }
    }

    override func tearDownWithError() throws {
        attachFailureArtifactsIfNeeded()

        if type(of: self).launchPolicy == .freshPerTest {
            app.terminate()
        }

        app = nil
    }

    // MARK: - Navigation Helpers

    func launchSharedApp(initialScreen: UITestScreen? = nil) {
        app = QwenVoiceUITestSession.shared.launchSharedApp(
            initialScreen: initialScreen,
            debugCapture: debugCaptureEnabled
        )
    }

    func waitForScreen(_ screen: UITestScreen, timeout: TimeInterval = 5) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: screen.rootIdentifier).firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Screen root '\(screen.rootIdentifier)' should exist within \(timeout)s"
        )
        return element
    }

    func ensureOnScreen(_ screen: UITestScreen, timeout: TimeInterval = 5) {
        let existing = app.descendants(matching: .any).matching(identifier: screen.rootIdentifier).firstMatch
        if existing.exists {
            return
        }

        let sidebarItem = app.descendants(matching: .any).matching(identifier: screen.sidebarIdentifier).firstMatch
        XCTAssertTrue(
            sidebarItem.waitForExistence(timeout: 10),
            "Sidebar item '\(screen.sidebarIdentifier)' should exist"
        )
        sidebarItem.click()
        _ = waitForScreen(screen, timeout: timeout)
    }

    func resetToScreen(_ screen: UITestScreen, timeout: TimeInterval = 5) {
        let existing = app.descendants(matching: .any).matching(identifier: screen.rootIdentifier).firstMatch
        if existing.exists {
            let fallback: UITestScreen = screen == .customVoice ? .models : .customVoice
            let fallbackItem = app.descendants(matching: .any).matching(identifier: fallback.sidebarIdentifier).firstMatch
            if fallbackItem.waitForExistence(timeout: 5) {
                fallbackItem.click()
                _ = waitForScreen(fallback, timeout: timeout)
            }
        }

        ensureOnScreen(screen, timeout: timeout)
    }

    /// Backward-compatible string navigation helper.
    func navigateToSidebar(_ item: String) {
        guard let screen = UITestScreen(rawValue: item) else {
            XCTFail("Unknown sidebar item '\(item)'")
            return
        }
        ensureOnScreen(screen)
    }

    func navigateToSidebar(_ screen: UITestScreen) {
        ensureOnScreen(screen)
    }

    func waitForBackendStatusElement(timeout: TimeInterval = 5) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: "sidebar_backendStatus").firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Backend status indicator should exist"
        )
        return element
    }

    func waitForElement(
        _ identifier: String,
        type: XCUIElement.ElementType = .any,
        timeout: TimeInterval = 5
    ) -> XCUIElement {
        let element = app.descendants(matching: type).matching(identifier: identifier).firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Element '\(identifier)' should exist within \(timeout)s"
        )
        return element
    }

    func assertElementExists(_ identifier: String, timeout: TimeInterval = 5) {
        _ = waitForElement(identifier, timeout: timeout)
    }

    func dismissTransientUI() {
        let cancelButtons = ["Cancel", "Close", "Done"]
        let alerts = app.alerts

        if alerts.firstMatch.exists {
            for label in cancelButtons {
                let button = alerts.buttons[label]
                if button.exists {
                    button.click()
                    return
                }
            }
        }

        let sheets = app.sheets
        if sheets.firstMatch.exists {
            for label in cancelButtons {
                let button = sheets.buttons[label]
                if button.exists {
                    button.click()
                    return
                }
            }
        }
    }

    // MARK: - Failure Diagnostics

    private func attachFailureArtifactsIfNeeded() {
        guard let run = testRun, run.totalFailureCount > 0 else { return }

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Failure Screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Accessibility Hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
