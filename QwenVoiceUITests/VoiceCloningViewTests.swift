import XCTest

final class VoiceCloningViewTests: QwenVoiceUITestBase {
    override class var initialScreen: UITestScreen? { .voiceCloning }

    func testVoiceCloningScreenCoreLayout() {
        _ = waitForScreen(.voiceCloning)
        _ = waitForMainWindowTitle("Voice Cloning")
        let configuration = waitForElement("voiceCloning_configuration")
        let script = waitForElement("voiceCloning_script")
        XCTAssertLessThan(
            configuration.frame.minY,
            script.frame.minY,
            "Reference should be the first visible content section on Voice Cloning"
        )
        _ = waitForElement("voiceCloning_importButton")
        _ = waitForTranscriptInput()
        _ = waitForElement("delivery_tonePicker")
        _ = waitForElement("textInput_textEditor")
        _ = waitForElement("textInput_generateButton", type: .button)
        _ = waitForElement("textInput_batchButton", type: .button)
    }

    func testVoiceCloningInputControls() {
        _ = waitForScreen(.voiceCloning)

        let transcript = waitForTranscriptInput()
        transcript.click()
        transcript.typeText("Reference transcript")
        XCTAssertTrue((transcript.value as? String)?.contains("Reference") ?? false)

        let editor = waitForElement("textInput_textEditor")
        let generate = waitForElement("textInput_generateButton", type: .button)
        XCTAssertFalse(editor.isEnabled, "Text entry should remain disabled until reference audio is selected and the clone model is available")
        XCTAssertFalse(generate.isEnabled, "Generate should remain disabled until reference audio is selected and the clone model is available")
    }

    func testVoiceCloningDeliveryControlsUseInlineIntensityLayout() {
        _ = waitForScreen(.voiceCloning)

        let neutralTonePicker = waitForElement("delivery_tonePicker")
        let neutralToneFrame = neutralTonePicker.frame
        let neutralToneField = waitForCustomToneField()
        let neutralToneFieldFrame = neutralToneField.frame
        assertIntensityPickerIsDisabled(referenceToneFrame: neutralToneFrame)
        assertCustomToneFieldState(enabled: false, referenceFieldFrame: neutralToneFieldFrame)

        let happyTone = openTonePickerAndSelect("delivery_tone_happy")
        happyTone.click()
        assertIntensityPickerIsInline(referenceToneFrame: neutralToneFrame)
        assertCustomToneFieldState(enabled: false, referenceFieldFrame: neutralToneFieldFrame)

        let customTone = openTonePickerAndSelect("delivery_tone_custom")
        customTone.click()
        XCTAssertTrue(waitForCustomToneField().exists, "Custom tone field should remain visible below the inline picker row")
        let toneField = waitForCustomToneField()
        toneField.click()
        toneField.typeKey("a", modifierFlags: .command)
        toneField.typeText("Quiet and breathy")
        assertIntensityPickerIsDisabled(referenceToneFrame: neutralToneFrame)
        assertCustomToneFieldState(enabled: true, referenceFieldFrame: neutralToneFieldFrame)
        assertEmotionValue("Quiet and breathy")

        let happyAgain = openTonePickerAndSelect("delivery_tone_happy")
        happyAgain.click()
        assertIntensityPickerIsInline(referenceToneFrame: neutralToneFrame)
        assertCustomToneFieldState(enabled: false, referenceFieldFrame: neutralToneFieldFrame)

        let customAgain = openTonePickerAndSelect("delivery_tone_custom")
        customAgain.click()
        XCTAssertEqual(waitForCustomToneField().value as? String, "Quiet and breathy")
        assertIntensityPickerIsDisabled(referenceToneFrame: neutralToneFrame)
        assertCustomToneFieldState(enabled: true, referenceFieldFrame: neutralToneFieldFrame)
        assertEmotionValue("Quiet and breathy")
    }

    private func waitForTranscriptInput(timeout: TimeInterval = 5) -> XCUIElement {
        let identified = app.textFields["voiceCloning_transcriptInput"].firstMatch
        if identified.waitForExistence(timeout: timeout) {
            return identified
        }

        let labeled = app.textFields["Transcript"].firstMatch
        if labeled.waitForExistence(timeout: timeout) {
            return labeled
        }

        XCTFail("Voice Cloning transcript input should exist within \(timeout)s")
        return identified
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

    func testVoiceCloningMissingModelNavigation() {
        _ = waitForScreen(.voiceCloning)

        let banner = app.descendants(matching: .any).matching(identifier: "voiceCloning_modelBanner").firstMatch
        guard banner.waitForExistence(timeout: 2) else {
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "screen_voiceCloning").firstMatch.exists)
            return
        }

        let goToModels = waitForElement("voiceCloning_goToModels", type: .button)
        goToModels.click()
        _ = waitForScreen(.models)
        _ = waitForElement("models_card_pro_custom")
    }
}
