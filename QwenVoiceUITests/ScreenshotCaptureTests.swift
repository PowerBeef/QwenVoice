import XCTest

final class ScreenshotCaptureTests: QwenVoiceUITestBase {
    func testCaptureAllScreens() {
        let screens: [(sidebarID: String, screenID: String, name: String)] = [
            ("sidebar_customVoice", "screen_customVoice", "screenshot_customVoice_default"),
            ("sidebar_voiceDesign", "screen_voiceDesign", "screenshot_voiceDesign_default"),
            ("sidebar_voiceCloning", "screen_voiceCloning", "screenshot_voiceCloning_default"),
            ("sidebar_history", "screen_history", "screenshot_history_empty"),
            ("sidebar_voices", "screen_voices", "screenshot_voices_empty"),
            ("sidebar_models", "screen_models", "screenshot_models_default"),
        ]

        for (sidebarID, screenID, name) in screens {
            navigateTo(sidebarID, expectScreen: screenID)
            // Brief pause for rendering to settle
            usleep(500_000)
            captureScreenshot(name: name)
        }
    }
}
