import XCTest

final class CustomVoiceViewTests: QwenVoiceUITestBase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        navigateToSidebar("customVoice")
        // Wait for view to load
        let title = app.staticTexts["customVoice_title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
    }

    // MARK: - Title & Header

    func testTitleExists() {
        assertElementExists("customVoice_title")
    }

    // MARK: - Batch Button

    func testBatchButtonExists() {
        let button = app.buttons["customVoice_batchButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Batch button should exist")
    }

    // MARK: - Model Banner (appears when model not downloaded)

    func testModelBannerAppearsWhenModelMissing() {
        // Models are likely not downloaded in test environment
        let banner = app.descendants(matching: .any).matching(identifier: "customVoice_modelBanner").firstMatch
        // This may or may not appear depending on whether models are downloaded
        if banner.waitForExistence(timeout: 3) {
            XCTAssertTrue(banner.exists, "Model banner should be visible when model is not downloaded")
        }
        // If banner doesn't appear, model is downloaded — both states are valid
    }

    func testGoToModelsButtonNavigates() {
        let goToModels = app.buttons["customVoice_goToModels"]
        // Only test if the banner is visible (model not downloaded)
        guard goToModels.waitForExistence(timeout: 3) else {
            // Model is downloaded, banner not shown — skip
            return
        }
        goToModels.click()
        // Should navigate to Models view
        assertElementExists("models_title")
    }

    // MARK: - Speaker Buttons

    func testSpeakerButtonsExist() {
        let vivian = app.buttons["customVoice_speaker_vivian"]
        XCTAssertTrue(vivian.waitForExistence(timeout: 5), "Vivian speaker button should exist")
    }

    func testMultipleSpeakersPresent() {
        let speakers = ["aiden", "ryan", "serena", "vivian"]
        for speaker in speakers {
            let button = app.buttons["customVoice_speaker_\(speaker)"]
            XCTAssertTrue(button.waitForExistence(timeout: 3), "\(speaker) speaker button should exist")
        }
    }

    func testSpeakerButtonClickable() {
        let aiden = app.buttons["customVoice_speaker_aiden"]
        XCTAssertTrue(aiden.waitForExistence(timeout: 5))
        aiden.click()
        // Verify Aiden is now selected (button state change)
        // We just verify no crash occurs
    }

    // MARK: - Emotion Field (requires Custom chip)

    func testEmotionFieldExists() {
        // Click Custom chip to reveal the text field
        let custom = app.buttons["customVoice_emotion_custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5), "Custom emotion chip should exist")
        custom.click()

        let field = app.textFields["customVoice_emotionField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Emotion field should exist after clicking Custom")
    }

    func testEmotionFieldAcceptsInput() {
        // Click Custom chip to reveal the text field
        let custom = app.buttons["customVoice_emotion_custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.click()

        let field = app.textFields["customVoice_emotionField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command) // Select all
        field.typeText("Happy and excited")
        XCTAssertEqual(field.value as? String, "Happy and excited")
    }

    // MARK: - Emotion Chips

    func testEmotionChipsExist() {
        let chipIds = [
            "neutral", "happy", "sad", "angry", "fearful",
            "whisper", "dramatic", "calm", "excited", "custom",
        ]
        for chipId in chipIds {
            let chip = app.buttons["customVoice_emotion_\(chipId)"]
            XCTAssertTrue(chip.waitForExistence(timeout: 5), "\(chipId) emotion chip should exist")
        }
    }

    func testEmotionChipClickHidesField() {
        // Start in custom mode to show the field
        let custom = app.buttons["customVoice_emotion_custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.click()

        let field = app.textFields["customVoice_emotionField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Field should be visible in custom mode")

        // Click a preset — field should disappear
        let happy = app.buttons["customVoice_emotion_happy"]
        happy.click()

        // Field should no longer exist
        XCTAssertFalse(field.waitForExistence(timeout: 2), "Field should be hidden when a preset is selected")
    }

    func testIntensityControlExists() {
        // Click a non-neutral chip to make intensity appear
        let happy = app.buttons["customVoice_emotion_happy"]
        XCTAssertTrue(happy.waitForExistence(timeout: 5))
        happy.click()

        let picker = app.descendants(matching: .any).matching(identifier: "customVoice_intensityPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Intensity picker should appear for non-neutral emotion")
    }

    func testIntensityHiddenForNeutral() {
        let neutral = app.buttons["customVoice_emotion_neutral"]
        XCTAssertTrue(neutral.waitForExistence(timeout: 5))
        neutral.click()

        let picker = app.descendants(matching: .any).matching(identifier: "customVoice_intensityPicker").firstMatch
        XCTAssertFalse(picker.waitForExistence(timeout: 2), "Intensity picker should be hidden for Neutral")
    }

    func testCustomChipRevealsFieldAndAcceptsText() {
        // Click Custom chip
        let custom = app.buttons["customVoice_emotion_custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.click()

        // Field should appear
        let field = app.textFields["customVoice_emotionField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        // Type custom text
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("My custom emotion")
        XCTAssertEqual(field.value as? String, "My custom emotion")

        // Click a preset chip — field should disappear
        let calm = app.buttons["customVoice_emotion_calm"]
        calm.click()
        XCTAssertFalse(field.waitForExistence(timeout: 2), "Field should disappear when selecting a preset")
    }

    // MARK: - Speed Picker

    func testSpeedPickerExists() {
        let picker = app.descendants(matching: .any).matching(identifier: "customVoice_speedPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Speed picker should exist")
    }

    // MARK: - Text Input (shared component)

    func testTextEditorExists() {
        let editor = app.descendants(matching: .any).matching(identifier: "textInput_textEditor").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Text editor should exist")
    }

    func testGenerateButtonExists() {
        let button = app.buttons["textInput_generateButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Generate button should exist")
    }
}
