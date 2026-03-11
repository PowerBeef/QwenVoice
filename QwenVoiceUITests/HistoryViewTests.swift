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
        let errorState = app.descendants(matching: .any).matching(identifier: "history_errorState").firstMatch

        XCTAssertTrue(
            waitForHistoryState(
                loadingState: loadingState,
                emptyState: emptyState,
                errorState: errorState,
                timeout: 3
            ),
            "History should show a loading state, empty state, error state, or rows"
        )

        let sawLoading = loadingState.exists
        let hasRows = historyRowsExist()

        XCTAssertTrue(
            sawLoading || emptyState.exists || errorState.exists || hasRows,
            "History should show a loading state, empty state, error state, or rows"
        )

        if sawLoading {
            _ = loadingState.waitForNonExistence(timeout: 5)
        }

        XCTAssertTrue(
            waitForHistoryState(
                loadingState: nil,
                emptyState: emptyState,
                errorState: errorState,
                timeout: 3
            ),
            "History should settle into either empty state, error state, or rows"
        )
    }

    private func waitForHistoryState(
        loadingState: XCUIElement?,
        emptyState: XCUIElement,
        errorState: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if loadingState?.exists == true || emptyState.exists || errorState.exists || historyRowsExist() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func historyRowsExist() -> Bool {
        let query = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "historyRow_")
        )
        return query.count > 0
    }
}
