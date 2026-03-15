import XCTest

final class VoicesFlowTests: FeatureMatrixUITestBase {
    func testEnrollPlayAndDeleteVoice() {
        launchStubApp(initialScreen: .voices)
        _ = waitForScreen(.voices, timeout: 15)
        waitForVoicesLibraryToSettle()

        waitForElement("voices_enrollButton", type: .button, timeout: 5).click()
        let nameField = waitForElement("voicesEnroll_nameField", type: .textField, timeout: 5)
        nameField.click()
        nameField.typeText("Stub Voice")

        waitForElement("voicesEnroll_browseButton", type: .button, timeout: 5).click()

        let transcriptField = waitForElement("voicesEnroll_transcriptField", type: .textField, timeout: 5)
        transcriptField.click()
        transcriptField.typeText("This is the enrolled voice transcript.")
        waitForElement("voicesEnroll_confirmButton", type: .button, timeout: 5).click()

        XCTAssertTrue(
            app.buttons["voicesRow_play_Stub Voice"].waitForExistence(timeout: 10),
            "The newly enrolled voice should appear in the list"
        )

        app.buttons["voicesRow_play_Stub Voice"].click()
        XCTAssertTrue(waitForElement("sidebarPlayer_bar", timeout: 5).exists)

        app.buttons["voicesRow_delete_Stub Voice"].click()
        let deleteButton = app.alerts.firstMatch.buttons["Delete"].firstMatch.exists
            ? app.alerts.firstMatch.buttons["Delete"].firstMatch
            : app.sheets.firstMatch.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.click()
        waitForVoiceToDisappear(named: "Stub Voice")
    }

    private func waitForVoicesLibraryToSettle(timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let emptyState = app.descendants(matching: .any).matching(identifier: "voices_emptyState").firstMatch
            if emptyState.exists {
                return
            }

            if !app.staticTexts["Loading voices..."].exists && !app.staticTexts["Starting backend..."].exists {
                return
            }

            usleep(200_000)
        }

        XCTFail("Voices library should settle within \(timeout)s")
    }

    private func waitForVoiceToDisappear(named voiceName: String, timeout: TimeInterval = 10) {
        let playButton = app.buttons["voicesRow_play_\(voiceName)"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let emptyState = app.descendants(matching: .any).matching(identifier: "voices_emptyState").firstMatch
            if emptyState.exists || !playButton.exists {
                return
            }
            usleep(200_000)
        }

        XCTFail("Voice '\(voiceName)' should disappear from the library within \(timeout)s")
    }
}
