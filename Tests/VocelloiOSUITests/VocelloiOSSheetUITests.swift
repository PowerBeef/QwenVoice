import XCTest

/// Regression UI tests for the Studio bottom-sheet pickers — the durable, autonomous
/// counterpart to live on-device review. Runs on the device (`scripts/ios_device.sh ui-test`)
/// or a simulator.
///
/// Reaching the sheets: the Studio **selector pills** are tapped by their stable label
/// prefix ("Voice: ", "Language:", "Voice brief:") — their own `studioChip_*` identifiers are
/// shadowed by the screen-level `screen_generateStudio` identifier that SwiftUI propagates
/// onto descendants (same reason `textInput_*` are shadowed). Inside the sheets the elements
/// keep their own identifiers (`voicePickerRow_*`, `voicePickerPreview_*`, `voicePicker_confirm`,
/// `languagePicker_*`, `voiceBrief_editor`, `voiceBrief_confirm`) because the bottom panel is a
/// separate overlay, so those are driven by identifier.
///
/// These assert *behaviour* (select-and-confirm, preview-doesn't-close, confirm gating),
/// not pixels — the no-rubber-band scroll feel + thumb fade are verified by visual review.
final class VocelloiOSSheetUITests: XCTestCase {

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

    /// Selecting a voice row updates the provisional selection but does NOT close the picker.
    /// Tapping the Confirm header button commits the selection and dismisses the sheet.
    func testVoicePickerSelectAndConfirm() {
        selectMode("generateSection_custom")
        openSheet(viaChipLabelPrefix: "Voice: ")

        let confirm = element("voicePicker_confirm")
        let chipBefore = button(labelPrefix: "Voice: ").label

        // The shared app session means the current voice may already be the first row.
        // Derive the current row identifier from the chip label and pick a different one.
        let currentVoiceName = chipBefore
            .replacingOccurrences(of: "Voice: ", with: "")
            .trimmingCharacters(in: .whitespaces)
        let currentRowID = "voicePickerRow_\(currentVoiceName.lowercased())"

        let newRow = firstElement(prefix: "voicePickerRow_", excludingIdentifier: currentRowID)
        XCTAssertTrue(newRow.waitForExistence(timeout: 10), "a different voice row should exist")
        newRow.tap()

        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "confirm button should remain visible after selecting a row")
        confirm.tap()
        XCTAssertTrue(
            confirm.waitForNonExistence(timeout: 10),
            "tapping Confirm should dismiss the voice picker"
        )

        let chipAfter = button(labelPrefix: "Voice: ").label
        XCTAssertTrue(chipAfter.hasPrefix("Voice: "), "voice chip should show a selected voice")
        XCTAssertNotEqual(chipAfter, chipBefore, "voice chip should reflect the newly selected voice")
        VocelloUITestApp.shared.captureScreenshot(named: "sheet-voice-confirmed")
    }

    /// The per-row preview button is a sibling Button (not nested) — tapping it must preview
    /// WITHOUT selecting or closing the sheet. The sheet is then closed with the Confirm header.
    func testVoicePreviewKeepsPickerOpen() {
        selectMode("generateSection_custom")
        openSheet(viaChipLabelPrefix: "Voice: ")

        let confirm = element("voicePicker_confirm")
        let preview = firstElement(prefix: "voicePickerPreview_")
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "a preview button should exist")
        preview.tap()

        XCTAssertTrue(confirm.exists, "previewing a voice should not close the picker")
        confirm.tap()
        XCTAssertTrue(
            confirm.waitForNonExistence(timeout: 10),
            "tapping Confirm should dismiss the picker after preview"
        )
        VocelloUITestApp.shared.captureScreenshot(named: "sheet-preview-closed")
    }

    /// Selecting a language row updates the selection but does NOT close the picker.
    /// Tapping the Confirm header button commits the selection and dismisses the sheet.
    func testLanguagePickerSelectAndClose() {
        selectMode("generateSection_custom")
        openSheet(viaChipLabelPrefix: "Language:")

        let confirm = element("languagePicker_confirm")
        let firstRow = firstElement(prefix: "languagePicker_", excludingIdentifier: "languagePicker_confirm")
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "language rows should exist")
        firstRow.tap()

        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "confirm button should remain visible after selecting a row")
        confirm.tap()
        XCTAssertTrue(
            confirm.waitForNonExistence(timeout: 10),
            "tapping Confirm should dismiss the language picker"
        )
        VocelloUITestApp.shared.captureScreenshot(named: "sheet-language-closed")
    }

    /// With a non-empty brief, the header Confirm button applies it and closes the sheet.
    func testVoiceBriefConfirmCloses() {
        selectMode("generateSection_design")
        openSheet(viaChipLabelPrefix: "Voice brief:")

        let confirm = element("voiceBrief_confirm")
        let editor = element("voiceBrief_editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "the brief editor should exist")
        editor.tap()
        editor.typeText("A calm test narrator")   // ensure a non-empty brief deterministically

        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the Confirm CTA should exist")
        confirm.tap()
        XCTAssertTrue(
            confirm.waitForNonExistence(timeout: 10),
            "Confirm with a non-empty brief should apply + close the sheet"
        )
        VocelloUITestApp.shared.captureScreenshot(named: "sheet-brief-closed")
    }

    /// A long custom tone is accepted up to the 500-char cap and is truncated in the Studio chip.
    func testCustomToneLongInstructionAndChipTruncation() {
        selectMode("generateSection_custom")
        openSheet(viaChipLabelPrefix: "Delivery: ")

        let customToneButton = element("deliveryPickerSheet_customTone")
        XCTAssertTrue(customToneButton.waitForExistence(timeout: 10), "custom tone button should exist")
        customToneButton.tap()

        let editor = element("deliveryPickerSheet_customTone_editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "custom tone editor should exist")

        let longInstruction = String(
            repeating: "A calm, deep narrator with a slow pace and warm timbre. ",
            count: 6
        )
        editor.tap()
        editor.typeText(longInstruction)

        let counter = element("deliveryPickerSheet_customTone_charCount")
        XCTAssertTrue(counter.waitForExistence(timeout: 5), "character counter should exist")
        XCTAssertTrue(counter.label.contains("/500"), "counter should show the 500-character cap")

        let confirm = element("deliveryPicker_confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Confirm CTA should remain visible")
        confirm.tap()
        XCTAssertTrue(
            confirm.waitForNonExistence(timeout: 10),
            "Confirm should apply the custom tone and close the sheet"
        )

        let chip = button(labelPrefix: "Delivery: ")
        XCTAssertTrue(chip.label.hasPrefix("Delivery: "), "delivery chip should show a custom tone")
        XCTAssertTrue(chip.label.contains("…"), "long custom tone should be truncated in the chip")
        VocelloUITestApp.shared.captureScreenshot(named: "sheet-custom-tone-long")
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        VocelloUITestApp.shared.element(identifier)
    }

    /// First element whose identifier begins with `prefix` (rows carry a per-item suffix).
    private func firstElement(prefix: String) -> XCUIElement {
        VocelloUITestApp.shared.firstElement(prefix: prefix)
    }

    /// First element whose identifier begins with `prefix` but is not `excludingIdentifier`.
    private func firstElement(prefix: String, excludingIdentifier: String) -> XCUIElement {
        VocelloUITestApp.shared.firstElement(prefix: prefix, excludingIdentifier: excludingIdentifier)
    }

    /// A button matched by its label prefix — used for the Studio selector pills, whose own
    /// identifiers are shadowed by the screen-level identifier (see the type doc).
    private func button(labelPrefix: String) -> XCUIElement {
        VocelloUITestApp.shared.button(labelPrefix: labelPrefix)
    }

    @discardableResult
    private func waitFor(_ identifier: String, timeout: TimeInterval = 30) -> Bool {
        VocelloUITestApp.shared.waitFor(identifier, timeout: timeout)
    }

    /// Tap a Studio selector pill (by label) and wait for the bottom sheet to open.
    private func openSheet(viaChipLabelPrefix prefix: String) {
        let chip = button(labelPrefix: prefix)
        XCTAssertTrue(chip.waitForExistence(timeout: 30), "selector pill '\(prefix)…' should exist")
        chip.tap()

        // Voice, language, delivery, and voice-brief pickers surface a Confirm header; other sheets expose the X close button.
        let sheetOpen = element("voicePicker_confirm").waitForExistence(timeout: 10)
            || element("languagePicker_confirm").waitForExistence(timeout: 10)
            || element("deliveryPicker_confirm").waitForExistence(timeout: 10)
            || element("voiceBrief_confirm").waitForExistence(timeout: 10)
            || element("bottomSheet_close").waitForExistence(timeout: 10)
        XCTAssertTrue(sheetOpen, "the sheet opened from '\(prefix)…' should appear")
    }

    /// Tap a mode segment (Custom/Design/Clone). A no-op if already selected; harmless.
    private func selectMode(_ identifier: String) {
        let segment = element(identifier)
        XCTAssertTrue(segment.waitForExistence(timeout: 30), "mode segment \(identifier) should exist")
        segment.tap()
    }
}
