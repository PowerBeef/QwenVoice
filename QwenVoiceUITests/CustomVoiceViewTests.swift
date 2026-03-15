import XCTest

final class CustomVoiceViewTests: QwenVoiceUITestBase {
    override class var launchPolicy: UITestLaunchPolicy { .freshPerTest }
    override class var initialScreen: UITestScreen? { .customVoice }

    func testCustomVoiceScreenCoreLayout() {
        _ = waitForScreen(.customVoice)
        _ = waitForMainWindowTitle("Custom Voice")
        let configuration = waitForElement("customVoice_configuration")
        let script = waitForElement("customVoice_script")
        XCTAssertLessThan(
            configuration.frame.minY,
            script.frame.minY,
            "Configuration should be the first visible content section on Custom Voice"
        )
        _ = waitForCustomVoiceSpeakerPicker()
        _ = waitForElement("delivery_tonePicker")
        _ = waitForElement("textInput_textEditor")
        _ = waitForElement("textInput_generateButton", type: .button)
        _ = waitForElement("textInput_batchButton", type: .button)
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "customVoice_modeSwitch").firstMatch.waitForExistence(timeout: 1),
            "The legacy embedded mode switch should no longer be present on Custom Voice"
        )
    }

    func testToneControlTransitions() {
        _ = waitForScreen(.customVoice)

        let neutralTonePicker = waitForElement("delivery_tonePicker")
        let neutralToneFrame = neutralTonePicker.frame
        let neutralToneField = waitForCustomToneField()
        let neutralToneFieldFrame = neutralToneField.frame
        assertIntensityPickerIsDisabled(referenceToneFrame: neutralToneFrame)
        assertCustomToneFieldState(enabled: false, referenceFieldFrame: neutralToneFieldFrame)

        let customTone = openTonePickerAndSelect("delivery_tone_custom")
        customTone.click()

        let toneField = waitForCustomToneField()
        XCTAssertTrue(toneField.exists, "Custom tone field should remain visible")
        toneField.click()
        toneField.typeKey("a", modifierFlags: .command)
        toneField.typeText("Bright and energetic")
        assertIntensityPickerIsDisabled(referenceToneFrame: neutralToneFrame)
        assertCustomToneFieldState(enabled: true, referenceFieldFrame: neutralToneFieldFrame)
        assertEmotionValue("Bright and energetic")

        let happyTone = openTonePickerAndSelect("delivery_tone_happy")
        happyTone.click()
        assertIntensityPickerIsInline(referenceToneFrame: neutralToneFrame)
        assertCustomToneFieldState(enabled: false, referenceFieldFrame: neutralToneFieldFrame)

        let customToneAgain = openTonePickerAndSelect("delivery_tone_custom")
        customToneAgain.click()
        assertIntensityPickerIsDisabled(referenceToneFrame: neutralToneFrame)
        assertCustomToneFieldState(enabled: true, referenceFieldFrame: neutralToneFieldFrame)
        XCTAssertEqual(waitForCustomToneField().value as? String, "Bright and energetic")
        assertEmotionValue("Bright and energetic")

        let neutralTone = openTonePickerAndSelect("delivery_tone_neutral")
        neutralTone.click()
        assertIntensityPickerIsDisabled(referenceToneFrame: neutralToneFrame)
        assertCustomToneFieldState(enabled: false, referenceFieldFrame: neutralToneFieldFrame)
    }

    func testSpeakerSelectionTransitions() {
        _ = waitForScreen(.customVoice)

        let defaultSpeaker = UITestContractManifest.current.defaultSpeaker
        let alternateSpeaker = UITestContractManifest.current.allSpeakers.first(where: { $0 != defaultSpeaker }) ?? defaultSpeaker
        let alternateSpeakerItem = openSpeakerPickerAndSelect(alternateSpeaker.capitalized)
        alternateSpeakerItem.click()
        XCTAssertTrue(selectedSpeakerValue()?.contains(alternateSpeaker.capitalized) ?? false)
    }

    func testDefaultSpeakerMatchesContract() {
        _ = waitForScreen(.customVoice)

        XCTAssertTrue(
            selectedSpeakerValue()?.contains(UITestContractManifest.current.defaultSpeaker.capitalized) ?? false
        )
    }

    func testTextInputsAcceptUserInput() {
        _ = waitForScreen(.customVoice)

        let customTone = openTonePickerAndSelect("delivery_tone_custom")
        customTone.click()
        let toneField = waitForCustomToneField()
        toneField.click()
        toneField.typeKey("a", modifierFlags: .command)
        toneField.typeText("Bright and energetic")
        XCTAssertEqual(toneField.value as? String, "Bright and energetic")

        let editor = waitForElement("textInput_textEditor")
        let modelBanner = app.descendants(matching: .any).matching(identifier: "customVoice_modelBanner").firstMatch
        if modelBanner.waitForExistence(timeout: 1) {
            XCTAssertFalse(editor.isEnabled, "Text input should be disabled when the active model is unavailable")
        } else {
            editor.click()
            editor.typeText("This is a UI test prompt.")
            XCTAssertTrue(
                app.staticTexts["textInput_charCount"].waitForExistence(timeout: 2),
                "Character count should remain visible after typing"
            )
        }

        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "customVoice_voiceDescriptionField").firstMatch.waitForExistence(timeout: 1),
            "Voice Design inputs should live on the dedicated Voice Design screen"
        )
    }

    private func openTonePickerAndSelect(_ identifier: String) -> XCUIElement {
        app.activate()
        waitForElement("delivery_tonePicker").click()
        app.activate()

        let identifiedButton = app.buttons.matching(identifier: identifier).firstMatch
        if identifiedButton.waitForExistence(timeout: 2) {
            return identifiedButton
        }

        let label = toneMenuLabel(for: identifier)
        let menuItem = app.menuItems[label].firstMatch
        if menuItem.waitForExistence(timeout: 2) {
            return menuItem
        }

        let labeledButton = app.buttons[label].firstMatch
        if labeledButton.waitForExistence(timeout: 2) {
            return labeledButton
        }

        XCTFail("Tone menu item '\(identifier)' should exist")
        return identifiedButton
    }

    private func waitForCustomToneField(timeout: TimeInterval = 5) -> XCUIElement {
        let identified = app.textFields["delivery_toneField"].firstMatch
        if identified.waitForExistence(timeout: min(timeout, 1.5)) {
            return identified
        }

        let placeholder = app.textFields["Describe the delivery in your own words"].firstMatch
        if placeholder.waitForExistence(timeout: timeout) {
            return placeholder
        }

        XCTFail("Custom tone field should exist within \(timeout)s")
        return identified
    }

    private func waitForEmotionValue(timeout: TimeInterval = 5) -> XCUIElement {
        let marker = app.descendants(matching: .any).matching(identifier: "delivery_emotionValue").firstMatch
        XCTAssertTrue(
            marker.waitForExistence(timeout: timeout),
            "Emotion value marker should exist within \(timeout)s"
        )
        return marker
    }

    private func assertIntensityPickerIsInline(
        referenceToneFrame: CGRect? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tonePicker = waitForElement("delivery_tonePicker")
        let intensityPicker = waitForElement("delivery_intensityPicker", timeout: 5)

        XCTAssertTrue(intensityPicker.exists, "Intensity control should appear for non-neutral tones", file: file, line: line)
        XCTAssertTrue(intensityPicker.isEnabled, "Intensity control should be enabled for non-neutral tones", file: file, line: line)
        if let referenceToneFrame {
            XCTAssertLessThan(
                abs(tonePicker.frame.minX - referenceToneFrame.minX),
                4,
                "Tone picker should stay horizontally stable when intensity becomes available",
                file: file,
                line: line
            )
            XCTAssertLessThan(
                abs(tonePicker.frame.minY - referenceToneFrame.minY),
                4,
                "Tone picker should stay vertically stable when intensity becomes available",
                file: file,
                line: line
            )
        }
        XCTAssertLessThan(
            abs(intensityPicker.frame.midY - tonePicker.frame.midY),
            18,
            "Intensity picker should align horizontally with the tone picker at default width",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            intensityPicker.frame.minX,
            tonePicker.frame.maxX,
            "Intensity picker should render to the right of the tone picker at default width",
            file: file,
            line: line
        )
    }

    private func assertIntensityPickerIsDisabled(
        referenceToneFrame: CGRect? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tonePicker = waitForElement("delivery_tonePicker")
        let intensityPicker = waitForElement("delivery_intensityPicker", timeout: 5)

        XCTAssertTrue(intensityPicker.exists, "Intensity control should remain visible when not applicable", file: file, line: line)
        XCTAssertFalse(intensityPicker.isEnabled, "Intensity control should be disabled when not applicable", file: file, line: line)
        if let referenceToneFrame {
            XCTAssertLessThan(
                abs(tonePicker.frame.minX - referenceToneFrame.minX),
                4,
                "Tone picker should stay horizontally stable when intensity is disabled",
                file: file,
                line: line
            )
            XCTAssertLessThan(
                abs(tonePicker.frame.minY - referenceToneFrame.minY),
                4,
                "Tone picker should stay vertically stable when intensity is disabled",
                file: file,
                line: line
            )
        }
        XCTAssertLessThan(
            abs(intensityPicker.frame.midY - tonePicker.frame.midY),
            18,
            "Disabled intensity picker should stay on the same row as the tone picker",
            file: file,
            line: line
        )
    }

    private func assertCustomToneFieldState(
        enabled: Bool,
        referenceFieldFrame: CGRect? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let toneField = waitForCustomToneField()

        XCTAssertTrue(toneField.exists, "Custom tone field should remain mounted", file: file, line: line)
        XCTAssertEqual(
            toneField.isEnabled,
            enabled,
            "Custom tone field should \(enabled ? "be enabled" : "stay disabled") in the current tone mode",
            file: file,
            line: line
        )

        if let referenceFieldFrame {
            XCTAssertLessThan(
                abs(toneField.frame.minX - referenceFieldFrame.minX),
                4,
                "Custom tone field should stay horizontally stable across tone changes",
                file: file,
                line: line
            )
            XCTAssertLessThan(
                abs(toneField.frame.minY - referenceFieldFrame.minY),
                4,
                "Custom tone field should stay vertically stable across tone changes",
                file: file,
                line: line
            )
            XCTAssertLessThan(
                abs(toneField.frame.height - referenceFieldFrame.height),
                4,
                "Custom tone field height should remain stable across tone changes",
                file: file,
                line: line
            )
        }
    }

    private func assertEmotionValue(
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let marker = waitForEmotionValue()
        let markerText = [marker.label, marker.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")

        XCTAssertTrue(
            markerText.contains(expected),
            "Emotion value should resolve to '\(expected)'",
            file: file,
            line: line
        )
    }

    private func openSpeakerPickerAndSelect(_ speakerLabel: String) -> XCUIElement {
        app.activate()
        waitForCustomVoiceSpeakerPicker().click()
        app.activate()

        let menuItem = app.menuItems[speakerLabel].firstMatch
        if menuItem.waitForExistence(timeout: 2) {
            return menuItem
        }

        let button = app.buttons[speakerLabel].firstMatch
        if button.waitForExistence(timeout: 2) {
            return button
        }

        XCTFail("Speaker menu item '\(speakerLabel)' should exist")
        return menuItem
    }

    private func selectedSpeakerValue() -> String? {
        let selectedSpeaker = app.descendants(matching: .any)
            .matching(identifier: "customVoice_selectedSpeaker")
            .firstMatch
        if selectedSpeaker.waitForExistence(timeout: 1) {
            let containerValue = selectedSpeaker.label.isEmpty ? selectedSpeaker.value as? String : selectedSpeaker.label
            if let containerValue, !containerValue.isEmpty {
                return containerValue
            }
        }

        let speakerPicker = waitForCustomVoiceSpeakerPicker(timeout: 5)
        return speakerPicker.label.isEmpty ? speakerPicker.value as? String : speakerPicker.label
    }

    private func toneMenuLabel(for identifier: String) -> String {
        switch identifier {
        case "delivery_tone_neutral":
            return "Normal tone"
        case "delivery_tone_custom":
            return "Custom"
        default:
            let rawValue = identifier.replacingOccurrences(of: "delivery_tone_", with: "")
            return rawValue.capitalized
        }
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
        _ = waitForElement("models_card_pro_custom")
    }
}
