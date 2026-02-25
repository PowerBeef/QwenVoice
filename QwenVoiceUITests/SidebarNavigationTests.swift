import XCTest

final class SidebarNavigationTests: QwenVoiceUITestBase {

    // MARK: - Default State

    func testDefaultViewIsCustomVoice() {
        let title = app.staticTexts["customVoice_title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Custom Voice should be the default view")
    }

    // MARK: - Navigate to Each Sidebar Item

    func testNavigateToCustomVoice() {
        navigateToSidebar("customVoice")
        assertElementExists("customVoice_title")
    }

    func testNavigateToVoiceCloning() {
        navigateToSidebar("voiceCloning")
        assertElementExists("voiceCloning_title")
    }

    func testNavigateToHistory() {
        navigateToSidebar("history")
        assertElementExists("history_title")
    }

    func testNavigateToVoices() {
        navigateToSidebar("voices")
        assertElementExists("voices_title")
    }

    func testNavigateToModels() {
        navigateToSidebar("models")
        assertElementExists("models_title")
    }

    func testNavigateToPreferences() {
        navigateToSidebar("preferences")
        // Preferences uses Form — look for any element with our identifier
        let toggle = app.descendants(matching: .any).matching(identifier: "preferences_autoPlayToggle").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Preferences auto-play toggle should exist")
    }

    // MARK: - Round-trip Navigation

    func testRoundTripNavigation() {
        // Navigate away and back
        navigateToSidebar("models")
        assertElementExists("models_title")

        navigateToSidebar("customVoice")
        assertElementExists("customVoice_title")
    }

    // MARK: - Backend Status

    func testBackendStatusExists() {
        let status = app.otherElements["sidebar_backendStatus"]
        // The backend status HStack may take a moment to appear
        if !status.waitForExistence(timeout: 3) {
            // Try as a group or other element type
            let statusAlt = app.descendants(matching: .any).matching(identifier: "sidebar_backendStatus").firstMatch
            XCTAssertTrue(statusAlt.waitForExistence(timeout: 5), "Backend status indicator should exist in sidebar")
        }
    }
}
