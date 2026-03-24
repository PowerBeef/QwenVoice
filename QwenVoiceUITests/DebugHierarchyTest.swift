import XCTest

@MainActor
final class DebugHierarchyTest: XCTestCase {
    func testDumpHierarchy() {
        continueAfterFailure = true

        let app = XCUIApplication()
        app.launchArguments = ["--uitest", "--uitest-disable-animations", "--uitest-fast-idle"]
        app.launchEnvironment = [
            "QWENVOICE_UI_TEST": "1",
            "QWENVOICE_UI_TEST_BACKEND_MODE": "stub",
            "QWENVOICE_UI_TEST_SETUP_SCENARIO": "success",
            "QWENVOICE_UI_TEST_WINDOW_SIZE": "1280x820",
        ]
        app.launch()
        sleep(8)

        // Dump raw counts for every element type
        var info: [String] = []
        info.append("windows:\(app.windows.count)")
        info.append("staticTexts:\(app.staticTexts.count)")
        info.append("buttons:\(app.buttons.count)")
        info.append("groups:\(app.groups.count)")
        info.append("others:\(app.otherElements.count)")
        info.append("images:\(app.images.count)")
        info.append("textFields:\(app.textFields.count)")
        info.append("textViews:\(app.textViews.count)")
        info.append("all:\(app.descendants(matching: .any).count)")

        XCTFail("COUNTS: \(info.joined(separator: " "))")
        app.terminate()
    }
}
