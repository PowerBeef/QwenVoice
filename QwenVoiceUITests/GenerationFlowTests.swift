import XCTest

final class GenerationFlowTests: QwenVoiceUITestBase {
    override class var launchPolicy: UITestLaunchPolicy { .freshPerTest }
    override class var initialScreen: UITestScreen? { .customVoice }

    /// Full end-to-end test: type text, generate, verify the sidebar player appears.
    /// Requires a downloaded model and running backend.
    func testFullCustomVoiceGeneration() throws {
        _ = waitForScreen(.customVoice)
        assertElementExists("customVoice_title")

        let banner = app.descendants(matching: .any).matching(identifier: "customVoice_modelBanner").firstMatch
        if banner.waitForExistence(timeout: 2) {
            throw XCTSkip("Model not downloaded; skipping generation test")
        }

        _ = waitForBackendStatusElement(timeout: 5)
        if app.staticTexts["Starting..."].exists {
            throw XCTSkip("Backend not ready; skipping generation test")
        }

        let editor = waitForElement("textInput_textEditor")
        editor.click()
        editor.typeText("Hello, this is a test.")

        let generateButton = waitForElement("textInput_generateButton", type: .button)
        XCTAssertTrue(generateButton.isEnabled, "Generate button should be enabled when text is entered")
        generateButton.click()

        let playerBar = waitForElement("sidebarPlayer_bar", timeout: 120)
        XCTAssertTrue(playerBar.exists, "Sidebar player should appear after generation")

        let playPause = waitForElement("sidebarPlayer_playPause", timeout: 5)
        XCTAssertTrue(playPause.exists, "Play/pause control should exist in the sidebar player")
    }
}
