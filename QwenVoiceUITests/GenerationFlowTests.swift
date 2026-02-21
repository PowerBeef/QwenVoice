import XCTest

final class GenerationFlowTests: QwenVoiceUITestBase {

    /// Full end-to-end test: type text, generate, verify audio player appears.
    /// Requires a downloaded model and running backend — skips otherwise.
    func testFullCustomVoiceGeneration() throws {
        // Navigate to Custom Voice
        navigateToSidebar("customVoice")
        assertElementExists("customVoice_title")

        // Check if model is downloaded (banner absent = model present)
        let banner = app.descendants(matching: .any).matching(identifier: "customVoice_modelBanner").firstMatch
        if banner.waitForExistence(timeout: 3) {
            throw XCTSkip("Model not downloaded — skipping generation test")
        }

        // Check backend is ready
        let backendStatus = app.descendants(matching: .any).matching(identifier: "sidebar_backendStatus").firstMatch
        if backendStatus.waitForExistence(timeout: 5) {
            // Check if "Starting..." text is present
            let startingText = app.staticTexts["Starting..."]
            if startingText.exists {
                throw XCTSkip("Backend not ready — skipping generation test")
            }
        }

        // Type text
        let editor = app.descendants(matching: .any).matching(identifier: "textInput_textEditor").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("Hello, this is a test.")

        // Click generate
        let generateButton = app.buttons["textInput_generateButton"]
        XCTAssertTrue(generateButton.waitForExistence(timeout: 5))
        XCTAssertTrue(generateButton.isEnabled, "Generate button should be enabled when text is entered")
        generateButton.click()

        // Wait for audio player bar to appear (generation may take 30-60s)
        let playerBar = app.descendants(matching: .any).matching(identifier: "audioPlayer_bar").firstMatch
        XCTAssertTrue(playerBar.waitForExistence(timeout: 120), "Audio player bar should appear after generation")

        // Verify play/pause button exists
        let playPause = app.buttons["audioPlayer_playPause"]
        XCTAssertTrue(playPause.exists, "Play/pause button should exist in audio player")
    }
}
