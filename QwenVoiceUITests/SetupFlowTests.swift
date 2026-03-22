import XCTest

final class SetupFlowTests: QwenVoiceUITestBase {
    /// Override: do NOT skip setup in this test — we want to observe it.
    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitest", "--uitest-disable-animations"]
        app.launchEnvironment["QWENVOICE_UI_TEST"] = "1"
        app.launchEnvironment["QWENVOICE_UI_TEST_BACKEND_MODE"] = "stub"
        app.launchEnvironment["QWENVOICE_UI_TEST_SETUP_SCENARIO"] = "fail_once"
        app.launchEnvironment["QWENVOICE_UI_TEST_SETUP_DELAY_MS"] = "50"
        app.launch()
    }

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
