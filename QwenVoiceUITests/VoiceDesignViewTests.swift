import XCTest

final class VoiceDesignViewTests: QwenVoiceUITestBase {
    override var initialScreen: String? { "voiceDesign" }
    override var uiTestBackendMode: UITestLaunchBackendMode { .stub }

    override func prepareFixtureRoot(_ root: String) {
        mirrorInstalledModels(in: root)
    }

    func testCoreLayoutElements() {
        waitForScreen("screen_voiceDesign")
        assertElementExists("textInput_textEditor")
        assertElementExists("textInput_generateButton")
    }

    func testDraftsPersistAcrossSidebarSwitches() {
        let brief = "Warm narrator"

        waitForScreen("screen_voiceDesign")
        typeInTextField("voiceDesign_voiceDescriptionField", text: brief)

        clickElement("sidebar_models")
        assertElementExists("models_title")

        clickElement("sidebar_voiceDesign")
        assertElementExists("voiceDesign_voiceDescriptionField")

        assertStringValue(brief, for: "voiceDesign_voiceDescriptionValue")
    }

    func testDesignedVoiceCanBeSavedToSavedVoices() {
        let brief = "Warm narrator"
        let script = "Save this designed voice for cloning."

        waitForScreen("screen_voiceDesign")
        typeInTextField("voiceDesign_voiceDescriptionField", text: brief)
        typeInTextEditor(script)

        clickElement("textInput_generateButton")
        assertElementExists("voiceDesign_saveVoiceButton", timeout: 10)

        clickElement("voiceDesign_saveVoiceButton")
        assertElementExists("voicesEnroll_nameField")
        assertStringValue("Warm_narrator", for: "voicesEnroll_nameField")
        XCTAssertTrue((stringValue(for: "voicesEnroll_audioPathField") ?? "").contains("VoiceDesign"))
        assertStringValue(script, for: "voicesEnroll_transcriptField")

        clickElement("voicesEnroll_confirmButton")

        let okButton = app.buttons["OK"]
        XCTAssertTrue(okButton.waitForExistence(timeout: 5), "Expected confirmation alert after saving designed voice")
        okButton.click()

        assertElementExists("voiceDesign_saveVoiceCompleted")

        navigateTo("sidebar_voices", expectScreen: "screen_voices")
        assertElementExists("voicesRow_Warm_narrator", timeout: 5)
    }

    @MainActor
    func testDesignHistoryRowsOfferSaveToSavedVoicesAction() {
        waitForScreen("screen_voiceDesign")
        typeInTextField("voiceDesign_voiceDescriptionField", text: "Radio host")
        typeInTextEditor("Keep this in history.")
        clickElement("textInput_generateButton")
        assertElementExists("voiceDesign_saveVoiceButton", timeout: 10)

        navigateTo("sidebar_history", expectScreen: "screen_history")

        let saveButton = app.buttons.matching(NSPredicate(format: "label == %@", "Save to Saved Voices")).firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Expected design history row to surface Save to Saved Voices")
    }

    func testScreenshotCapture() {
        waitForScreen("screen_voiceDesign")
        captureScreenshot(name: "screenshot_voiceDesign_default")
    }
}
