import XCTest

final class VoicesFlowTests: FeatureMatrixUITestBase {
    func testAddPreviewAndDeleteSavedVoice() {
        launchStubApp(initialScreen: .voices)
        _ = waitForScreen(.voices, timeout: 15)
        waitForVoicesLibraryToSettle()

        waitForElement("voices_enrollButton", type: .button, timeout: 5).click()
        let nameField = waitForElement("voicesEnroll_nameField", type: .textField, timeout: 5)
        nameField.click()
        nameField.typeText("Stub Voice")

        waitForElement("voicesEnroll_browseButton", type: .button, timeout: 5).click()

        let transcriptField = waitForTranscriptField(timeout: 5)
        transcriptField.click()
        transcriptField.typeText("This is the saved voice transcript.")
        waitForElement("voicesEnroll_confirmButton", type: .button, timeout: 5).click()

        let savedName = normalizedVoiceName("Stub Voice")
        XCTAssertTrue(
            app.buttons["voicesRow_play_\(savedName)"].waitForExistence(timeout: 10),
            "The newly added saved voice should appear in the list"
        )

        app.buttons["voicesRow_play_\(savedName)"].click()
        XCTAssertTrue(waitForElement("sidebarPlayer_bar", timeout: 5).exists)
        waitForElement("sidebarPlayer_dismiss", type: .button, timeout: 5).click()

        app.buttons["voicesRow_delete_\(savedName)"].click()
        let deleteButton = app.alerts.firstMatch.buttons["Delete"].firstMatch.exists
            ? app.alerts.firstMatch.buttons["Delete"].firstMatch
            : app.sheets.firstMatch.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.click()
        waitForVoiceToDisappear(named: savedName)
    }

    func testSavedVoiceCanJumpDirectlyToVoiceCloning() {
        fixture.installModel(mode: "clone")
        launchStubApp(initialScreen: .voices)
        _ = waitForScreen(.voices, timeout: 15)
        waitForVoicesLibraryToSettle()

        addSavedVoice(named: "Routing Voice", transcript: "This voice should route directly to Voice Cloning.")
        let savedName = normalizedVoiceName("Routing Voice")

        waitForElement("voicesRow_use_\(savedName)", type: .button, timeout: 5).click()
        _ = waitForScreen(.voiceCloning, timeout: 10)
        _ = waitForMainWindowTitle("Voice Cloning")
        XCTAssertTrue(
            waitForElement("voiceCloning_activeReference", timeout: 5).exists,
            "Using a saved voice should preload the Voice Cloning reference"
        )

        let savedVoicePicker = waitForElement("voiceCloning_savedVoicePicker", timeout: 5)
        let pickerText = [savedVoicePicker.label, savedVoicePicker.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertTrue(
            pickerText.contains(savedName),
            "Voice Cloning should select the saved voice that launched the handoff"
        )
    }

    func testDuplicateSavedVoiceNamesAreRejected() {
        launchStubApp(initialScreen: .voices)
        _ = waitForScreen(.voices, timeout: 15)
        waitForVoicesLibraryToSettle()

        addSavedVoice(named: "Duplicate Voice", transcript: "Original transcript.")

        waitForElement("voices_enrollButton", type: .button, timeout: 5).click()
        let nameField = waitForElement("voicesEnroll_nameField", type: .textField, timeout: 5)
        nameField.click()
        nameField.typeText("Duplicate Voice")

        waitForElement("voicesEnroll_browseButton", type: .button, timeout: 5).click()
        waitForElement("voicesEnroll_confirmButton", type: .button, timeout: 5).click()

        let duplicateMessage = app.staticTexts["voicesEnroll_errorMessage"].firstMatch
        XCTAssertTrue(
            duplicateMessage.waitForExistence(timeout: 5),
            "Adding a duplicate saved voice name should surface inline validation"
        )

        let savedName = normalizedVoiceName("Duplicate Voice")
        XCTAssertEqual(
            app.buttons.matching(identifier: "voicesRow_play_\(savedName)").count,
            1,
            "Duplicate validation should prevent a second saved voice from being created"
        )
    }

    private func addSavedVoice(named name: String, transcript: String) {
        waitForElement("voices_enrollButton", type: .button, timeout: 5).click()

        let nameField = waitForElement("voicesEnroll_nameField", type: .textField, timeout: 5)
        nameField.click()
        nameField.typeText(name)

        waitForElement("voicesEnroll_browseButton", type: .button, timeout: 5).click()
        let transcriptField = waitForTranscriptField(timeout: 5)
        transcriptField.click()
        transcriptField.typeText(transcript)
        waitForElement("voicesEnroll_confirmButton", type: .button, timeout: 5).click()

        XCTAssertTrue(
            app.buttons["voicesRow_play_\(normalizedVoiceName(name))"].waitForExistence(timeout: 10)
        )
    }

    private func normalizedVoiceName(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "_")
    }

    private func waitForTranscriptField(timeout: TimeInterval) -> XCUIElement {
        let textView = app.textViews["voicesEnroll_transcriptField"].firstMatch
        if textView.waitForExistence(timeout: timeout) {
            return textView
        }

        let identified = app.descendants(matching: .any).matching(identifier: "voicesEnroll_transcriptField").firstMatch
        if identified.waitForExistence(timeout: timeout) {
            return identified
        }

        XCTFail("Saved voice transcript field should exist within \(timeout)s")
        return identified
    }

    private func waitForVoicesLibraryToSettle(timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let emptyState = app.descendants(matching: .any).matching(identifier: "voices_emptyState").firstMatch
            if emptyState.exists {
                return
            }

            if !app.staticTexts["Loading saved voices..."].exists && !app.staticTexts["Starting backend..."].exists {
                return
            }

            usleep(200_000)
        }

        XCTFail("Saved Voices should settle within \(timeout)s")
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

        XCTFail("Saved voice '\(voiceName)' should disappear from the library within \(timeout)s")
    }
}
