import XCTest

final class PreferencesViewTests: QwenVoiceUITestBase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        navigateToSidebar("preferences")
        // Wait for preferences form to load — use broad query since Form elements
        // may not map to standard XCUIElement types
        let toggle = app.descendants(matching: .any).matching(identifier: "preferences_autoPlayToggle").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    }

    // MARK: - Auto-play Toggle

    func testAutoPlayToggleExists() {
        let toggle = app.descendants(matching: .any).matching(identifier: "preferences_autoPlayToggle").firstMatch
        XCTAssertTrue(toggle.exists, "Auto-play toggle should exist")
    }

    // MARK: - Output Directory

    func testOutputDirectoryFieldExists() {
        let field = app.descendants(matching: .any).matching(identifier: "preferences_outputDirectory").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Output directory field should exist")
    }

    // MARK: - Open in Finder Button

    func testOpenFinderButtonExists() {
        let button = app.descendants(matching: .any).matching(identifier: "preferences_openFinderButton").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Open in Finder button should exist")
    }
}
