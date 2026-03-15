import XCTest

final class SidebarNavigationTests: QwenVoiceUITestBase {
    override class var launchPolicy: UITestLaunchPolicy { .freshPerTest }
    override class var initialScreen: UITestScreen? { .customVoice }

    func testSidebarLaunchLayoutKeepsTopSectionVisible() {
        let generateHeader = waitForElement("sidebarSection_generate", timeout: 5)
        XCTAssertGreaterThan(generateHeader.frame.minY, 0, "Generate section header should render below the titlebar chrome")

        let customVoiceRow = waitForElement("sidebar_customVoice", timeout: 5)
        XCTAssertGreaterThan(customVoiceRow.frame.minY, generateHeader.frame.maxY, "First sidebar row should appear below the Generate section header")
        let hittableDeadline = Date().addingTimeInterval(2)
        while Date() < hittableDeadline, !customVoiceRow.isHittable {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(customVoiceRow.isHittable, "First sidebar row should be hittable on launch")
    }

    func testSidebarNavigationAcrossAllSections() {
        let screens: [UITestScreen] = [
            .customVoice, .voiceDesign, .voiceCloning, .history, .voices, .models,
        ]

        for screen in screens {
            ensureOnScreen(screen)
            _ = waitForScreen(screen)
            _ = waitForMainWindowTitle(expectedTitle(for: screen))
        }
    }

    func testSidebarStatusIndicatorsExist() {
        _ = waitForElement("sidebar_generationStatus", timeout: 5)
        _ = waitForBackendStatusElement(timeout: 5)
    }

    func testWindowToolbarChromeTracksActiveScreen() {
        ensureOnScreen(.voices)
        _ = waitForScreen(.voices)
        _ = waitForMainWindowTitle("Voices")

        let enrollButton = waitForElement("voices_enrollButton", type: .button, timeout: 5)
        XCTAssertTrue(enrollButton.exists, "Enroll Voice should appear while Voices is active")

        ensureOnScreen(.customVoice)
        _ = waitForScreen(.customVoice)
        _ = waitForMainWindowTitle("Custom Voice")
        XCTAssertTrue(
            enrollButton.waitForNonExistence(timeout: 5),
            "Enroll Voice should disappear when leaving Voices"
        )

        ensureOnScreen(.history)
        _ = waitForScreen(.history)
        _ = waitForMainWindowTitle("History")

        let searchField = waitForHistorySearchField(timeout: 5)
        let sortPicker = waitForHistorySortPicker(timeout: 5)
        XCTAssertTrue(searchField.exists, "History search should appear while History is active")
        XCTAssertTrue(sortPicker.exists, "History sort should appear while History is active")

        ensureOnScreen(.voiceDesign)
        _ = waitForScreen(.voiceDesign)
        _ = waitForMainWindowTitle("Voice Design")
        XCTAssertTrue(
            searchField.waitForNonExistence(timeout: 5),
            "History search should disappear when leaving History"
        )
        XCTAssertTrue(
            sortPicker.waitForNonExistence(timeout: 5),
            "History sort should disappear when leaving History"
        )
    }

    func testSidebarNavigationPreservesGenerationDraftState() {
        let defaultSpeaker = UITestContractManifest.current.defaultSpeaker
        let alternateSpeaker = UITestContractManifest.current.allSpeakers.first(where: { $0 != defaultSpeaker }) ?? defaultSpeaker

        let alternateSpeakerItem = openSpeakerPickerAndSelect(alternateSpeaker.capitalized)
        alternateSpeakerItem.click()
        XCTAssertTrue(selectedSpeakerValue()?.contains(alternateSpeaker.capitalized) ?? false)

        ensureOnScreen(.voiceDesign)
        _ = waitForScreen(.voiceDesign)
        _ = waitForMainWindowTitle("Voice Design")

        let voiceField = waitForElement("voiceDesign_voiceDescriptionField", timeout: 5)
        voiceField.click()
        app.activate()
        voiceField.typeText("A steady documentary narrator")
        let editor = waitForElement("textInput_textEditor", timeout: 5)
        editor.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        ensureOnScreen(.history)
        _ = waitForScreen(.history)
        _ = waitForMainWindowTitle("History")

        ensureOnScreen(.customVoice)
        _ = waitForScreen(.customVoice)
        _ = waitForMainWindowTitle("Custom Voice")
        XCTAssertTrue(selectedSpeakerValue()?.contains(alternateSpeaker.capitalized) ?? false)

        ensureOnScreen(.voiceDesign)
        _ = waitForScreen(.voiceDesign)
        _ = waitForMainWindowTitle("Voice Design")
        let persistedBrief = app.descendants(matching: .any)
            .matching(identifier: "voiceDesign_voiceDescriptionValue")
            .firstMatch
        let persistedLabel = if persistedBrief.waitForExistence(timeout: 2) {
            [persistedBrief.label, persistedBrief.value as? String]
                .compactMap { $0 }
                .joined(separator: " ")
        } else {
            ""
        }

        if !persistedLabel.contains("documentary") {
            let sameField = waitForElement("voiceDesign_voiceDescriptionField", timeout: 5)
            let fieldValue = [sameField.value as? String, sameField.label]
                .compactMap { $0 }
                .joined(separator: " ")
            XCTAssertTrue(fieldValue.contains("documentary"))
        }
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
        let selectedSpeaker = waitForElement("customVoice_selectedSpeaker", timeout: 5)
        return selectedSpeaker.label.isEmpty ? selectedSpeaker.value as? String : selectedSpeaker.label
    }

    private func expectedTitle(for screen: UITestScreen) -> String {
        switch screen {
        case .customVoice:
            return "Custom Voice"
        case .voiceDesign:
            return "Voice Design"
        case .voiceCloning:
            return "Voice Cloning"
        case .history:
            return "History"
        case .voices:
            return "Voices"
        case .models:
            return "Models"
        case .preferences:
            return "Preferences"
        }
    }
}
