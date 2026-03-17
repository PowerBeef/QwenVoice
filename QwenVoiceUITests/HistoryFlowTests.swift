import XCTest

final class HistoryFlowTests: FeatureMatrixUITestBase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try fixture.seedHistoryEntry(
            text: "Alpha history fixture",
            mode: "custom",
            voice: "Vivian",
            fileName: "alpha.wav"
        )
        try fixture.seedHistoryEntry(
            text: "Bravo history fixture",
            mode: "clone",
            voice: "fixture_voice",
            fileName: "bravo.wav"
        )
    }

    func testSearchAndDeleteFlow() {
        launchStubApp(initialScreen: .history)
        _ = waitForScreen(.history, timeout: 15)
        XCTAssertTrue(app.staticTexts["Alpha history fixture"].firstMatch.waitForExistence(timeout: 5))

        let search = waitForHistorySearchField(timeout: 5)
        search.click()
        search.typeText("Bravo")

        XCTAssertTrue(app.staticTexts["Bravo history fixture"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Alpha history fixture"].firstMatch.exists)

        _ = waitForElement("historyRow_generation-2", timeout: 5)
        let deleteRowButton = waitForElement("historyRow_delete", type: .button, timeout: 5)
        deleteRowButton.click()
        let deleteButton = app.alerts.firstMatch.buttons["Delete"].firstMatch.exists
            ? app.alerts.firstMatch.buttons["Delete"].firstMatch
            : app.sheets.firstMatch.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.click()

        let deletedRow = app.descendants(matching: .any).matching(identifier: "historyRow_generation-2").firstMatch
        XCTAssertTrue(deletedRow.waitForNonExistence(timeout: 5))
    }

    func testPartialCleanupWarningPath() {
        launchStubApp(
            initialScreen: .history,
            additionalEnvironment: ["QWENVOICE_UI_TEST_FAULT_HISTORY_DELETE_AUDIO": "1"]
        )
        _ = waitForScreen(.history, timeout: 15)
        XCTAssertTrue(app.staticTexts["Alpha history fixture"].firstMatch.waitForExistence(timeout: 5))

        waitForElement("historyRow_delete", type: .button, timeout: 5).click()
        let deleteButton = app.alerts.firstMatch.buttons["Delete"].firstMatch.exists
            ? app.alerts.firstMatch.buttons["Delete"].firstMatch
            : app.sheets.firstMatch.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.click()

        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5) || app.sheets.firstMatch.waitForExistence(timeout: 5))
    }

    func testCloneRowsCanSaveToSavedVoices() {
        launchStubApp(initialScreen: .history)
        _ = waitForScreen(.history, timeout: 15)

        XCTAssertTrue(
            app.buttons["historyRow_saveVoice_generation-2"].firstMatch.exists,
            "Clone history rows should expose Save to Saved Voices"
        )

        XCTAssertFalse(
            app.buttons["historyRow_saveVoice_generation-1"].firstMatch.exists,
            "Non-clone history rows should not expose Save to Saved Voices"
        )

        app.buttons["historyRow_saveVoice_generation-2"].firstMatch.click()

        let transcriptField = app.descendants(matching: .any).matching(identifier: "voicesEnroll_transcriptField").firstMatch
        XCTAssertTrue(transcriptField.waitForExistence(timeout: 5))
        waitForElement("voicesEnroll_confirmButton", type: .button, timeout: 5).click()

        XCTAssertTrue(
            app.alerts.firstMatch.waitForExistence(timeout: 5) || app.sheets.firstMatch.waitForExistence(timeout: 5),
            "Saving a clone into Saved Voices should confirm success"
        )
    }
}
