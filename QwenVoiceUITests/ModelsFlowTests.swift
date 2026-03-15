import XCTest

final class ModelsFlowTests: FeatureMatrixUITestBase {
    func testAppDefaultsToModelsWhenNoGenerationModelsAreInstalled() {
        launchStubApp()
        _ = waitForScreen(.models, timeout: 15)
        _ = waitForMainWindowTitle("Models", timeout: 5)
        _ = waitForDisabledSidebarItems([.customVoice, .voiceDesign, .voiceCloning], timeout: 5)
    }

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
        let deleteButton = app.alerts.firstMatch.buttons["Delete"].firstMatch.exists
            ? app.alerts.firstMatch.buttons["Delete"].firstMatch
            : app.sheets.firstMatch.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.click()
        XCTAssertTrue(
            app.buttons["models_download_\(customModelID)"].waitForExistence(timeout: 5),
            "Delete should transition back to the download state"
        )
    }

    func testCustomVoiceSidebarUnlocksPromptlyAfterDownload() {
        launchStubApp(initialScreen: .customVoice)
        _ = waitForScreen(.customVoice, timeout: 15)

        _ = waitForDisabledSidebarItems([.customVoice, .voiceDesign, .voiceCloning], timeout: 5)
        _ = waitForSidebarItemState(.customVoice, disabled: true, timeout: 2)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "customVoice_modelBanner").firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(identifier: "customVoice_goToModels").firstMatch.exists)

        ensureOnScreen(.models, timeout: 10)
        _ = waitForScreen(.models, timeout: 10)

        let customModelID = UITestContractManifest.current.model(mode: "custom")?.id ?? "pro_custom"
        waitForElement("models_download_\(customModelID)", type: .button, timeout: 10).click()
        XCTAssertTrue(
            app.buttons["models_delete_\(customModelID)"].waitForExistence(timeout: 10),
            "Downloading the custom model should transition to the ready/delete state"
        )

        _ = waitForDisabledSidebarItems([.voiceDesign, .voiceCloning], timeout: 10)
        _ = waitForSidebarItemState(.customVoice, disabled: false, timeout: 5)
        ensureOnScreen(.customVoice, timeout: 10)
        _ = waitForScreen(.customVoice, timeout: 5)
    }

    func testModelRetryEnablesVoiceDesignAndSupportsDefaultGenerationLaunch() {
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
            initialScreen: nil,
            additionalEnvironment: fixture.environment(
                additional: ["QWENVOICE_UI_TEST_SETUP_DELAY_MS": "150"]
            )
        )
        _ = waitForScreen(.voiceDesign, timeout: 15)
        _ = waitForMainWindowTitle("Voice Design", timeout: 5)
        _ = waitForDisabledSidebarItems([.customVoice, .voiceCloning], timeout: 5)
        _ = waitForSidebarItemState(.voiceDesign, disabled: false, timeout: 2)
    }
}
