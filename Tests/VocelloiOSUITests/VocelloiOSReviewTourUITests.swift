import XCTest

/// On-device UI REVIEW capture tour — navigates the key screens + a sheet and captures a
/// screenshot of each (`VocelloUITestApp.captureScreenshot` → `UI_TEST_SCREENSHOT_DIR` +
/// the `.xcresult`), for visual review + baseline diffing against
/// `docs/ios-review-baselines/`. Run via `scripts/ios_device.sh review`.
///
/// Burns-in aware: each sheet is opened only long enough to capture, then dismissed
/// (capture-and-dismiss) — the tour never dwells on a static high-contrast screen. The
/// app launches its real in-process engine as usual; the tour simply never triggers a
/// generation, so the Studio composer is captured idle.
///
/// Accessibility: the tour doubles as a reachability pass — every screen/sheet is reached
/// by tapping a real, hittable, identified control (tabs via `rootTab_*`, the sheet via
/// the "Voice: " selector pill, dismissed via the `voicePicker_confirm` header), so a
/// green run implies the interactive surface is navigable with assistive tech. (Dynamic
/// Type at the largest content size is a future addition — it needs app-side plumbing to
/// override `preferredContentSizeCategory` from a UI test.)
final class VocelloiOSReviewTourUITests: XCTestCase {

    override class func setUp() {
        super.setUp()
        VocelloUITestBootstrap.registerObserverIfNeeded()
        VocelloUITestApp.shared.retainIfNeeded()
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        VocelloUITestApp.shared.resetToStudio()
    }

    /// Capture the canonical review screens in one tour. One method on purpose: a single
    /// `-only-testing` run captures every baseline together (one app session, fast, and
    /// minimal OLED dwell). Stable capture names are the baseline keys.
    func testCaptureReviewScreens() {
        // Studio — Custom (default), Design, Clone.
        XCTAssertTrue(waitFor("screen_generateStudio"), "Studio should be the default surface")
        capture("review-studio-custom")

        selectMode("generateSection_design")
        capture("review-studio-design")

        selectMode("generateSection_clone")
        capture("review-studio-clone")

        // Voice picker sheet — open, capture, dismiss immediately (capture-and-dismiss).
        selectMode("generateSection_custom")
        openSheet(viaChipLabelPrefix: "Voice: ")
        capture("review-sheet-voice")
        closeSheet()

        // Tabs (each tap is also an a11y hittability assert).
        tapTab("rootTab_settings", captureNamed: "review-settings")
        tapTab("rootTab_history", captureNamed: "review-history")
        tapTab("rootTab_voices", captureNamed: "review-voices")
        tapTab("rootTab_studio", captureNamed: nil)
    }

    // MARK: - Helpers

    private func tapTab(_ identifier: String, captureNamed name: String?) {
        let tab = element(identifier)
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "tab \(identifier) should exist")
        XCTAssertTrue(tab.isHittable, "tab \(identifier) should be hittable (a11y reachability)")
        tab.tap()
        _ = isSelectedEventually(tab)
        if let name { capture(name) }
    }

    private func openSheet(viaChipLabelPrefix prefix: String) {
        let chip = button(labelPrefix: prefix)
        XCTAssertTrue(chip.waitForExistence(timeout: 30), "selector pill '\(prefix)…' should exist")
        XCTAssertTrue(chip.isHittable, "selector pill '\(prefix)…' should be hittable")
        chip.tap()
        let opened = element("voicePicker_confirm").waitForExistence(timeout: 10)
            || element("languagePicker_confirm").waitForExistence(timeout: 10)
            || element("deliveryPicker_confirm").waitForExistence(timeout: 10)
            || element("voiceBrief_confirm").waitForExistence(timeout: 10)
            || element("bottomSheet_close").waitForExistence(timeout: 10)
        XCTAssertTrue(opened, "the sheet opened from '\(prefix)…' should appear")
    }

    /// Dismiss whatever sheet is open — burn-in rule: never leave a sheet on screen.
    private func closeSheet() {
        for confirm in ["voicePicker_confirm", "languagePicker_confirm", "deliveryPicker_confirm", "voiceBrief_confirm"] {
            let c = element(confirm)
            if c.exists { c.tap(); _ = c.waitForNonExistence(timeout: 5); return }
        }
        let close = element("bottomSheet_close")
        if close.exists { close.tap(); _ = close.waitForNonExistence(timeout: 5) }
    }

    private func selectMode(_ identifier: String) {
        let segment = element(identifier)
        XCTAssertTrue(segment.waitForExistence(timeout: 30), "mode segment \(identifier) should exist")
        segment.tap()
    }

    private func capture(_ name: String) {
        VocelloUITestApp.shared.captureScreenshot(named: name)
    }

    private func element(_ identifier: String) -> XCUIElement {
        VocelloUITestApp.shared.element(identifier)
    }

    private func button(labelPrefix: String) -> XCUIElement {
        VocelloUITestApp.shared.button(labelPrefix: labelPrefix)
    }

    @discardableResult
    private func waitFor(_ identifier: String, timeout: TimeInterval = 30) -> Bool {
        VocelloUITestApp.shared.waitFor(identifier, timeout: timeout)
    }

    private func isSelectedEventually(_ e: XCUIElement, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if e.isSelected { return true }; usleep(200_000) }
        return e.isSelected
    }
}
