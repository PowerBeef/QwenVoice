import XCTest

class QwenVoiceUITestBase: XCTestCase {
    var app: XCUIApplication!
    private var fixtureRoot: String?
    private var fixtureShouldCleanup = false
    private var defaultsSuiteName: String?

    /// Override in subclass to auto-navigate after launch.
    var initialScreen: String? { nil }
    var uiTestBackendMode: UITestLaunchBackendMode { .live }
    var uiTestDataRoot: UITestLaunchDataRoot { .fixture }
    var uiTestSetupScenario: String { "success" }
    var uiTestSetupDelayMilliseconds: String { "1" }
    var shouldWaitForInitialReadiness: Bool { true }
    var includesFastIdleLaunchArgument: Bool { true }
    nonisolated func additionalLaunchEnvironment(fixtureRoot: String?) -> [String: String] { [:] }

    nonisolated func prepareFixtureRoot(_ root: String) {}

    nonisolated func mirrorInstalledModels(in root: String) {
        let modelsRoot = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        let sourceRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("QwenVoice", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        let fileManager = FileManager.default

        guard let installedModels = try? fileManager.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for modelURL in installedModels {
            let destinationURL = modelsRoot.appendingPathComponent(modelURL.lastPathComponent, isDirectory: true)
            try? fileManager.removeItem(at: destinationURL)
            do {
                try fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: modelURL)
            } catch {
                try? fileManager.copyItem(at: modelURL, to: destinationURL)
            }
        }
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        prepareLaunchContextIfNeeded()
        configureAppForLaunch()

        app.launch()
        if shouldWaitForInitialReadiness {
            waitForReadiness()
        }
    }

    override func tearDown() {
        app?.terminate()
        sleep(1)
        app = nil
        if fixtureShouldCleanup, let fixtureRoot {
            StubFixtureSupport.cleanupFixtureRoot(fixtureRoot)
        }
        if let defaultsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        }
        fixtureRoot = nil
        fixtureShouldCleanup = false
        defaultsSuiteName = nil
        super.tearDown()
    }

    func configureAppForLaunch() {
        prepareLaunchContextIfNeeded()

        app = XCUIApplication()
        app.launchArguments = ["--uitest", "--uitest-disable-animations"]
        if includesFastIdleLaunchArgument {
            app.launchArguments += ["--uitest-fast-idle"]
        }
        if let screen = initialScreen {
            app.launchArguments += ["--uitest-screen=\(screen)"]
        }

        app.launchEnvironment["QWENVOICE_UI_TEST"] = "1"
        app.launchEnvironment["QWENVOICE_UI_TEST_BACKEND_MODE"] = uiTestBackendMode.rawValue
        app.launchEnvironment["QWENVOICE_UI_TEST_SETUP_SCENARIO"] = uiTestSetupScenario
        app.launchEnvironment["QWENVOICE_UI_TEST_SETUP_DELAY_MS"] = uiTestSetupDelayMilliseconds
        app.launchEnvironment["QWENVOICE_UI_TEST_DEFAULTS_SUITE"] = defaultsSuiteName
        app.launchEnvironment.removeValue(forKey: "QWENVOICE_UI_TEST_FIXTURE_ROOT")
        app.launchEnvironment.removeValue(forKey: "QWENVOICE_APP_SUPPORT_DIR")
        switch uiTestBackendMode {
        case .stub:
            app.launchEnvironment["QWENVOICE_UI_TEST_FIXTURE_ROOT"] = fixtureRoot
        case .live:
            app.launchEnvironment["QWENVOICE_APP_SUPPORT_DIR"] = fixtureRoot
        }
        for (key, value) in additionalLaunchEnvironment(fixtureRoot: fixtureRoot) {
            app.launchEnvironment[key] = value
        }
    }

    // MARK: - Readiness

    func waitForReadiness(timeout: TimeInterval = 0) {
        let effectiveTimeout = timeout > 0 ? timeout : defaultReadinessTimeout
        // Phase 1: Wait for the app to be in the foreground
        let foreground = app.wait(for: .runningForeground, timeout: min(effectiveTimeout, 10))
        guard foreground else {
            XCTFail("App did not reach runningForeground within 10s")
            return
        }

        let deadline = Date().addingTimeInterval(effectiveTimeout)
        repeat {
            if readinessMarkerValue() == "true" {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        let setupVisible = app.descendants(matching: .any)["setupView_visible"].exists
        if setupVisible {
            XCTFail("App remained in setup instead of becoming \(readinessDescription) within \(effectiveTimeout)s")
        } else {
            XCTFail("App did not become \(readinessDescription) within \(effectiveTimeout)s")
        }
    }

    // MARK: - Navigation

    func navigateTo(_ sidebarID: String, expectScreen: String, timeout: TimeInterval = 5) {
        let row = app.descendants(matching: .any)[sidebarID]
        XCTAssertTrue(row.waitForExistence(timeout: 3), "Sidebar item \(sidebarID) not found")
        row.click()
        waitForScreen(expectScreen, timeout: timeout)
    }

    func navigateToExpectingActiveScreen(_ sidebarID: String, expectScreen: String, timeout: TimeInterval = 5) {
        let row = app.descendants(matching: .any)[sidebarID]
        XCTAssertTrue(row.waitForExistence(timeout: 3), "Sidebar item \(sidebarID) not found")
        row.click()
        waitForActiveScreen(expectScreen, timeout: timeout)
    }

    func waitForScreen(_ screenID: String, timeout: TimeInterval = 5) {
        let screen = app.descendants(matching: .any)[screenID]
        XCTAssertTrue(screen.waitForExistence(timeout: timeout), "Screen \(screenID) did not appear within \(timeout)s")
    }

    func waitForActiveScreen(_ screenID: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if activeScreenValue() == screenID {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline

        XCTFail(
            "Active screen \(activeScreenValue() ?? "nil") did not become \(screenID) within \(timeout)s",
            file: file,
            line: line
        )
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

    @discardableResult
    func clickElement(_ identifier: String, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Element '\(identifier)' not found within \(timeout)s", file: file, line: line)
        element.click()
        return element
    }

    func typeInTextEditor(_ text: String, identifier: String = "textInput_textEditor", file: StaticString = #filePath, line: UInt = #line) {
        let textView = app.textViews.firstMatch
        if textView.waitForExistence(timeout: 3) {
            textView.click()
            textView.typeText(text)
            return
        }

        clickElement(identifier, file: file, line: line)
        app.typeText(text)
    }

    func typeInTextField(_ identifier: String, text: String, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "Field '\(identifier)' not found within \(timeout)s", file: file, line: line)
        field.click()
        field.typeText(text)
    }

    func stringValue(for identifier: String, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line) -> String? {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Element '\(identifier)' not found within \(timeout)s", file: file, line: line)
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        let label = element.label
        return label.isEmpty ? nil : label
    }

    func assertStringValue(_ expected: String, for identifier: String, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(stringValue(for: identifier, timeout: timeout, file: file, line: line), expected, file: file, line: line)
    }

    private var defaultReadinessTimeout: TimeInterval {
        uiTestBackendMode == .live ? 60 : 15
    }

    private var readinessMarkerIdentifier: String {
        uiTestBackendMode == .live ? "mainWindow_interactiveReady" : "mainWindow_ready"
    }

    private var readinessDescription: String {
        uiTestBackendMode == .live ? "interactive-ready" : "ready"
    }

    private func readinessMarkerValue() -> String? {
        let marker = app.descendants(matching: .any)[readinessMarkerIdentifier]
        guard marker.exists else { return nil }
        if let value = marker.value as? String, !value.isEmpty {
            return value
        }
        return marker.label.isEmpty ? nil : marker.label
    }

    private func prepareLaunchContextIfNeeded() {
        if fixtureRoot == nil {
            let context = StubFixtureSupport.createContext(
                backendMode: uiTestBackendMode,
                dataRoot: uiTestDataRoot
            )
            fixtureRoot = context.root
            fixtureShouldCleanup = context.shouldCleanup
        }
        if defaultsSuiteName == nil {
            defaultsSuiteName = "QwenVoiceUITests.\(UUID().uuidString)"
        }
        if let fixtureRoot {
            prepareFixtureRoot(fixtureRoot)
        }
    }
}
