import XCTest

/// Thin UI-flow smoke for the Vocello iPhone app — the durable replacement (paired
/// with `scripts/ios_device.sh`) for the deprecated screen-mirror UI-driving method.
///
/// Intentionally shallow: it does NOT generate audio (that's the headless
/// `IOSAutorunHarness` / `vocello bench` path). It asserts the app launches and the
/// 4-tab information architecture + Studio composer/mode-control are reachable, keyed
/// off the stable `accessibilityIdentifier`s (kept through refactors per CLAUDE.md).
///
/// Run on a simulator (fast, no signing) or the device:
///   xcodebuild test -scheme VocelloiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
///   xcodebuild test -scheme VocelloiOS -destination 'id=<device-udid>'
final class VocelloiOSSmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        dismissOnboardingIfPresent()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    /// Launches and confirms the Studio tab + its Custom/Design/Clone mode control are present.
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
        }
    }

    // MARK: - Helpers

    /// Resolve an element by accessibility identifier across any element type
    /// (SwiftUI surfaces vary the underlying XCUIElementType).
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
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

    @discardableResult
    private func waitFor(_ identifier: String, timeout: TimeInterval = 15) -> Bool {
        element(identifier).waitForExistence(timeout: timeout)
    }

    /// First-run onboarding (3 pages) sits in front of the tabs on a fresh install — which
    /// happens on every `xcodebuild test` reinstall, and can render a beat after launch.
    /// Poll for either the main UI or onboarding rather than a one-shot wait; Skip completes
    /// the whole flow, the CTA advances/completes as a fallback.
    private func dismissOnboardingIfPresent() {
        let studio = element("rootTab_studio")
        let skip = element("onboarding_skip")
        let cta = element("onboarding_cta")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if studio.exists { return }
            if skip.exists {
                skip.tap()
                _ = studio.waitForExistence(timeout: 6)
                return
            }
            if cta.exists { cta.tap() }
            usleep(300_000)
        }
    }
}
