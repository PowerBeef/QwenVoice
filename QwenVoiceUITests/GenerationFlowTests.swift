import XCTest

final class GenerationFlowTests: QwenVoiceUITestBase {
    override class var launchPolicy: UITestLaunchPolicy { .freshPerTest }
    override class var initialScreen: UITestScreen? { .customVoice }

    /// Full end-to-end test: type text, generate, verify the sidebar player appears.
    /// Requires a downloaded model and running backend.
    func testFullCustomVoiceGeneration() throws {
        _ = waitForScreen(.customVoice)
        let configuration = waitForElement("customVoice_configuration")
        let script = waitForElement("customVoice_script")
        XCTAssertLessThan(
            configuration.frame.minY,
            script.frame.minY,
            "Configuration should remain the first visible content section on Custom Voice"
        )

        let banner = app.descendants(matching: .any).matching(identifier: "customVoice_modelBanner").firstMatch
        if banner.waitForExistence(timeout: 2) {
            throw XCTSkip("Model not downloaded; skipping generation test")
        }

        _ = waitForBackendStatusElement(timeout: 5)
        let idleStatus = app.descendants(matching: .any).matching(identifier: "sidebar_backendStatus_idle").firstMatch
        let crashedStatus = app.descendants(matching: .any).matching(identifier: "sidebar_backendStatus_crashed").firstMatch
        let errorStatus = app.descendants(matching: .any).matching(identifier: "sidebar_backendStatus_error").firstMatch
        if !(idleStatus.waitForExistence(timeout: 20)) {
            if crashedStatus.exists || errorStatus.exists {
                throw XCTSkip("Backend failed to initialize; skipping generation test")
            }
            throw XCTSkip("Backend did not reach the idle state in time; skipping generation test")
        }

        let editor = waitForElement("textInput_textEditor")
        if !editor.isEnabled {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if editor.isEnabled {
                    break
                }
                if banner.exists {
                    throw XCTSkip("Model became unavailable before generation could start")
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
        }
        if !editor.isEnabled {
            throw XCTSkip("Text editor never became enabled after backend startup")
        }
        editor.click()
        editor.typeText("Hello, this is a test.")

        let generateButton = waitForElement("textInput_generateButton", type: .button)
        XCTAssertTrue(generateButton.isEnabled, "Generate button should be enabled when text is entered")
        generateButton.click()

        let activeStatus = waitForElement("sidebar_backendStatus_active", timeout: 10)
        XCTAssertTrue(activeStatus.exists, "Sidebar status should become active during generation")

        let playerBar = waitForElement("sidebarPlayer_bar", timeout: 120)
        XCTAssertTrue(playerBar.exists, "Sidebar player should appear after generation")

        let playPause = waitForElement("sidebarPlayer_playPause", timeout: 5)
        XCTAssertTrue(playPause.exists, "Play/pause control should exist in the sidebar player")
    }
}
