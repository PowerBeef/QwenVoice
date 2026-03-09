import XCTest

final class SetupFlowTests: FeatureMatrixUITestBase {
    func testSetupProgressTransitionsToMainUI() {
        launchStubApp(
            initialScreen: nil,
            setupScenario: .success,
            additionalEnvironment: ["QWENVOICE_UI_TEST_SETUP_DELAY_MS": "450"]
        )

        let progressIdentifiers = [
            "setup_checkingLabel",
            "setup_findingPythonLabel",
            "setup_creatingVenvLabel",
            "setup_progressLabel",
            "setup_updatingDepsLabel",
        ]
        let deadline = Date().addingTimeInterval(10)
        var sawProgressState = false
        while Date() < deadline {
            if progressIdentifiers.contains(where: {
                app.descendants(matching: .any).matching(identifier: $0).firstMatch.exists
            }) {
                sawProgressState = true
                break
            }
            usleep(200_000)
        }

        XCTAssertTrue(sawProgressState, "Expected at least one setup progress state before the main UI appears")

        _ = waitForScreen(.customVoice, timeout: 20)
    }

    func testSetupFailureThenRetrySucceeds() {
        launchStubApp(
            initialScreen: nil,
            setupScenario: .failOnce,
            additionalEnvironment: ["QWENVOICE_UI_TEST_SETUP_DELAY_MS": "350"]
        )

        XCTAssertTrue(waitForElement("setup_errorTitle", timeout: 10).exists)
        waitForElement("setup_retryButton", type: .button, timeout: 5).click()
        _ = waitForScreen(.customVoice, timeout: 20)
    }
}
