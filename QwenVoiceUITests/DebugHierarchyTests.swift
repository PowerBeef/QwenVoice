import XCTest

final class DebugHierarchyTests: QwenVoiceUITestBase {

    func testAppWindowExists() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists, "App window should exist")
    }

    func testCustomVoiceTitleVisible() {
        let title = app.staticTexts["customVoice_title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Custom Voice title should be visible on launch")
    }
}
