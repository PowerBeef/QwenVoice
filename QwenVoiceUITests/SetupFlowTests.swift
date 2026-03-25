import XCTest

final class SetupFlowTests: QwenVoiceUITestBase {
    override var uiTestBackendMode: UITestLaunchBackendMode { .stub }
    override var uiTestSetupScenario: String { "fail_once" }
    override var uiTestSetupDelayMilliseconds: String { "50" }
    override var shouldWaitForInitialReadiness: Bool { false }
    override var includesFastIdleLaunchArgument: Bool { false }

    func testSetupFailureShowsRetryButton() {
        let retryButton = app.buttons["setup_retryButton"]
        XCTAssertTrue(retryButton.waitForExistence(timeout: 15), "Retry button should appear after setup failure")
    }

    func testSetupScreenshotCapture() {
        // Wait briefly for setup UI to render
        sleep(2)
        captureScreenshot(name: "screenshot_setup_checking")
    }
}
