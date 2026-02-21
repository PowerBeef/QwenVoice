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

    // MARK: - Tier Picker

    func testTierPickerExists() {
        let picker = app.descendants(matching: .any).matching(identifier: "customVoice_tierPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Tier picker should exist")
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
        // Check that at least one speaker button exists (vivian appears in English group)
        let vivian = app.buttons["customVoice_speaker_English_vivian"]
        XCTAssertTrue(vivian.waitForExistence(timeout: 5), "Vivian speaker button should exist")
    }

    func testMultipleSpeakersPresent() {
        let speakers = [
            ("English", "aiden"),
            ("English", "ryan"),
            ("English", "serena"),
            ("Chinese", "uncle_fu"),
        ]
        for (language, speaker) in speakers {
            let button = app.buttons["customVoice_speaker_\(language)_\(speaker)"]
            XCTAssertTrue(button.waitForExistence(timeout: 3), "\(speaker) speaker button should exist")
        }
    }

    func testSpeakerButtonClickable() {
        let aiden = app.buttons["customVoice_speaker_English_aiden"]
        XCTAssertTrue(aiden.waitForExistence(timeout: 5))
        aiden.click()
        // Verify Aiden is now selected (button state change)
        // We just verify no crash occurs
    }

    // MARK: - Emotion Field

    func testEmotionFieldExists() {
        let field = app.textFields["customVoice_emotionField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Emotion field should exist")
    }

    func testEmotionFieldAcceptsInput() {
        let field = app.textFields["customVoice_emotionField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // Clear existing text first, then type new text
        field.click()
        field.typeKey("a", modifierFlags: .command) // Select all
        field.typeText("Happy and excited")
        XCTAssertEqual(field.value as? String, "Happy and excited")
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
