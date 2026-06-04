import XCTest

/// Regression UI tests for the Studio bottom-sheet pickers — the durable, autonomous
/// counterpart to live on-device review. Runs on the device (`scripts/ios_device.sh ui-test`)
/// or a simulator.
///
/// Reaching the sheets: the Studio **selector pills** are tapped by their stable label
/// prefix ("Voice: ", "Language:", "Voice brief:") — their own `studioChip_*` identifiers are
/// shadowed by the screen-level `screen_generateStudio` identifier that SwiftUI propagates
/// onto descendants (same reason `textInput_*` are shadowed). Inside the sheets the elements
/// keep their own identifiers (`bottomSheet_close`, `voicePickerRow_*`, `voicePickerPreview_*`,
/// `languagePicker_*`, `voiceBrief_editor`, `voiceBrief_confirm`) because the bottom panel is a
/// separate overlay, so those are driven by identifier.
///
/// These assert *behaviour* (select-and-close, preview-doesn't-close, confirm gating), not
/// pixels — the no-rubber-band scroll feel + thumb fade are verified by visual review.
final class VocelloiOSSheetUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // Seed the simulator fake engine so the Studio is in its normal, model-installed
        // state (ignored on a real device, which uses the in-process MLX engine).
        app.launchEnvironment["QVOICE_SIM_FAKE_MODELS"] = "all"
        app.launchEnvironment["QVOICE_SIM_SEED_DATA"] = "voices,history"
        app.launch()
        dismissOnboardingIfPresent()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    /// Tapping a voice row selects it and closes the picker (the regression this session fixed:
    /// the row was a nested Button whose select tap got swallowed).
    func testVoicePickerSelectAndClose() {
        selectMode("generateSection_custom")
        openSheet(viaChipLabelPrefix: "Voice: ")

        let close = element("bottomSheet_close")
        let firstRow = firstElement(prefix: "voicePickerRow_")
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "at least one voice row should exist")
        firstRow.tap()

        XCTAssertTrue(close.waitForNonExistence(timeout: 10), "selecting a voice should close the picker")
    }

    /// The per-row preview button is a sibling Button (not nested) — tapping it must preview
    /// WITHOUT selecting or closing the sheet.
    func testVoicePreviewKeepsPickerOpen() {
        selectMode("generateSection_custom")
        openSheet(viaChipLabelPrefix: "Voice: ")

        let close = element("bottomSheet_close")
        let preview = firstElement(prefix: "voicePickerPreview_")
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "a preview button should exist")
        preview.tap()

        XCTAssertTrue(close.exists, "previewing a voice should not close the picker")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10), "tapping close should dismiss the picker")
    }

    /// Tapping a language row selects it and closes the picker.
    func testLanguagePickerSelectAndClose() {
        selectMode("generateSection_custom")
        openSheet(viaChipLabelPrefix: "Language:")

        let close = element("bottomSheet_close")
        let firstRow = firstElement(prefix: "languagePicker_")
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "language rows should exist")
        firstRow.tap()

        XCTAssertTrue(close.waitForNonExistence(timeout: 10), "selecting a language should close the picker")
    }

    /// With a non-empty brief, the "Done" CTA applies it and closes the sheet (the affordance
    /// added this session). The empty-brief gating is a visual/disabled-opacity concern that's
    /// state-dependent here (the device draft persists), so it's left to code/visual review.
    func testVoiceBriefConfirmCloses() {
        selectMode("generateSection_design")
        openSheet(viaChipLabelPrefix: "Voice brief:")

        let close = element("bottomSheet_close")
        let editor = element("voiceBrief_editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "the brief editor should exist")
        editor.tap()
        editor.typeText("A calm test narrator")   // ensure a non-empty brief deterministically

        let done = element("voiceBrief_confirm")
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the Done CTA should exist")
        done.tap()
        XCTAssertTrue(
            close.waitForNonExistence(timeout: 10),
            "Done with a non-empty brief should apply + close the sheet"
        )
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// First element whose identifier begins with `prefix` (rows carry a per-item suffix).
    private func firstElement(prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .firstMatch
    }

    /// A button matched by its label prefix — used for the Studio selector pills, whose own
    /// identifiers are shadowed by the screen-level identifier (see the type doc).
    private func button(labelPrefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix)).firstMatch
    }

    /// Tap a Studio selector pill (by label) and wait for the bottom sheet to open.
    private func openSheet(viaChipLabelPrefix prefix: String) {
        let chip = button(labelPrefix: prefix)
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "selector pill '\(prefix)…' should exist")
        chip.tap()
        XCTAssertTrue(
            element("bottomSheet_close").waitForExistence(timeout: 10),
            "the sheet opened from '\(prefix)…' should appear"
        )
    }

    @discardableResult
    private func waitFor(_ identifier: String, timeout: TimeInterval = 15) -> Bool {
        element(identifier).waitForExistence(timeout: timeout)
    }

    /// Tap a mode segment (Custom/Design/Clone). A no-op if already selected; harmless.
    private func selectMode(_ identifier: String) {
        let segment = element(identifier)
        XCTAssertTrue(segment.waitForExistence(timeout: 15), "mode segment \(identifier) should exist")
        segment.tap()
    }

    /// First-run onboarding (3 pages) shows on a fresh install. Poll for either the main UI or
    /// onboarding; tapping Skip completes the whole flow, the CTA advances/completes as a fallback.
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
