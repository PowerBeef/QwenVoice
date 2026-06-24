import XCTest

/// End-to-end regression tests for the iOS model download manager.
///
/// These run in the simulator with the simulated download backend so they don't
/// need a real iPhone or network. They exercise the full user flow through the
/// Settings model list: install, pause, resume, cancel, and delete.
///
/// Each test launches its own app instance with `QVOICE_SIM_FAKE_MODELS=none`
/// so the models start in the not-installed state.
final class VocelloiOSDownloadManagerUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("simulator-only download backend (QVOICE_SIM_* env is ignored on device)")
        #endif
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchEnvironment["QVOICE_IOS_DISABLE_ENGINE"] = "1"
        app.launchEnvironment["QVOICE_SIM_FAKE_MODELS"] = "none"
        app.launchEnvironment["QVOICE_SIM_SEED_DATA"] = "voices,history"
        app.launchEnvironment["QVOICE_SIM_BACKEND_DELAY_MS"] = "500"
        app.launch()

        VocelloUITestApp.dismissOnboardingIfPresent(in: app)
        navigateToSettings()
        uninstallProCustomIfNeeded()
    }

    override func tearDownWithError() throws {
        if app != nil, app.state == .runningForeground || app.state == .runningBackground {
            app.terminate()
        }
        app = nil
    }

    // MARK: - Flows

    /// Install a model, pause mid-download, resume, and let it complete.
    func testDownloadPauseResumeAndComplete() {
        let installButton = element("iosModelDownload_pro_custom")
        XCTAssertTrue(installButton.waitForExistence(timeout: 10), "Install button should be visible")
        installButton.tap()

        // Wait for the Cancel button to appear, then pause.
        let cancelButton = element("iosModelCancel_pro_custom")
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 10), "Cancel button should appear after starting download")
        cancelButton.tap()

        let pauseButton = element("iosModelPauseConfirmButton")
        XCTAssertTrue(pauseButton.waitForExistence(timeout: 10), "Pause option should be offered in the confirmation dialog")
        pauseButton.tap()

        let resumeButton = element("iosModelResume_pro_custom")
        XCTAssertTrue(resumeButton.waitForExistence(timeout: 30), "Resume button should appear while paused")
        captureScreenshot(named: "download-paused-pro-custom")

        resumeButton.tap()

        // Wait for the install to finish: the delete button means it's installed.
        let deleteButton = element("iosModelDelete_pro_custom")
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 60), "Model should finish installing")
        captureScreenshot(named: "download-completed-pro-custom")

        // Clean up so the next test starts from a not-installed state.
        deleteButton.tap()
        confirmDeleteModel()
        XCTAssertTrue(installButton.waitForExistence(timeout: 30), "Install button should return after deleting the model")
    }

    /// Start a download and choose "Cancel Download" from the pause/cancel dialog.
    /// Partial data should be discarded and the Install button should reappear.
    func testDownloadCancel() {
        let installButton = element("iosModelDownload_pro_custom")
        XCTAssertTrue(installButton.waitForExistence(timeout: 10), "Install button should be visible")
        installButton.tap()

        let cancelButton = element("iosModelCancel_pro_custom")
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 10), "Cancel button should appear after starting download")
        cancelButton.tap()

        let cancelDownloadButton = element("iosModelCancelDownloadConfirmButton")
        XCTAssertTrue(cancelDownloadButton.waitForExistence(timeout: 10), "Cancel Download option should be offered")
        cancelDownloadButton.tap()

        if !installButton.waitForExistence(timeout: 20) {
            print("=== Accessibility hierarchy after cancel ===")
            print(app.debugDescription)
            print("=== End hierarchy ===")
            XCTFail("Install button should reappear after cancelling")
        }
        captureScreenshot(named: "download-cancelled-pro-custom")
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func navigateToSettings() {
        let settingsTab = element("rootTab_settings")
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 30), "Settings tab should exist")
        settingsTab.tap()
        XCTAssertTrue(element("iosModelRow_pro_custom").waitForExistence(timeout: 10), "Model row should be visible in Settings")
    }

    private func uninstallProCustomIfNeeded() {
        let deleteButton = element("iosModelDelete_pro_custom")
        guard deleteButton.waitForExistence(timeout: 5) else { return }
        deleteButton.tap()
        confirmDeleteModel()
        XCTAssertTrue(element("iosModelDownload_pro_custom").waitForExistence(timeout: 30), "Model should be not installed after cleanup")
    }

    private func confirmDeleteModel() {
        let confirm = element("deleteModelSheet_confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Delete model confirmation should appear")
        confirm.tap()
    }

    private func captureScreenshot(named name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Screenshot: \(name)") { activity in
            activity.add(attachment)
        }
    }
}
