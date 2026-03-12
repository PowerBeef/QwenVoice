import XCTest

final class VoiceCloningGenerationTests: FeatureMatrixUITestBase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture.installModel(mode: "clone")
        fixture.seedVoice()
    }

    func testSavedVoiceGenerationWithTranscript() {
        launchStubApp(initialScreen: .voiceCloning)
        _ = waitForScreen(.voiceCloning, timeout: 15)
        _ = waitForBackendIdle(timeout: 10)

        waitForElement("voiceCloning_savedVoice_fixture_voice", type: .button, timeout: 10).click()
        let editor = waitForElement("textInput_textEditor", timeout: 5)
        XCTAssertTrue(editor.isEnabled)
        editor.click()
        editor.typeText("Clone generation from saved voice.")
        let generate = waitForElementToBecomeEnabled("textInput_generateButton", type: .button, timeout: 5)
        generate.click()

        XCTAssertTrue(waitForElement("sidebarPlayer_bar", timeout: 10).exists)
        XCTAssertTrue(waitForElement("sidebarPlayer_liveBadge", timeout: 10).exists)
        XCTAssertTrue(
            app.staticTexts["fixture_voice.wav"].waitForExistence(timeout: 5)
                || app.textFields["voiceCloning_transcriptField"].value as? String == "Fixture transcript"
        )
    }

    func testImportedReferenceGenerationWithoutTranscript() {
        launchStubApp(initialScreen: .voiceCloning)
        _ = waitForScreen(.voiceCloning, timeout: 15)
        _ = waitForBackendIdle(timeout: 10)

        waitForElement("voiceCloning_importButton", type: .button, timeout: 5).click()
        XCTAssertTrue(
            app.staticTexts["import-reference.wav"].firstMatch.waitForExistence(timeout: 5)
        )

        let editor = waitForElement("textInput_textEditor", timeout: 5)
        XCTAssertTrue(editor.isEnabled)
        editor.click()
        editor.typeText("Clone generation from imported voice.")
        let generate = waitForElementToBecomeEnabled("textInput_generateButton", type: .button, timeout: 5)
        generate.click()

        XCTAssertTrue(waitForElement("sidebarPlayer_bar", timeout: 10).exists)
        XCTAssertTrue(waitForElement("sidebarPlayer_liveBadge", timeout: 10).exists)
    }
}
