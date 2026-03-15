import XCTest

final class VoiceCloningViewTests: QwenVoiceUITestBase {
    override class var initialScreen: UITestScreen? { nil }
    override class var additionalLaunchEnvironment: [String: String] {
        ["QWENVOICE_UI_TEST_WINDOW_SIZE": "720x560"]
    }

    func testVoiceCloningScreenCoreLayout() {
        relaunchFreshApp(initialScreen: .voiceCloning)
        _ = waitForMainWindowTitle("Voice Cloning")
        _ = waitForElement("mainWindow_activeScreen")
        let activeScreenMarker = app.descendants(matching: .any)
            .matching(identifier: "mainWindow_activeScreen")
            .firstMatch
        XCTAssertTrue(
            activeScreenMarker.label.contains("screen_voiceCloning")
                || ((activeScreenMarker.value as? String)?.contains("screen_voiceCloning") == true),
            "Explicit Voice Cloning launch override should keep the Voice Cloning screen active"
        )
        let importButton = waitForElement("voiceCloning_importButton")
        _ = waitForTranscriptInput()
        _ = waitForElement("delivery_tonePicker")
        let editor = waitForElement("textInput_textEditor")
        XCTAssertLessThan(
            importButton.frame.minY,
            editor.frame.minY,
            "Reference controls should remain above the Script editor on Voice Cloning"
        )
        let generateButton = waitForElement("textInput_generateButton", type: .button)
        let batchButton = waitForElement("textInput_batchButton", type: .button)
        assertElementAboveFold(editor)
        assertElementAboveFold(generateButton)
        assertElementAboveFold(batchButton)
        XCTAssertGreaterThan(
            editor.frame.height,
            150,
            "Voice Cloning should let the script editor absorb spare vertical space"
        )
    }

    func testVoiceCloningInputControls() {
        relaunchFreshApp(initialScreen: .voiceCloning)
        _ = waitForScreen(.voiceCloning)

        let transcript = waitForTranscriptInput()
        transcript.click()
        transcript.typeText("Reference transcript")
        XCTAssertTrue(transcriptContains("Reference transcript"))

        let editor = waitForElement("textInput_textEditor")
        let generate = waitForElement("textInput_generateButton", type: .button)
        XCTAssertFalse(editor.isEnabled, "Text entry should remain disabled until reference audio is selected and the clone model is available")
        XCTAssertFalse(generate.isEnabled, "Generate should remain disabled until reference audio is selected and the clone model is available")
    }

    func testVoiceCloningDeliveryControlsUseInlineIntensityLayout() {
        relaunchFreshApp(initialScreen: .voiceCloning)
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

    private func transcriptContains(_ expected: String, timeout: TimeInterval = 2) -> Bool {
        let candidates: [XCUIElement] = [
            app.descendants(matching: .any).matching(identifier: "voiceCloning_transcriptInput").firstMatch,
            app.textFields["voiceCloning_transcriptInput"].firstMatch,
            app.textFields["Transcript"].firstMatch,
            app.descendants(matching: .any).matching(identifier: "voiceCloning_transcriptField").firstMatch,
        ]
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            for candidate in candidates where candidate.exists {
                let text = [candidate.value as? String, candidate.label]
                    .compactMap { $0 }
                    .joined(separator: " ")

                if text.contains(expected) {
                    return true
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        return false
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
        relaunchFreshApp(initialScreen: .voiceCloning)
        _ = waitForScreen(.voiceCloning)

        guard isSidebarItemDisabled(.voiceCloning) else {
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "screen_voiceCloning").firstMatch.exists)
            return
        }

        _ = waitForSidebarItemState(.voiceCloning, disabled: true, timeout: 2)
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "voiceCloning_modelBanner").firstMatch.exists,
            "Voice Cloning should not render an in-content model banner anymore"
        )
        XCTAssertFalse(
            app.buttons.matching(identifier: "voiceCloning_goToModels").firstMatch.exists,
            "Voice Cloning should no longer surface a titlebar warning action"
        )

        let editor = waitForElement("textInput_textEditor")
        XCTAssertFalse(editor.isEnabled, "The editor should remain disabled while the clone model is unavailable")

        ensureOnScreen(.models)
        _ = waitForScreen(.models)
    }
}
