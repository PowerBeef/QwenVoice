import XCTest

final class VoiceCloningGenerationTests: FeatureMatrixUITestBase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture.installModel(mode: "clone")
        fixture.seedVoice()
    }

    func testSavedVoiceGenerationWithTranscript() {
        launchStubApp(initialScreen: .voiceCloning)
        _ = waitForScreen(.voiceCloning, timeout: 15)
        _ = waitForBackendIdle(timeout: 10)

        let savedVoice = openSavedVoicePickerAndSelect("fixture_voice")
        savedVoice.click()
        let editor = waitForElement("textInput_textEditor", timeout: 5)
        revealElementIfNeeded(editor)
        app.activate()
        editor.click()
        editor.typeText("Clone generation from saved voice.")
        let generate = waitForElementToBecomeEnabled("textInput_generateButton", type: .button, timeout: 5)
        generate.click()

        XCTAssertTrue(waitForElement("sidebarPlayer_bar", timeout: 10).exists)
        assertEventMarkerExists("clone-generate-success", timeout: 10)
        let transcriptInput = app.textFields["voiceCloning_transcriptInput"].firstMatch
        let labeledTranscript = app.textFields["Transcript"].firstMatch
        XCTAssertTrue(
            app.staticTexts["fixture_voice.wav"].waitForExistence(timeout: 5)
                || (transcriptInput.exists && transcriptInput.value as? String == "Fixture transcript")
                || (labeledTranscript.exists && labeledTranscript.value as? String == "Fixture transcript")
        )
    }

    func testImportedReferenceGenerationWithoutTranscript() {
        launchStubApp(initialScreen: .voiceCloning)
        _ = waitForScreen(.voiceCloning, timeout: 15)
        _ = waitForBackendIdle(timeout: 10)

        waitForElement("voiceCloning_importButton", timeout: 5).click()
        XCTAssertTrue(
            app.staticTexts["import-reference.wav"].firstMatch.waitForExistence(timeout: 5)
        )

        let editor = waitForElement("textInput_textEditor", timeout: 5)
        revealElementIfNeeded(editor)
        app.activate()
        editor.click()
        editor.typeText("Clone generation from imported voice.")
        let generate = waitForElementToBecomeEnabled("textInput_generateButton", type: .button, timeout: 5)
        generate.click()

        XCTAssertTrue(waitForElement("sidebarPlayer_bar", timeout: 10).exists)
        assertEventMarkerExists("clone-generate-success", timeout: 10)
    }

    private func openSavedVoicePickerAndSelect(_ voiceLabel: String) -> XCUIElement {
        app.activate()
        waitForElement("voiceCloning_savedVoicePicker", timeout: 10).click()
        app.activate()

        let menuItem = app.menuItems[voiceLabel].firstMatch
        if menuItem.waitForExistence(timeout: 2) {
            return menuItem
        }

        let identifiedItem = app.descendants(matching: .any)
            .matching(identifier: "voiceCloning_savedVoice_\(voiceLabel)")
            .firstMatch
        if identifiedItem.waitForExistence(timeout: 2) {
            return identifiedItem
        }

        let button = app.buttons[voiceLabel].firstMatch
        if button.waitForExistence(timeout: 2) {
            return button
        }

        XCTFail("Saved voice menu item '\(voiceLabel)' should exist")
        return menuItem
    }
}
