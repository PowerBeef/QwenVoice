import XCTest

final class HistoryViewTests: QwenVoiceUITestBase {
    override var initialScreen: String? { "history" }
    override var uiTestBackendMode: UITestLaunchBackendMode { .stub }

    override func prepareFixtureRoot(_ root: String) {
        mirrorInstalledModels(in: root)
    }

    func testHistoryScreenLoads() {
        waitForScreen("screen_history")
    }

    func testScreenshotCapture() {
        waitForScreen("screen_history")
        captureScreenshot(name: "screenshot_history_empty")
    }
}
