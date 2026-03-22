import XCTest

final class ModelsViewTests: QwenVoiceUITestBase {
    override var initialScreen: String? { "models" }

    func testModelsScreenLoads() {
        waitForScreen("screen_models")
    }

    func testScreenshotCapture() {
        waitForScreen("screen_models")
        captureScreenshot(name: "screenshot_models_default")
    }
}
