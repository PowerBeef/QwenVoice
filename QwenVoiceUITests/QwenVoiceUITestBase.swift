import Foundation
import XCTest

private struct UITestStateSnapshot: Decodable {
    let activeScreen: String?
    let isReady: Bool?
    let interactiveReady: Bool?
    let launchPhase: String?
    let readinessBlocker: String?
    let environmentReady: Bool?
    let backendReady: Bool?
    let windowMounted: Bool?
    let hasVisibleMainWindow: Bool?
    let windowTitle: String?
    let sidebarStatusKind: String?
    let sidebarStatusLabel: String?

    var readinessSummary: String {
        [
            "launchPhase=\(launchPhase ?? "")",
            "readinessBlocker=\(readinessBlocker ?? "")",
            "environmentReady=\(environmentReady.map(String.init) ?? "nil")",
            "backendReady=\(backendReady.map(String.init) ?? "nil")",
            "windowMounted=\(windowMounted.map(String.init) ?? "nil")",
            "hasVisibleMainWindow=\(hasVisibleMainWindow.map(String.init) ?? "nil")",
            "activeScreen=\(activeScreen ?? "")",
            "windowTitle=\(windowTitle ?? "")",
            "sidebarStatusKind=\(sidebarStatusKind ?? "")",
            "sidebarStatusLabel=\(sidebarStatusLabel ?? "")",
        ].joined(separator: ", ")
    }
}

private final class UITestStateBox: @unchecked Sendable {
    var snapshot: UITestStateSnapshot?
}

class QwenVoiceUITestBase: XCTestCase {
    var app: XCUIApplication!
    private var fixtureRoot: String?
    private var fixtureShouldCleanup = false
    private var defaultsSuiteName: String?
    private let stateServerURL = URL(string: "http://127.0.0.1:19876/state")!

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

        let application = app!
        performOnMainActor(with: application) { app in
            app.launch()
        }
        if shouldWaitForInitialReadiness {
            waitForReadiness()
        }
    }

    override func tearDown() {
        if let application = app {
            performOnMainActor(with: application) { app in
                app.terminate()
            }
        }
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

        var application: XCUIApplication!
        MainActor.assumeIsolated {
            application = XCUIApplication()
        }
        let includesFastIdleLaunchArgument = includesFastIdleLaunchArgument
        let initialScreen = initialScreen
        let backendMode = uiTestBackendMode
        let setupScenario = uiTestSetupScenario
        let setupDelayMilliseconds = uiTestSetupDelayMilliseconds
        let defaultsSuiteName = defaultsSuiteName
        let fixtureRoot = fixtureRoot
        let extraEnvironment = additionalLaunchEnvironment(fixtureRoot: fixtureRoot)

        performOnMainActor(with: application) { app in
            app.launchArguments = [
                "-ApplePersistenceIgnoreState", "YES",
                "--uitest",
                "--uitest-disable-animations",
            ]
            if includesFastIdleLaunchArgument {
                app.launchArguments += ["--uitest-fast-idle"]
            }
            if let screen = initialScreen {
                app.launchArguments += ["--uitest-screen=\(screen)"]
            }

            app.launchEnvironment["QWENVOICE_UI_TEST"] = "1"
            app.launchEnvironment["QWENVOICE_UI_TEST_BACKEND_MODE"] = backendMode.rawValue
            app.launchEnvironment["QWENVOICE_UI_TEST_SETUP_SCENARIO"] = setupScenario
            app.launchEnvironment["QWENVOICE_UI_TEST_SETUP_DELAY_MS"] = setupDelayMilliseconds
            app.launchEnvironment["QWENVOICE_UI_TEST_DEFAULTS_SUITE"] = defaultsSuiteName
            app.launchEnvironment.removeValue(forKey: "QWENVOICE_UI_TEST_FIXTURE_ROOT")
            app.launchEnvironment.removeValue(forKey: "QWENVOICE_APP_SUPPORT_DIR")
            switch backendMode {
            case .stub:
                app.launchEnvironment["QWENVOICE_UI_TEST_FIXTURE_ROOT"] = fixtureRoot
            case .live:
                app.launchEnvironment["QWENVOICE_APP_SUPPORT_DIR"] = fixtureRoot
            }
            for (key, value) in extraEnvironment {
                app.launchEnvironment[key] = value
            }
        }

        app = application
    }

    // MARK: - Readiness

    func waitForReadiness(timeout: TimeInterval = 0) {
        let effectiveTimeout = timeout > 0 ? timeout : defaultReadinessTimeout
        // Phase 1: Wait for the app to be in the foreground
        let foreground = boolFromApplicationOnMainActor { application in
            application.wait(for: .runningForeground, timeout: min(effectiveTimeout, 10))
        }
        guard foreground else {
            XCTFail("App did not reach runningForeground within 10s")
            return
        }

        let deadline = Date().addingTimeInterval(effectiveTimeout)
        var lastSnapshot: UITestStateSnapshot?
        repeat {
            if let snapshot = fetchTestState() {
                lastSnapshot = snapshot
                if isReady(snapshot) {
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        let setupVisible = elementExists(identifier: "setupView_visible")
        let diagnostics = lastSnapshot?.readinessSummary ?? "state_server_unreachable"
        if setupVisible {
            XCTFail(
                "App remained in setup instead of becoming \(readinessDescription) within \(effectiveTimeout)s (\(diagnostics))"
            )
        } else {
            XCTFail(
                "App did not become \(readinessDescription) within \(effectiveTimeout)s (\(diagnostics))"
            )
        }
    }

    // MARK: - Navigation

    func navigateTo(_ sidebarID: String, expectScreen: String, timeout: TimeInterval = 5) {
        performWithApplicationOnMainActor { application in
            let row = application.descendants(matching: .any)[sidebarID]
            XCTAssertTrue(row.waitForExistence(timeout: 3), "Sidebar item \(sidebarID) not found")
            row.click()
        }
        waitForScreen(expectScreen, timeout: timeout)
    }

    func navigateToExpectingActiveScreen(_ sidebarID: String, expectScreen: String, timeout: TimeInterval = 5) {
        performWithApplicationOnMainActor { application in
            let row = application.descendants(matching: .any)[sidebarID]
            XCTAssertTrue(row.waitForExistence(timeout: 3), "Sidebar item \(sidebarID) not found")
            row.click()
        }
        waitForActiveScreen(expectScreen, timeout: timeout)
    }

    func waitForScreen(_ screenID: String, timeout: TimeInterval = 5) {
        performWithApplicationOnMainActor { application in
            let screen = application.descendants(matching: .any)[screenID]
            XCTAssertTrue(screen.waitForExistence(timeout: timeout), "Screen \(screenID) did not appear within \(timeout)s")
        }
    }

    func waitForActiveScreen(_ screenID: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSnapshot: UITestStateSnapshot?
        repeat {
            if let snapshot = fetchTestState() {
                lastSnapshot = snapshot
                if snapshot.activeScreen == screenID {
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline

        XCTFail(
            "Active screen \(lastSnapshot?.activeScreen ?? "nil") did not become \(screenID) within \(timeout)s (\(lastSnapshot?.readinessSummary ?? "state_server_unreachable"))",
            file: file,
            line: line
        )
    }

    func activeScreenValue() -> String? {
        fetchTestState()?.activeScreen
    }

    // MARK: - Screenshots

    func captureScreenshot(name: String) {
        MainActor.assumeIsolated {
            let screenshot = XCUIScreen.main.screenshot()
            let outputDir = ProcessInfo.processInfo.environment["QWENVOICE_UITEST_SCREENSHOT_DIR"]
                ?? NSTemporaryDirectory() + "QwenVoiceUITestScreenshots"
            let fm = FileManager.default
            try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
            let path = (outputDir as NSString).appendingPathComponent("\(name).png")
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Assertions

    func assertElementExists(_ identifier: String, type: XCUIElement.ElementType = .any, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line) {
        performWithApplicationOnMainActor { application in
            let element: XCUIElement
            if type == .any {
                element = application.descendants(matching: .any)[identifier]
            } else {
                element = application.descendants(matching: type)[identifier]
            }
            XCTAssertTrue(element.waitForExistence(timeout: timeout), "Element '\(identifier)' not found within \(timeout)s", file: file, line: line)
        }
    }

    func clickElement(_ identifier: String, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line) {
        performWithApplicationOnMainActor { application in
            let element = application.descendants(matching: .any)[identifier]
            XCTAssertTrue(element.waitForExistence(timeout: timeout), "Element '\(identifier)' not found within \(timeout)s", file: file, line: line)
            element.click()
        }
    }

    func assertElementEnabled(_ identifier: String, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line) {
        performWithApplicationOnMainActor { application in
            let element = application.descendants(matching: .any)[identifier]
            XCTAssertTrue(element.waitForExistence(timeout: timeout), "Element '\(identifier)' not found within \(timeout)s", file: file, line: line)
            let deadline = Date().addingTimeInterval(timeout)
            while !element.isEnabled, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertTrue(element.isEnabled, "Element '\(identifier)' was disabled", file: file, line: line)
        }
    }

    func typeInTextEditor(_ text: String, identifier: String = "textInput_textEditor", file: StaticString = #filePath, line: UInt = #line) {
        performWithApplicationOnMainActor { application in
            let textView = application.textViews.firstMatch
            if textView.waitForExistence(timeout: 3) {
                textView.click()
                textView.typeText(text)
                return
            }

            let element = application.descendants(matching: .any)[identifier]
            XCTAssertTrue(element.waitForExistence(timeout: 3), "Element '\(identifier)' not found within 3.0s", file: file, line: line)
            element.click()
            application.typeText(text)
        }
    }

    func typeInTextField(_ identifier: String, text: String, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line) {
        performWithApplicationOnMainActor { application in
            let field = application.descendants(matching: .any)[identifier]
            XCTAssertTrue(field.waitForExistence(timeout: timeout), "Field '\(identifier)' not found within \(timeout)s", file: file, line: line)
            field.click()
            field.typeText(text)
        }
    }

    func stringValue(for identifier: String, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line) -> String? {
        stringFromApplicationOnMainActor { application in
            let element = application.descendants(matching: .any)[identifier]
            XCTAssertTrue(element.waitForExistence(timeout: timeout), "Element '\(identifier)' not found within \(timeout)s", file: file, line: line)
            return Self.elementStringValue(element)
        }
    }

    func assertStringValue(_ expected: String, for identifier: String, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(stringValue(for: identifier, timeout: timeout, file: file, line: line), expected, file: file, line: line)
    }

    private var defaultReadinessTimeout: TimeInterval {
        uiTestBackendMode == .live ? 60 : 15
    }

    private var readinessDescription: String {
        uiTestBackendMode == .live ? "interactive-ready" : "ready"
    }

    private func fetchTestState(timeout: TimeInterval = 0.5) -> UITestStateSnapshot? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let semaphore = DispatchSemaphore(value: 0)
        let box = UITestStateBox()
        let task = session.dataTask(with: stateServerURL) { data, _, _ in
            defer { semaphore.signal() }
            guard let data else { return }
            box.snapshot = try? JSONDecoder().decode(UITestStateSnapshot.self, from: data)
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 0.1)
        return box.snapshot
    }

    private func isReady(_ snapshot: UITestStateSnapshot) -> Bool {
        switch uiTestBackendMode {
        case .stub:
            return snapshot.isReady == true
        case .live:
            return snapshot.interactiveReady == true
        }
    }

    private func elementExists(identifier: String) -> Bool {
        boolFromApplicationOnMainActor { application in
            application.descendants(matching: .any)[identifier].exists
        }
    }

    private func elementStringValue(identifier: String) -> String? {
        stringFromApplicationOnMainActor { application in
            let element = application.descendants(matching: .any)[identifier]
            return Self.elementStringValue(element)
        }
    }

    @MainActor
    private static func elementStringValue(_ element: XCUIElement) -> String? {
        guard element.exists else { return nil }
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label.isEmpty ? nil : element.label
    }

    private func performWithApplicationOnMainActor(_ body: @MainActor (XCUIApplication) -> Void) {
        performOnMainActor(with: app!, body)
    }

    private func boolFromApplicationOnMainActor(_ body: @MainActor (XCUIApplication) -> Bool) -> Bool {
        let application = app!
        return MainActor.assumeIsolated {
            body(application)
        }
    }

    private func stringFromApplicationOnMainActor(_ body: @MainActor (XCUIApplication) -> String?) -> String? {
        let application = app!
        return MainActor.assumeIsolated {
            body(application)
        }
    }

    private func performOnMainActor(with application: XCUIApplication, _ body: @MainActor (XCUIApplication) -> Void) {
        MainActor.assumeIsolated {
            body(application)
        }
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
