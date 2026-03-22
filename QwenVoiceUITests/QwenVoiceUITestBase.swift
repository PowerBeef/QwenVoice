import XCTest

class QwenVoiceUITestBase: XCTestCase {
    var app: XCUIApplication!

    /// Override in subclass to auto-navigate after launch.
    var initialScreen: String? { nil }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchArguments += ["--uitest", "--uitest-disable-animations", "--uitest-fast-idle"]
        if let screen = initialScreen {
            app.launchArguments += ["--uitest-screen=\(screen)"]
        }
        app.launchEnvironment["QWENVOICE_UI_TEST"] = "1"
        app.launchEnvironment["QWENVOICE_UI_TEST_BACKEND_MODE"] = "stub"
        app.launchEnvironment["QWENVOICE_UI_TEST_SETUP_SCENARIO"] = "success"
        app.launchEnvironment["QWENVOICE_UI_TEST_SETUP_DELAY_MS"] = "1"
        app.launch()
        waitForReadiness()
    }

    override func tearDown() {
        app?.terminate()
        sleep(1)
        app = nil
        super.tearDown()
    }

    // MARK: - Readiness

    func waitForReadiness(timeout: TimeInterval = 15) {
        // Phase 1: Wait for the app to be in the foreground
        let foreground = app.wait(for: .runningForeground, timeout: min(timeout, 10))
        guard foreground else {
            XCTFail("App did not reach runningForeground within 10s")
            return
        }

        // Phase 2: Wait for content readiness marker
        let readyMarker = app.descendants(matching: .any)["mainWindow_ready"]
        if readyMarker.waitForExistence(timeout: timeout) { return }

        // Fallback: check if setup view is visible (app launched but still setting up)
        let setupMarker = app.descendants(matching: .any)["setupView_visible"]
        if setupMarker.exists {
            // Setup is running — wait longer for ready state
            if readyMarker.waitForExistence(timeout: timeout) { return }
        }

        XCTFail("App did not become ready within \(timeout)s")
    }

    // MARK: - Navigation

    func navigateTo(_ sidebarID: String, expectScreen: String, timeout: TimeInterval = 5) {
        let row = app.descendants(matching: .any)[sidebarID]
        XCTAssertTrue(row.waitForExistence(timeout: 3), "Sidebar item \(sidebarID) not found")
        row.click()
        waitForScreen(expectScreen, timeout: timeout)
    }

    func waitForScreen(_ screenID: String, timeout: TimeInterval = 5) {
        let screen = app.descendants(matching: .any)[screenID]
        XCTAssertTrue(screen.waitForExistence(timeout: timeout), "Screen \(screenID) did not appear within \(timeout)s")
    }

    func activeScreenValue() -> String? {
        let marker = app.descendants(matching: .any)["mainWindow_activeScreen"]
        guard marker.exists else { return nil }
        return marker.value as? String
    }

    // MARK: - Screenshots

    func captureScreenshot(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let outputDir = ProcessInfo.processInfo.environment["QWENVOICE_UITEST_SCREENSHOT_DIR"]
            ?? NSTemporaryDirectory() + "QwenVoiceUITestScreenshots"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let path = (outputDir as NSString).appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Assertions

    func assertElementExists(_ identifier: String, type: XCUIElement.ElementType = .any, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line) {
        let element: XCUIElement
        if type == .any {
            element = app.descendants(matching: .any)[identifier]
        } else {
            element = app.descendants(matching: type)[identifier]
        }
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Element '\(identifier)' not found within \(timeout)s", file: file, line: line)
    }
}
