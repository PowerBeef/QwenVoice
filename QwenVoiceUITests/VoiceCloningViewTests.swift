import XCTest

final class VoiceCloningViewTests: QwenVoiceUITestBase {
    override class var initialScreen: UITestScreen? { .voiceCloning }

    func testVoiceCloningScreenCoreLayout() {
        _ = waitForScreen(.voiceCloning)
        assertElementExists("voiceCloning_title")
        _ = waitForElement("voiceCloning_batchButton", type: .button)
        _ = waitForElement("voiceCloning_dropZone")
        _ = waitForElement("voiceCloning_transcriptField", type: .textField)
        _ = waitForElement("textInput_textEditor")
        _ = waitForElement("textInput_generateButton", type: .button)
    }

    func testVoiceCloningInputControls() {
        _ = waitForScreen(.voiceCloning)

        let transcript = waitForElement("voiceCloning_transcriptField", type: .textField)
        transcript.click()
        transcript.typeText("Reference transcript")
        XCTAssertTrue((transcript.value as? String)?.contains("Reference") ?? false)

        let editor = waitForElement("textInput_textEditor")
        let generate = waitForElement("textInput_generateButton", type: .button)
        XCTAssertFalse(editor.isEnabled, "Text entry should remain disabled until reference audio is selected and the clone model is available")
        XCTAssertFalse(generate.isEnabled, "Generate should remain disabled until reference audio is selected and the clone model is available")
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
        assertElementExists("models_title")
    }
}
