import XCTest

final class SidebarNavigationTests: QwenVoiceUITestBase {
    override class var initialScreen: UITestScreen? { .customVoice }

    func testSidebarNavigationAcrossAllSections() {
        let screens: [UITestScreen] = [
            .customVoice, .voiceCloning, .history, .voices, .models, .preferences,
        ]

        for screen in screens {
            ensureOnScreen(screen)
            _ = waitForScreen(screen)
        }
    }

    func testSidebarStatusIndicatorsExist() {
        _ = waitForElement("sidebar_generationStatus", timeout: 5)
        _ = waitForBackendStatusElement(timeout: 5)
    }
}
