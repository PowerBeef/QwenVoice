import XCTest

final class VoicesViewTests: QwenVoiceUITestBase {
    override var initialScreen: String? { "voices" }

    func testVoicesScreenLoads() {
        waitForScreen("screen_voices")
    }

    func testScreenshotCapture() {
        waitForScreen("screen_voices")
        captureScreenshot(name: "screenshot_voices_empty")
    }
}
