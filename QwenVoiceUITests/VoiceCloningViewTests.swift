import XCTest

final class VoiceCloningViewTests: QwenVoiceUITestBase {
    override var initialScreen: String? { "voiceCloning" }

    func testCoreLayoutElements() {
        waitForScreen("screen_voiceCloning")
        assertElementExists("textInput_textEditor")
        assertElementExists("textInput_generateButton")
    }

    func testImportButtonExists() {
        waitForScreen("screen_voiceCloning")
        assertElementExists("voiceCloning_importButton")
    }

    func testScreenshotCapture() {
        waitForScreen("screen_voiceCloning")
        captureScreenshot(name: "screenshot_voiceCloning_default")
    }
}
