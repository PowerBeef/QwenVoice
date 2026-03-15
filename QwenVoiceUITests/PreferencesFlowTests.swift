import XCTest

final class PreferencesFlowTests: FeatureMatrixUITestBase {
    func testPlaybackAndOutputDirectoryPersistAcrossRelaunch() {
        launchStubApp(initialScreen: .preferences)
        _ = waitForScreen(.preferences, timeout: 15)

        let autoPlayToggle = waitForElement("preferences_autoPlayToggle", timeout: 5)
        let originalValue = String(describing: autoPlayToggle.value ?? "")
        autoPlayToggle.click()
        let deadline = Date().addingTimeInterval(5)
        var toggledValue = String(describing: app.descendants(matching: .any).matching(identifier: "preferences_autoPlayToggle").firstMatch.value ?? "")
        while Date() < deadline && toggledValue == originalValue {
            usleep(200_000)
            toggledValue = String(describing: app.descendants(matching: .any).matching(identifier: "preferences_autoPlayToggle").firstMatch.value ?? "")
        }
        XCTAssertNotEqual(originalValue, toggledValue)

        waitForElement("preferences_browseButton", type: .button, timeout: 5).click()
        let outputField = waitForElement("preferences_outputDirectory", type: .textField, timeout: 5)
        XCTAssertEqual(outputField.value as? String, fixture.outputDirectoryURL.path)

        waitForElement("preferences_openFinderButton", type: .button, timeout: 5).click()
        assertEventMarkerExists("open-app-support")

        relaunchFreshApp(
            initialScreen: .preferences,
            additionalEnvironment: fixture.environment()
        )
        _ = waitForScreen(.preferences, timeout: 15)

        let persistedToggle = waitForElement("preferences_autoPlayToggle", timeout: 5)
        XCTAssertTrue(persistedToggle.exists)
        XCTAssertEqual(String(describing: persistedToggle.value ?? ""), toggledValue)
        XCTAssertEqual(
            waitForElement("preferences_outputDirectory", type: .textField, timeout: 5).value as? String,
            fixture.outputDirectoryURL.path
        )
    }

    func testResetEnvironmentConfirmationCompletesSetupCycle() {
        launchStubApp(
            initialScreen: .preferences,
            additionalEnvironment: ["QWENVOICE_UI_TEST_SETUP_DELAY_MS": "250"]
        )
        _ = waitForScreen(.preferences, timeout: 15)

        clickMaintenanceResetButton()

        let confirmButtons = app.descendants(matching: .button).matching(
            NSPredicate(format: "label == 'Reset' OR label == 'Restart'")
        )
        let confirmButton = confirmButtons.firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.click()

        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "setup_title").firstMatch.waitForExistence(timeout: 10)
        )

        let returnedToPreferences = app.descendants(matching: .any)
            .matching(identifier: UITestScreen.preferences.rootIdentifier)
            .firstMatch
            .waitForExistence(timeout: 20)
        if !returnedToPreferences {
            _ = waitForScreen(.customVoice, timeout: 20)
        }
    }

    private func clickMaintenanceResetButton() {
        let resetButton = waitForElement("preferences_resetEnvButton", type: .button, timeout: 5)
        if resetButton.isHittable {
            resetButton.click()
            return
        }

        let preferencesScrollView = app.scrollViews.matching(identifier: "screen_preferences").firstMatch
        let scrollContainer = preferencesScrollView.exists ? preferencesScrollView : app.scrollViews.firstMatch

        for _ in 0..<4 {
            scrollContainer.swipeUp()
            if resetButton.isHittable {
                resetButton.click()
                return
            }
        }

        XCTFail("Reset Environment button should become hittable after scrolling Preferences")
    }
}
