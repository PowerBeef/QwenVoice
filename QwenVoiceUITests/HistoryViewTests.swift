import XCTest

final class HistoryViewTests: QwenVoiceUITestBase {
    override class var initialScreen: UITestScreen? { .history }

    func testHistoryScreenAvailability() {
        _ = waitForScreen(.history)
    }

    func testHistoryToolbarControlsExist() {
        _ = waitForScreen(.history)
        _ = waitForHistorySearchField(timeout: 5)
        _ = waitForHistorySortPicker(timeout: 5)
    }

    func testHistoryToolbarDoesNotOverlapContent() {
        _ = waitForScreen(.history)

        let searchField = waitForHistorySearchField(timeout: 5)
        let sortPicker = waitForHistorySortPicker(timeout: 5)
        let contentElement = waitForHistoryTopContentElement(timeout: 5)

        XCTAssertGreaterThan(contentElement.frame.minY, 0, "History content should appear below the title bar")
        XCTAssertLessThan(searchField.frame.maxY, contentElement.frame.minY, "Search field should remain above the History content region")
        XCTAssertLessThan(sortPicker.frame.maxY, contentElement.frame.minY, "Sort control should remain above the History content region")
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
        let sawNativeStateText = nativeHistoryStateTextExists()

        XCTAssertTrue(
            sawLoading || emptyState.exists || errorState.exists || hasRows || sawNativeStateText,
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
            if loadingState?.exists == true
                || emptyState.exists
                || errorState.exists
                || historyRowsExist()
                || nativeHistoryStateTextExists()
            {
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

    private func waitForHistoryTopContentElement(timeout: TimeInterval) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let loadingState = app.descendants(matching: .any).matching(identifier: "history_loadingState").firstMatch
            if loadingState.exists {
                return loadingState
            }

            let emptyState = app.descendants(matching: .any).matching(identifier: "history_emptyState").firstMatch
            if emptyState.exists {
                return emptyState
            }

            let errorState = app.descendants(matching: .any).matching(identifier: "history_errorState").firstMatch
            if errorState.exists {
                return errorState
            }

            let rows = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "historyRow_")
            )
            if rows.count > 0 {
                return rows.firstMatch
            }

            let labels = [
                app.staticTexts["Loading history..."].firstMatch,
                app.staticTexts["No generations yet"].firstMatch,
                app.staticTexts["No results found"].firstMatch,
                app.staticTexts["Couldn't load history"].firstMatch,
            ]
            if let label = labels.first(where: \.exists) {
                return label
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTFail("History should expose visible content within \(timeout)s")
        return app.descendants(matching: .any).matching(identifier: "screen_history").firstMatch
    }

    private func nativeHistoryStateTextExists() -> Bool {
        let labels = [
            "Loading history...",
            "No generations yet",
            "No results found",
            "Couldn't load history",
        ]

        return labels.contains { app.staticTexts[$0].exists }
    }
}
