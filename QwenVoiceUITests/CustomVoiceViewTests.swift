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

    func testScreenshotCapture() {
        captureScreenshot(name: "screenshot_customVoice_default")
    }
}
