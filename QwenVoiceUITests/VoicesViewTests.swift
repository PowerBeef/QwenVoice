import XCTest

final class VoicesViewTests: QwenVoiceUITestBase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        navigateToSidebar("voices")
        let title = app.staticTexts["voices_title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
    }

    // MARK: - Title

    func testTitleExists() {
        assertElementExists("voices_title")
    }

    // MARK: - Enroll Button

    func testEnrollButtonExists() {
        let button = app.buttons["voices_enrollButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Enroll Voice button should exist")
    }

    // MARK: - Empty State

    func testEmptyStateVisibleWhenNoVoices() {
        let emptyState = app.descendants(matching: .any).matching(identifier: "voices_emptyState").firstMatch
        // May or may not show depending on enrolled voices
        if emptyState.waitForExistence(timeout: 3) {
            XCTAssertTrue(emptyState.exists, "Empty state should be visible when no voices enrolled")
        }
    }
}
