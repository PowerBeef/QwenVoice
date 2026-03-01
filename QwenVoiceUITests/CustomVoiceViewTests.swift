import XCTest

final class CustomVoiceViewTests: QwenVoiceUITestBase {
    override class var initialScreen: UITestScreen? { .customVoice }

    func testCustomVoiceScreenCoreLayout() {
        _ = waitForScreen(.customVoice)
        assertElementExists("customVoice_title")
        _ = waitForElement("customVoice_batchButton", type: .button)
        _ = waitForElement("customVoice_speaker_vivian", type: .button)
        _ = waitForElement("customVoice_speaker_custom", type: .button)
        _ = waitForElement("customVoice_emotion_custom", type: .button)
        _ = waitForElement("customVoice_speedPicker")
        _ = waitForElement("textInput_textEditor")
        _ = waitForElement("textInput_generateButton", type: .button)
    }

    func testEmotionControlTransitions() {
        _ = waitForScreen(.customVoice)

        let customEmotion = waitForElement("customVoice_emotion_custom", type: .button)
        customEmotion.click()

        let emotionField = waitForElement("customVoice_emotionField", type: .textField)
        XCTAssertTrue(emotionField.exists, "Custom emotion field should appear")

        let happyEmotion = waitForElement("customVoice_emotion_happy", type: .button)
        happyEmotion.click()
        XCTAssertTrue(
            waitForElement("customVoice_intensityPicker", timeout: 5).exists,
            "Intensity control should appear for non-neutral emotions"
        )

        let neutralEmotion = waitForElement("customVoice_emotion_neutral", type: .button)
        neutralEmotion.click()
        XCTAssertFalse(
            app.textFields["customVoice_emotionField"].waitForExistence(timeout: 1),
            "Custom emotion field should hide after returning to a preset"
        )
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "customVoice_intensityPicker").firstMatch.waitForExistence(timeout: 1),
            "Intensity control should hide for neutral"
        )
    }

    func testCustomSpeakerTransitions() {
        _ = waitForScreen(.customVoice)

        let customSpeaker = waitForElement("customVoice_speaker_custom", type: .button)
        customSpeaker.click()
        _ = waitForElement("customVoice_voiceDescriptionField", type: .textField)
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "customVoice_speedPicker").firstMatch.waitForExistence(timeout: 1),
            "Speed picker should hide in custom speaker mode"
        )

        let presetSpeaker = waitForElement("customVoice_speaker_vivian", type: .button)
        presetSpeaker.click()
        _ = waitForElement("customVoice_speedPicker", timeout: 5)
    }

    func testTextInputsAcceptUserInput() {
        _ = waitForScreen(.customVoice)

        let customEmotion = waitForElement("customVoice_emotion_custom", type: .button)
        customEmotion.click()
        let emotionField = waitForElement("customVoice_emotionField", type: .textField)
        emotionField.click()
        emotionField.typeKey("a", modifierFlags: .command)
        emotionField.typeText("Bright and energetic")
        XCTAssertEqual(emotionField.value as? String, "Bright and energetic")

        let customSpeaker = waitForElement("customVoice_speaker_custom", type: .button)
        customSpeaker.click()
        let voiceField = waitForElement("customVoice_voiceDescriptionField", type: .textField)
        voiceField.click()
        voiceField.typeText("A calm narrator voice")
        XCTAssertTrue((voiceField.value as? String)?.contains("calm") ?? false)

        let editor = waitForElement("textInput_textEditor")
        editor.click()
        editor.typeText("This is a UI test prompt.")
        XCTAssertTrue(
            app.staticTexts["textInput_charCount"].waitForExistence(timeout: 2),
            "Character count should remain visible after typing"
        )
    }

    func testModelMissingNavigationPath() {
        _ = waitForScreen(.customVoice)

        let banner = app.descendants(matching: .any).matching(identifier: "customVoice_modelBanner").firstMatch
        guard banner.waitForExistence(timeout: 2) else {
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "screen_customVoice").firstMatch.exists)
            return
        }

        let goToModels = waitForElement("customVoice_goToModels", type: .button)
        goToModels.click()
        _ = waitForScreen(.models)
        assertElementExists("models_title")
    }
}
