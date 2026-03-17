import XCTest

final class VoicesViewTests: StubbedQwenVoiceUITestBase {
    override class var initialScreen: UITestScreen? { .voices }

    func testVoicesScreenAvailability() {
        _ = waitForScreen(.voices)
        _ = waitForMainWindowTitle("Saved Voices")
        _ = waitForElement("voices_enrollButton", type: .button)
    }

    func testVoicesControlsAndStates() {
        _ = waitForScreen(.voices)

        let emptyState = app.descendants(matching: .any).matching(identifier: "voices_emptyState").firstMatch
        let isLoading = app.staticTexts["Loading saved voices..."].exists
        let isStarting = app.staticTexts["Starting backend..."].exists
        let hasRows = app.tables.firstMatch.exists || app.outlines.firstMatch.exists

        XCTAssertTrue(
            emptyState.exists || isLoading || isStarting || hasRows,
            "Voices should show a visible state"
        )
    }
}
