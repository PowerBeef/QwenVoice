import XCTest

final class HistoryViewTests: QwenVoiceUITestBase {
    override class var initialScreen: UITestScreen? { .history }

    func testHistoryScreenAvailability() {
        _ = waitForScreen(.history)
    }

    func testHistorySearchAndStateElements() {
        _ = waitForScreen(.history)

        let loadingState = app.descendants(matching: .any).matching(identifier: "history_loadingState").firstMatch
        let emptyState = app.descendants(matching: .any).matching(identifier: "history_emptyState").firstMatch
        let initialHasRows = app.tables.firstMatch.exists || app.outlines.firstMatch.exists
        let sawLoading = loadingState.exists || loadingState.waitForExistence(timeout: 1)

        XCTAssertTrue(sawLoading || emptyState.exists || initialHasRows, "History should show a loading state, empty state, or rows")

        if sawLoading {
            _ = loadingState.waitForNonExistence(timeout: 5)
        }

        let settledHasRows = app.tables.firstMatch.exists || app.outlines.firstMatch.exists
        XCTAssertTrue(emptyState.exists || settledHasRows, "History should settle into either empty state or rows")
    }
}
