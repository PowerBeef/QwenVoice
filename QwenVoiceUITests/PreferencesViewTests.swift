import XCTest

final class PreferencesViewTests: QwenVoiceUITestBase {
    override class var initialScreen: UITestScreen? { .preferences }

    func testPreferencesScreenAvailability() {
        _ = waitForScreen(.preferences)
        _ = waitForElement("preferences_autoPlayToggle")
    }

    func testPreferencesControlsExist() {
        _ = waitForScreen(.preferences)
        _ = waitForElement("preferences_autoPlayToggle")
        _ = waitForElement("preferences_outputDirectory")
        _ = waitForElement("preferences_openFinderButton", type: .button)
        _ = waitForElement("preferences_resetEnvButton", type: .button)
    }
}
