import XCTest

final class ModelsFlowTests: FeatureMatrixUITestBase {
    func testModelDownloadAndDeleteTransitions() {
        launchStubApp(initialScreen: .models)
        _ = waitForScreen(.models, timeout: 15)

        let customModelID = UITestContractManifest.current.model(mode: "custom")?.id ?? "pro_custom"
        let download = waitForElement("models_download_\(customModelID)", type: .button, timeout: 10)
        download.click()

        XCTAssertTrue(
            app.buttons["models_delete_\(customModelID)"].waitForExistence(timeout: 10),
            "Download should transition to the ready/delete state"
        )

        app.buttons["models_delete_\(customModelID)"].click()
        XCTAssertTrue(
            app.buttons["models_download_\(customModelID)"].waitForExistence(timeout: 5),
            "Delete should transition back to the download state"
        )
    }

    func testModelRetryAndBannerNavigation() {
        let designModelID = UITestContractManifest.current.model(mode: "design")?.id ?? "pro_design"
        launchStubApp(
            initialScreen: .models,
            additionalEnvironment: ["QWENVOICE_UI_TEST_MODEL_DOWNLOAD_FAIL_ONCE": designModelID]
        )
        _ = waitForScreen(.models, timeout: 15)

        waitForElement("models_download_\(designModelID)", type: .button, timeout: 10).click()
        XCTAssertTrue(
            app.buttons["models_retry_\(designModelID)"].waitForExistence(timeout: 10),
            "The fail-once download should surface the retry action"
        )

        app.buttons["models_retry_\(designModelID)"].click()
        XCTAssertTrue(
            app.buttons["models_delete_\(designModelID)"].waitForExistence(timeout: 10),
            "Retry should succeed and transition to the ready/delete state"
        )

        relaunchFreshApp(
            initialScreen: .customVoice,
            additionalEnvironment: fixture.environment(
                additional: ["QWENVOICE_UI_TEST_SETUP_DELAY_MS": "150"]
            )
        )
        _ = waitForScreen(.customVoice, timeout: 15)
        let banner = waitForElement("customVoice_modelBanner", timeout: 5)
        XCTAssertTrue(banner.exists)
        waitForElement("customVoice_goToModels", type: .button, timeout: 5).click()
        _ = waitForScreen(.models, timeout: 10)
    }
}
