import XCTest

final class VoiceDesignViewTests: QwenVoiceUITestBase {
    override var initialScreen: String? { "voiceDesign" }

    func testCoreLayoutElements() {
        waitForScreen("screen_voiceDesign")
        assertElementExists("textInput_textEditor")
        assertElementExists("textInput_generateButton")
    }

    func testScreenshotCapture() {
        waitForScreen("screen_voiceDesign")
        captureScreenshot(name: "screenshot_voiceDesign_default")
    }
}
