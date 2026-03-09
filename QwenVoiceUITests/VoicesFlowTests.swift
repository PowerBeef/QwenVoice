import XCTest

final class VoicesFlowTests: FeatureMatrixUITestBase {
    func testEnrollPlayAndDeleteVoice() {
        launchStubApp(initialScreen: .voices)
        _ = waitForScreen(.voices, timeout: 15)
        XCTAssertTrue(waitForElement("voices_emptyState", timeout: 10).exists)

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
        XCTAssertTrue(waitForElement("voices_emptyState", timeout: 10).exists)
    }
}
