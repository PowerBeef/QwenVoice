import XCTest

/// Thin UI-flow smoke for the Vocello iPhone app — the durable replacement (paired
/// with `scripts/ios_device.sh`) for the deprecated screen-mirror UI-driving method.
///
/// Intentionally shallow: it does NOT generate audio (that's the headless
/// `IOSAutorunHarness` / `vocello bench` path). It asserts the app launches and the
/// 4-tab information architecture + Studio composer/mode-control are reachable, keyed
/// off the stable `accessibilityIdentifier`s (kept through refactors per AGENTS.md).
///
/// The app is launched once for the whole UI-test target by `VocelloUITestApp` and
/// stays alive across test classes; each test only resets surface state.
final class VocelloiOSSmokeUITests: XCTestCase {

    override class func setUp() {
        super.setUp()
        VocelloUITestApp.shared.retain()
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        VocelloUITestApp.shared.resetToStudio()
    }

    override class func tearDown() {
        VocelloUITestApp.shared.release()
        super.tearDown()
    }

    /// Confirms the Studio tab + its Custom/Design/Clone mode control are present.
    /// (Note: the screen-level `screen_generateStudio` identifier propagates onto the composer +
    /// pills, shadowing their own `textInput_*` / `studioChip_*` ids — so this asserts the mode
    /// segments, which keep their identifiers, rather than those shadowed ones.)
    func testStudioLaunchSurface() {
        XCTAssertTrue(waitFor("rootTab_studio"), "Studio tab should exist on launch")
        XCTAssertTrue(waitFor("screen_generateStudio"), "Studio screen should be the default surface")
        XCTAssertTrue(
            element("generateSection_custom").exists
                && element("generateSection_design").exists
                && element("generateSection_clone").exists,
            "all three Custom/Design/Clone mode segments should be present"
        )
        VocelloUITestApp.shared.captureScreenshot(named: "smoke-studio-surface")
    }

    /// Confirms each of the 4 tabs is reachable and becomes selected when tapped. (Uses the tab's
    /// own selected-state rather than an inner screen id, since some inner ids are shadowed by
    /// their screen-level identifier.)
    func testTabNavigation() {
        for tab in ["rootTab_voices", "rootTab_history", "rootTab_settings", "rootTab_studio"] {
            let tabElement = element(tab)
            XCTAssertTrue(tabElement.waitForExistence(timeout: 10), "tab \(tab) should exist")
            tabElement.tap()
            XCTAssertTrue(isSelectedEventually(tabElement), "tapping \(tab) should select it")
            VocelloUITestApp.shared.captureScreenshot(named: "smoke-tab-\(tab)")
        }
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        VocelloUITestApp.shared.element(identifier)
    }

    @discardableResult
    private func waitFor(_ identifier: String, timeout: TimeInterval = 30) -> Bool {
        VocelloUITestApp.shared.waitFor(identifier, timeout: timeout)
    }

    /// Poll an element's `isSelected` (the trait updates a beat after the tap).
    private func isSelectedEventually(_ e: XCUIElement, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if e.isSelected { return true }
            usleep(200_000)
        }
        return e.isSelected
    }
}
