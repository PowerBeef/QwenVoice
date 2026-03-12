import XCTest

final class VoiceDesignFlowTests: FeatureMatrixUITestBase {
    func testVoiceDesignGenerationCreatesHistoryEntry() throws {
        fixture.installModel(mode: "custom")
        fixture.installModel(mode: "design")

        launchStubApp(initialScreen: .customVoice)
        _ = waitForScreen(.customVoice, timeout: 15)
        _ = waitForBackendIdle(timeout: 10)

        waitForElement("customVoice_mode_design", type: .button, timeout: 5).click()

        let voiceDescription = waitForElement("customVoice_voiceDescriptionField", type: .textField, timeout: 5)
        voiceDescription.click()
        voiceDescription.typeText("A measured documentary narrator.")

        let editor = waitForElement("textInput_textEditor", timeout: 5)
        XCTAssertTrue(editor.isEnabled)
        editor.click()
        editor.typeText("Voice design test generation.")

        let generate = waitForElementToBecomeEnabled("textInput_generateButton", type: .button, timeout: 5)
        generate.click()
        XCTAssertTrue(waitForElement("sidebarPlayer_bar", timeout: 10).exists)
        XCTAssertTrue(waitForElement("sidebarPlayer_liveBadge", timeout: 10).exists)

        ensureOnScreen(.history, timeout: 10)
        XCTAssertTrue(
            app.staticTexts["Voice design test generation."].firstMatch.waitForExistence(timeout: 10)
                || app.staticTexts["Voice design test generation..."].firstMatch.waitForExistence(timeout: 10)
        )
    }
}
