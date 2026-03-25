import XCTest

final class PreferencesViewTests: QwenVoiceUITestBase {
    override var initialScreen: String? { "preferences" }

    @MainActor
    func testPreferencesScreenLoads() {
        // Preferences opens in a separate Settings window
        let settingsReady = app.descendants(matching: .any)["settingsWindow_ready"]
        if settingsReady.waitForExistence(timeout: 5) {
            // Settings window opened
        }
        assertElementExists("screen_preferences")
    }

    @MainActor
    func testScreenshotCapture() {
        let settingsReady = app.descendants(matching: .any)["settingsWindow_ready"]
        _ = settingsReady.waitForExistence(timeout: 5)
        captureScreenshot(name: "screenshot_preferences_default")
    }
}
