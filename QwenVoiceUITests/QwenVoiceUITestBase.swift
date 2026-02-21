import XCTest

/// Base class for all QwenVoice UI tests.
/// Provides app launch/teardown and common navigation helpers.
class QwenVoiceUITestBase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Disable state restoration to ensure a fresh window opens
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        // Wait for the main window to appear
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "App window should appear")
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - Navigation Helpers

    /// Click a sidebar item by its accessibility identifier.
    func navigateToSidebar(_ item: String) {
        let id = "sidebar_\(item)"
        let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: 10),
            "Sidebar item '\(id)' should exist"
        )
        element.click()
        // Give the view a moment to load
        usleep(500_000) // 0.5s
    }

    /// Assert a static text element exists within a timeout.
    func assertElementExists(_ id: String, timeout: TimeInterval = 5) {
        let element = app.staticTexts[id]
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Element '\(id)' should exist"
        )
    }

    /// Wait for any element to exist by identifier.
    func waitForElement(_ id: String, type: XCUIElement.ElementType = .any, timeout: TimeInterval = 5) -> XCUIElement {
        let element = app.descendants(matching: type).matching(identifier: id).firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Element '\(id)' should exist within \(timeout)s"
        )
        return element
    }
}
