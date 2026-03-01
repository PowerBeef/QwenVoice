import XCTest

final class DebugHierarchyTests: QwenVoiceUITestBase {
    override class var initialScreen: UITestScreen? { .customVoice }

    func testAppWindowAndDefaultScreen() {
        XCTAssertTrue(app.windows.firstMatch.exists, "App window should exist")
        _ = waitForScreen(.customVoice)
        _ = waitForBackendStatusElement(timeout: 5)
    }

    func testHistoryScreenIdentifiers() {
        ensureOnScreen(.history)
        _ = waitForScreen(.history)
    }
}
