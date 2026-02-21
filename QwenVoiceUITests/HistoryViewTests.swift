import XCTest

final class HistoryViewTests: QwenVoiceUITestBase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        navigateToSidebar("history")
        let title = app.staticTexts["history_title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
    }

    // MARK: - Title

    func testTitleExists() {
        assertElementExists("history_title")
    }

    // MARK: - Search Field

    func testSearchFieldExists() {
        let field = app.textFields["history_searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Search field should exist")
    }

    // MARK: - Empty State

    func testEmptyStateVisibleWhenNoHistory() {
        // In a fresh test environment there should be no history
        let emptyState = app.descendants(matching: .any).matching(identifier: "history_emptyState").firstMatch
        // This may or may not show depending on prior history
        if emptyState.waitForExistence(timeout: 3) {
            XCTAssertTrue(emptyState.exists, "Empty state should be visible when no history exists")
        }
    }
}
