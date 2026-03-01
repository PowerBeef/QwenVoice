import XCTest

final class HistoryViewTests: QwenVoiceUITestBase {
    override class var initialScreen: UITestScreen? { .history }

    func testHistoryScreenAvailability() {
        _ = waitForScreen(.history)
    }

    func testHistorySearchAndStateElements() {
        _ = waitForScreen(.history)

        let emptyState = app.descendants(matching: .any).matching(identifier: "history_emptyState").firstMatch
        let hasRows = app.tables.firstMatch.exists || app.outlines.firstMatch.exists
        XCTAssertTrue(emptyState.exists || hasRows, "History should show either empty state or rows")
    }
}
