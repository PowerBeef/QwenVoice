import XCTest

final class CustomVoiceViewTests: QwenVoiceUITestBase {
    override var initialScreen: String? { "customVoice" }

    func testCoreLayoutElements() {
        assertElementExists("textInput_textEditor")
        assertElementExists("textInput_generateButton")
        assertElementExists("textInput_charCount")
    }

    func testGenerateButtonDisabledWhenEmpty() {
        let button = app.buttons["textInput_generateButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        XCTAssertFalse(button.isEnabled, "Generate should be disabled with empty text")
    }

    func testSelectionStateSurvivesSidebarRoundTrip() {
        assertElementExists("customVoice_speakerPicker")
        let initialSpeaker = stringValue(for: "customVoice_selectedSpeaker")

        clickElement("sidebar_models")
        assertElementExists("models_title")

        clickElement("sidebar_customVoice")
        assertElementExists("customVoice_speakerPicker")

        XCTAssertEqual(stringValue(for: "customVoice_selectedSpeaker"), initialSpeaker)
    }

    func testScreenshotCapture() {
        captureScreenshot(name: "screenshot_customVoice_default")
    }
}
