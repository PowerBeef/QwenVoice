import XCTest

final class CustomVoiceViewTests: QwenVoiceUITestBase {
    override class var initialScreen: UITestScreen? { .customVoice }

    func testCustomVoiceScreenCoreLayout() {
        _ = waitForScreen(.customVoice)
        assertElementExists("customVoice_title")
        _ = waitForElement("customVoice_modeSwitch")
        _ = waitForElement("customVoice_mode_preset", type: .button)
        _ = waitForElement("customVoice_mode_design", type: .button)
        _ = waitForElement("customVoice_voiceSetup")
        _ = waitForElement("customVoice_toneSpeed")
        _ = waitForElement("customVoice_script")
        for speaker in UITestContractManifest.current.allSpeakers {
            _ = waitForElement("customVoice_speaker_\(speaker)", type: .button)
        }
        _ = waitForElement("delivery_tonePicker", type: .button)
        _ = waitForElement("delivery_speedPicker")
        _ = waitForElement("textInput_textEditor")
        _ = waitForElement("textInput_generateButton", type: .button)
        _ = waitForElement("textInput_batchButton", type: .button)
    }

    func testToneControlTransitions() {
        _ = waitForScreen(.customVoice)

        let customTone = openTonePickerAndSelect("delivery_tone_custom")
        customTone.click()

        let toneField = waitForElement("delivery_toneField", type: .textField)
        XCTAssertTrue(toneField.exists, "Custom tone field should appear")

        let happyTone = openTonePickerAndSelect("delivery_tone_happy")
        happyTone.click()
        XCTAssertTrue(
            waitForElement("delivery_intensityPicker", timeout: 5).exists,
            "Intensity control should appear for non-neutral tones"
        )

        let neutralTone = openTonePickerAndSelect("delivery_tone_neutral")
        neutralTone.click()
        XCTAssertFalse(
            app.textFields["delivery_toneField"].waitForExistence(timeout: 1),
            "Custom tone field should hide after returning to a preset"
        )
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "delivery_intensityPicker").firstMatch.waitForExistence(timeout: 1),
            "Intensity control should hide for neutral"
        )
    }

    func testModeSwitchTransitions() {
        _ = waitForScreen(.customVoice)

        let designMode = waitForElement("customVoice_mode_design", type: .button)
        designMode.click()
        _ = waitForElement("customVoice_voiceDescriptionField", type: .textField)
        _ = waitForElement("delivery_speedPicker", timeout: 5)

        let presetMode = waitForElement("customVoice_mode_preset", type: .button)
        presetMode.click()
        _ = waitForElement(
            "customVoice_speaker_\(UITestContractManifest.current.defaultSpeaker)",
            type: .button,
            timeout: 5
        )
    }

    func testDefaultSpeakerMatchesContract() {
        _ = waitForScreen(.customVoice)

        let defaultSpeaker = waitForElement(
            "customVoice_speaker_\(UITestContractManifest.current.defaultSpeaker)",
            type: .button
        )
        XCTAssertEqual(defaultSpeaker.value as? String, "selected")
    }

    func testTextInputsAcceptUserInput() {
        _ = waitForScreen(.customVoice)

        let customTone = openTonePickerAndSelect("delivery_tone_custom")
        customTone.click()
        let toneField = waitForElement("delivery_toneField", type: .textField)
        toneField.click()
        toneField.typeKey("a", modifierFlags: .command)
        toneField.typeText("Bright and energetic")
        XCTAssertEqual(toneField.value as? String, "Bright and energetic")

        let editor = waitForElement("textInput_textEditor")
        let modelBanner = app.descendants(matching: .any).matching(identifier: "customVoice_modelBanner").firstMatch
        if modelBanner.exists {
            XCTAssertFalse(editor.isEnabled, "Text input should be disabled when the active model is unavailable")
        } else {
            editor.click()
            editor.typeText("This is a UI test prompt.")
            XCTAssertTrue(
                app.staticTexts["textInput_charCount"].waitForExistence(timeout: 2),
                "Character count should remain visible after typing"
            )
        }

        let designMode = waitForElement("customVoice_mode_design", type: .button)
        designMode.click()
        let voiceField = waitForElement("customVoice_voiceDescriptionField", type: .textField)
        voiceField.click()
        voiceField.typeText("A calm narrator voice")
        XCTAssertTrue((voiceField.value as? String)?.contains("calm") ?? false)
    }

    private func openTonePickerAndSelect(_ identifier: String) -> XCUIElement {
        waitForElement("delivery_tonePicker", type: .button).click()
        return waitForElement(identifier, type: .button, timeout: 5)
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
