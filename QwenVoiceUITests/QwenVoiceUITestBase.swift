import XCTest

enum UITestLaunchPolicy {
    case sharedPerClass
    case freshPerTest
}

enum UITestBackendMode {
    case live
    case stub
}

enum UITestStateIsolation {
    case sharedHostState
    case isolatedFixture
}

struct UITestLaunchProfile {
    let launchPolicy: UITestLaunchPolicy
    let initialScreen: UITestScreen?
    let additionalEnvironment: [String: String]
    let backendMode: UITestBackendMode
    let stateIsolation: UITestStateIsolation
}

struct UITestSharedLaunchSignature: Equatable {
    let initialScreenRawValue: String?
    let debugCapture: Bool
    let additionalEnvironment: [String: String]
    let stateIsolation: UITestStateIsolation
}

enum UITestScreen: String, CaseIterable {
    case customVoice
    case voiceDesign
    case voiceCloning
    case history
    case voices
    case models
    case preferences

    var rootIdentifier: String {
        "screen_\(rawValue)"
    }

    var sidebarIdentifier: String {
        "sidebar_\(rawValue)"
    }

    var commandShortcutKey: String? {
        switch self {
        case .customVoice:
            return "1"
        case .voiceDesign:
            return "2"
        case .voiceCloning:
            return "3"
        case .history:
            return "4"
        case .voices:
            return "5"
        case .models:
            return "6"
        case .preferences:
            return nil
        }
    }

    var visibilitySentinelIdentifier: String? {
        switch self {
        case .customVoice:
            return "customVoice_speakerPicker"
        case .voiceDesign:
            return "voiceDesign_voiceDescriptionField"
        case .voiceCloning:
            return "voiceCloning_importButton"
        case .history:
            return nil
        case .voices:
            return "voices_enrollButton"
        case .models:
            return "models_card_pro_custom"
        case .preferences:
            return "preferences_autoPlayToggle"
        }
    }

}

final class QwenVoiceUITestSession {
    static let shared = QwenVoiceUITestSession()

    private var sharedApp: XCUIApplication?
    private var sharedLaunchSignature: UITestSharedLaunchSignature?

    private init() { }

    func launchSharedApp(
        initialScreen: UITestScreen?,
        debugCapture: Bool,
        additionalEnvironment: [String: String] = [:],
        launchSignature: UITestSharedLaunchSignature
    ) -> XCUIApplication {
        if let sharedApp, sharedApp.state != .notRunning, sharedLaunchSignature == launchSignature {
            sharedApp.activate()
            return sharedApp
        }

        if let sharedApp, sharedApp.state != .notRunning {
            sharedApp.terminate()
        }

        let app = makeApplication(
            initialScreen: initialScreen,
            debugCapture: debugCapture,
            additionalEnvironment: additionalEnvironment
        )
        app.launch()
        sharedApp = app
        sharedLaunchSignature = launchSignature
        return app
    }

    func sharedApplication(
        initialScreen: UITestScreen?,
        debugCapture: Bool,
        additionalEnvironment: [String: String] = [:],
        launchSignature: UITestSharedLaunchSignature
    ) -> XCUIApplication {
        launchSharedApp(
            initialScreen: initialScreen,
            debugCapture: debugCapture,
            additionalEnvironment: additionalEnvironment,
            launchSignature: launchSignature
        )
    }

    func launchFreshApp(
        initialScreen: UITestScreen?,
        debugCapture: Bool,
        additionalEnvironment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = makeApplication(
            initialScreen: initialScreen,
            debugCapture: debugCapture,
            additionalEnvironment: additionalEnvironment
        )
        app.launch()
        return app
    }

    func terminateSharedApp() {
        guard let sharedApp else { return }
        if sharedApp.state != .notRunning {
            sharedApp.terminate()
        }
        self.sharedApp = nil
        self.sharedLaunchSignature = nil
    }

    private func makeApplication(
        initialScreen: UITestScreen?,
        debugCapture: Bool,
        additionalEnvironment: [String: String]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        var launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--uitest",
            "--uitest-disable-animations",
            "--uitest-fast-idle",
        ]
        if let initialScreen {
            launchArguments.append("--uitest-screen=\(initialScreen.rawValue)")
        }
        if debugCapture {
            launchArguments.append("--uitest-debug-capture")
        }
        app.launchArguments = launchArguments
        app.launchEnvironment = ["QWENVOICE_UI_TEST": "1"].merging(additionalEnvironment) { _, new in new }
        return app
    }
}

/// Base class for all QwenVoice UI tests.
/// Fresh launches are the default to prioritize UI automation stability.
class QwenVoiceUITestBase: XCTestCase {
    private enum EnvironmentKeys {
        static let appSupportDir = "QWENVOICE_APP_SUPPORT_DIR"
        static let defaultsSuite = "QWENVOICE_UI_TEST_DEFAULTS_SUITE"
    }

    private(set) var app: XCUIApplication!
    private var generatedIsolationRoot: URL?
    private var generatedDefaultsSuiteName: String?

    class var launchPolicy: UITestLaunchPolicy { .freshPerTest }
    class var initialScreen: UITestScreen? { nil }
    class var additionalLaunchEnvironment: [String: String] { [:] }
    class var backendMode: UITestBackendMode { .live }
    class var stateIsolation: UITestStateIsolation { .sharedHostState }
    class var launchProfile: UITestLaunchProfile {
        UITestLaunchProfile(
            launchPolicy: launchPolicy,
            initialScreen: initialScreen,
            additionalEnvironment: additionalLaunchEnvironment,
            backendMode: backendMode,
            stateIsolation: stateIsolation
        )
    }

    private var debugCaptureEnabled: Bool {
        let flag = ProcessInfo.processInfo.environment["QWENVOICE_DEBUG_ON_FAIL"] ?? ""
        return flag == "1" || flag == "true"
    }

    override class func setUp() {
        super.setUp()
    }

    override class func tearDown() {
        if launchProfile.launchPolicy == .sharedPerClass {
            QwenVoiceUITestSession.shared.terminateSharedApp()
        }
        super.tearDown()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        let profile = type(of: self).launchProfile
        let launchEnvironment = resolvedLaunchEnvironment()
        let launchSignature = sharedLaunchSignature(
            initialScreen: profile.initialScreen,
            additionalEnvironment: launchEnvironment,
            stateIsolation: profile.stateIsolation
        )

        switch profile.launchPolicy {
        case .sharedPerClass:
            app = QwenVoiceUITestSession.shared.sharedApplication(
                initialScreen: profile.initialScreen,
                debugCapture: debugCaptureEnabled,
                additionalEnvironment: launchEnvironment,
                launchSignature: launchSignature
            )
        case .freshPerTest:
            app = QwenVoiceUITestSession.shared.launchFreshApp(
                initialScreen: profile.initialScreen,
                debugCapture: debugCaptureEnabled,
                additionalEnvironment: launchEnvironment
            )
        }

        let didBecomeReady = waitForLaunchReadinessWithRecovery(
            initialScreen: profile.initialScreen,
            launchPolicy: profile.launchPolicy,
            launchEnvironment: launchEnvironment,
            launchSignature: launchSignature
        )
        XCTAssertTrue(didBecomeReady, "App should become ready for UI automation")

        dismissTransientUI()

        if let initialScreen = profile.initialScreen {
            resetToScreen(initialScreen)
        }
    }

    override func tearDownWithError() throws {
        attachFailureArtifactsIfNeeded()

        if type(of: self).launchProfile.launchPolicy == .freshPerTest {
            app.terminate()
        }

        cleanupGeneratedIsolationArtifacts()
        app = nil
    }

    // MARK: - Navigation Helpers

    func launchSharedApp(initialScreen: UITestScreen? = nil) {
        let launchEnvironment = resolvedLaunchEnvironment()
        app = QwenVoiceUITestSession.shared.launchSharedApp(
            initialScreen: initialScreen,
            debugCapture: debugCaptureEnabled,
            additionalEnvironment: launchEnvironment,
            launchSignature: sharedLaunchSignature(
                initialScreen: initialScreen,
                additionalEnvironment: launchEnvironment,
                stateIsolation: type(of: self).launchProfile.stateIsolation
            )
        )
    }

    func relaunchFreshApp(
        initialScreen: UITestScreen? = nil,
        additionalEnvironment: [String: String] = [:]
    ) {
        if let app, app.state != .notRunning {
            app.terminate()
        }

        let launchEnvironment = resolvedLaunchEnvironment(
            additionalEnvironment: additionalEnvironment
        )
        app = QwenVoiceUITestSession.shared.launchFreshApp(
            initialScreen: initialScreen,
            debugCapture: debugCaptureEnabled,
            additionalEnvironment: launchEnvironment
        )

        let didBecomeReady = waitForLaunchReadinessWithRecovery(
            initialScreen: initialScreen,
            launchPolicy: .freshPerTest,
            launchEnvironment: launchEnvironment,
            launchSignature: sharedLaunchSignature(
                initialScreen: initialScreen,
                additionalEnvironment: launchEnvironment,
                stateIsolation: type(of: self).launchProfile.stateIsolation
            )
        )
        XCTAssertTrue(didBecomeReady, "App should become ready after relaunch")
        dismissTransientUI()
    }

    func resolvedLaunchEnvironment(additionalEnvironment: [String: String] = [:]) -> [String: String] {
        var environment = type(of: self).launchProfile.additionalEnvironment
            .merging(additionalEnvironment) { _, new in new }

        if type(of: self).launchProfile.backendMode == .stub {
            environment["QWENVOICE_UI_TEST_BACKEND_MODE"] = "stub"
        }

        if type(of: self).launchProfile.stateIsolation == .isolatedFixture {
            let isolationDefaults = isolatedLaunchEnvironment()
            environment = isolationDefaults.merging(environment) { _, new in new }

            if environment[EnvironmentKeys.appSupportDir]?.isEmpty != false {
                environment[EnvironmentKeys.appSupportDir] = isolatedAppSupportDirectoryURL().path
            }

            if environment[EnvironmentKeys.defaultsSuite]?.isEmpty != false {
                environment[EnvironmentKeys.defaultsSuite] = isolatedDefaultsSuiteName()
            }
        }

        return environment
    }

    func isolatedLaunchEnvironment() -> [String: String] { [:] }

    func isolatedAppSupportDirectoryURL() -> URL {
        if let generatedIsolationRoot {
            return generatedIsolationRoot
        }

        if let customRoot = isolatedAppSupportDirectoryOverride() {
            generatedIsolationRoot = customRoot
            return customRoot
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QwenVoiceUITest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        generatedIsolationRoot = root
        return root
    }

    func isolatedDefaultsSuiteName() -> String {
        if let generatedDefaultsSuiteName {
            return generatedDefaultsSuiteName
        }

        if let customSuite = isolatedDefaultsSuiteOverride() {
            generatedDefaultsSuiteName = customSuite
            return customSuite
        }

        let suiteName = "QwenVoiceUITests.\(UUID().uuidString)"
        generatedDefaultsSuiteName = suiteName
        return suiteName
    }

    func isolatedAppSupportDirectoryOverride() -> URL? { nil }

    func isolatedDefaultsSuiteOverride() -> String? { nil }

    private func sharedLaunchSignature(
        initialScreen: UITestScreen?,
        additionalEnvironment: [String: String],
        stateIsolation: UITestStateIsolation
    ) -> UITestSharedLaunchSignature {
        UITestSharedLaunchSignature(
            initialScreenRawValue: initialScreen?.rawValue,
            debugCapture: debugCaptureEnabled,
            additionalEnvironment: additionalEnvironment,
            stateIsolation: stateIsolation
        )
    }

    private func waitForLaunchReadinessWithRecovery(
        initialScreen: UITestScreen?,
        launchPolicy: UITestLaunchPolicy,
        launchEnvironment: [String: String],
        launchSignature: UITestSharedLaunchSignature,
        timeout: TimeInterval = 10
    ) -> Bool {
        if waitForLaunchReadiness(initialScreen: initialScreen, timeout: timeout) {
            return true
        }

        guard launchPolicy == .sharedPerClass else {
            return false
        }

        QwenVoiceUITestSession.shared.terminateSharedApp()
        app = QwenVoiceUITestSession.shared.launchSharedApp(
            initialScreen: initialScreen,
            debugCapture: debugCaptureEnabled,
            additionalEnvironment: launchEnvironment,
            launchSignature: launchSignature
        )

        return waitForLaunchReadiness(initialScreen: initialScreen, timeout: timeout)
    }

    private func waitForLaunchReadiness(
        initialScreen: UITestScreen?,
        timeout: TimeInterval
    ) -> Bool {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: timeout) else {
            return false
        }

        if initialScreen == .preferences {
            return waitForSettingsWindowReadiness(timeout: timeout)
        }

        return waitForMainWindowReadiness(expectedScreen: initialScreen, timeout: timeout)
    }

    private func waitForMainWindowReadiness(
        expectedScreen: UITestScreen?,
        timeout: TimeInterval
    ) -> Bool {
        let readyMarker = app.descendants(matching: .any).matching(identifier: "mainWindow_ready").firstMatch
        guard readyMarker.waitForExistence(timeout: timeout) else {
            return false
        }

        guard let expectedScreen else {
            return true
        }

        return waitUntilScreenVisible(expectedScreen, timeout: timeout)
    }

    private func waitForSettingsWindowReadiness(timeout: TimeInterval) -> Bool {
        let readyMarker = app.descendants(matching: .any).matching(identifier: "settingsWindow_ready").firstMatch
        if readyMarker.waitForExistence(timeout: timeout) {
            return true
        }

        return waitUntilScreenVisible(.preferences, timeout: timeout, allowSettingsRetry: true)
    }

    @discardableResult
    private func waitUntilScreenVisible(
        _ screen: UITestScreen,
        timeout: TimeInterval,
        allowSettingsRetry: Bool = false
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSettingsOpenAttempt: Date?

        while Date() < deadline {
            if isScreenVisible(screen) {
                return true
            }

            if allowSettingsRetry && screen == .preferences {
                let shouldRetryOpen = lastSettingsOpenAttempt.map { Date().timeIntervalSince($0) > 1 } ?? true
                if shouldRetryOpen {
                    openSettingsWindow()
                    lastSettingsOpenAttempt = Date()
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        return isScreenVisible(screen)
    }

    func waitForScreen(_ screen: UITestScreen, timeout: TimeInterval = 5) -> XCUIElement {
        let element = screenElement(for: screen)
        if waitUntilScreenVisible(screen, timeout: timeout, allowSettingsRetry: screen == .preferences) {
            return element
        }

        XCTAssertTrue(
            isScreenVisible(screen),
            "Screen root '\(screen.rootIdentifier)' should be visible within \(timeout)s"
        )
        return element
    }

    func ensureOnScreen(_ screen: UITestScreen, timeout: TimeInterval = 5) {
        if isScreenVisible(screen) {
            return
        }

        if screen == .preferences {
            openSettingsWindow()
            _ = waitForScreen(screen, timeout: timeout)
            return
        }

        if isSidebarItemDisabled(screen) {
            XCTFail("Sidebar item '\(screen.sidebarIdentifier)' is disabled and should not be selected")
            return
        }

        let sidebarItem = app.descendants(matching: .any).matching(identifier: screen.sidebarIdentifier).firstMatch
        if sidebarItem.waitForExistence(timeout: 3) {
            activateSidebarItem(sidebarItem, identifier: screen.sidebarIdentifier)
        } else if let shortcutKey = screen.commandShortcutKey {
            app.activate()
            app.typeKey(shortcutKey, modifierFlags: .command)
        } else {
            XCTFail("Sidebar item '\(screen.sidebarIdentifier)' should exist")
        }
        _ = waitForScreen(screen, timeout: timeout)
    }

    func resetToScreen(_ screen: UITestScreen, timeout: TimeInterval = 5) {
        if isScreenVisible(screen) {
            return
        }

        if screen == .preferences {
            openSettingsWindow()
            _ = waitForScreen(screen, timeout: timeout)
            return
        }

        ensureOnScreen(screen, timeout: timeout)
    }

    /// Backward-compatible string navigation helper.
    func navigateToSidebar(_ item: String) {
        guard let screen = UITestScreen(rawValue: item) else {
            XCTFail("Unknown sidebar item '\(item)'")
            return
        }
        ensureOnScreen(screen)
    }

    func navigateToSidebar(_ screen: UITestScreen) {
        ensureOnScreen(screen)
    }

    private func screenElement(for screen: UITestScreen) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: screen.rootIdentifier).firstMatch
    }

    private func isScreenVisible(_ element: XCUIElement) -> Bool {
        element.exists
    }

    private func isScreenVisible(_ screen: UITestScreen) -> Bool {
        if screen == .preferences {
            return isSettingsScreenVisible(screen)
        }

        return isMainWindowScreenVisible(screen)
    }

    private func isMainWindowScreenVisible(_ screen: UITestScreen) -> Bool {
        guard activeMainWindowScreenIdentifier() == screen.rootIdentifier else {
            return false
        }

        if isScreenVisible(screenElement(for: screen)) {
            return true
        }

        guard let sentinelIdentifier = screen.visibilitySentinelIdentifier else {
            return false
        }

        let sentinel = app.descendants(matching: .any).matching(identifier: sentinelIdentifier).firstMatch
        return sentinel.exists
    }

    private func isSettingsScreenVisible(_ screen: UITestScreen) -> Bool {
        if isScreenVisible(screenElement(for: screen)) {
            return true
        }

        guard let sentinelIdentifier = screen.visibilitySentinelIdentifier else {
            return false
        }

        let sentinel = app.descendants(matching: .any).matching(identifier: sentinelIdentifier).firstMatch
        return sentinel.exists
    }

    private func activeMainWindowScreenIdentifier() -> String? {
        let marker = app.descendants(matching: .any).matching(identifier: "mainWindow_activeScreen").firstMatch
        guard marker.exists || marker.waitForExistence(timeout: 0.2) else {
            return nil
        }

        let markerText = [marker.label, marker.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")

        return UITestScreen.allCases
            .map(\.rootIdentifier)
            .first(where: { markerText.contains($0) })
    }

    func waitForDisabledSidebarItems(
        _ screens: [UITestScreen],
        timeout: TimeInterval = 5
    ) -> XCUIElement {
        let marker = app.descendants(matching: .any).matching(identifier: "mainWindow_disabledSidebarItems").firstMatch
        let expectedIdentifiers = Set(screens.map(\.sidebarIdentifier))
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if marker.waitForExistence(timeout: 0.2) {
                if currentDisabledSidebarIdentifiers() == expectedIdentifiers {
                    return marker
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTFail(
            "Disabled sidebar marker should resolve to \(expectedIdentifiers.sorted()) within \(timeout)s, found \(currentDisabledSidebarIdentifiers().sorted())"
        )
        return marker
    }

    func waitForSidebarItemState(
        _ screen: UITestScreen,
        disabled: Bool,
        timeout: TimeInterval = 5
    ) -> XCUIElement {
        let sidebarItem = app.descendants(matching: .any).matching(identifier: screen.sidebarIdentifier).firstMatch
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if sidebarItem.waitForExistence(timeout: 0.2), isSidebarItemDisabled(screen) == disabled {
                return sidebarItem
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTFail("Sidebar item '\(screen.sidebarIdentifier)' should resolve to disabled=\(disabled) within \(timeout)s")
        return sidebarItem
    }

    func waitForBackendStatusElement(timeout: TimeInterval = 5) -> XCUIElement {
        let identifiers = [
            "sidebar_backendStatus",
            "sidebar_backendStatus_idle",
            "sidebar_backendStatus_starting",
            "sidebar_backendStatus_active",
            "sidebar_backendStatus_error",
            "sidebar_backendStatus_crashed",
        ]

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for identifier in identifiers {
                let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
                if element.exists {
                    return element
                }
            }
            usleep(250_000)
        }

        XCTFail("Backend status indicator should exist")
        return app.descendants(matching: .any).matching(identifier: identifiers[0]).firstMatch
    }

    func waitForMainWindowTitle(_ title: String, timeout: TimeInterval = 5) -> XCUIElement {
        let marker = app.descendants(matching: .any).matching(identifier: "mainWindow_activeTitle").firstMatch
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if marker.waitForExistence(timeout: 0.2) {
                let markerText = [marker.label, marker.value as? String]
                    .compactMap { $0 }
                    .joined(separator: " ")

                if markerText.contains(title) {
                    return marker
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        let markerText = [marker.label, marker.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTFail("Main window title should resolve to '\(title)' within \(timeout)s, found '\(markerText)'")
        return marker
    }

    func isSidebarItemDisabled(_ screen: UITestScreen) -> Bool {
        currentDisabledSidebarIdentifiers().contains(screen.sidebarIdentifier)
    }

    private func currentDisabledSidebarIdentifiers() -> Set<String> {
        let marker = app.descendants(matching: .any).matching(identifier: "mainWindow_disabledSidebarItems").firstMatch
        guard marker.exists || marker.waitForExistence(timeout: 0.2) else {
            return []
        }

        let markerText = (marker.value as? String) ?? marker.label
        let trimmed = markerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "none" else {
            return []
        }

        return Set(
            trimmed
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    func waitForBackendIdle(timeout: TimeInterval = 10) -> XCUIElement {
        let idle = app.descendants(matching: .any).matching(identifier: "sidebar_backendStatus_idle").firstMatch
        XCTAssertTrue(
            idle.waitForExistence(timeout: timeout),
            "Backend should reach the idle state within \(timeout)s"
        )
        return idle
    }

    func waitForHistorySearchField(timeout: TimeInterval = 5) -> XCUIElement {
        let identifiedField = app.descendants(matching: .any).matching(identifier: "history_searchField").firstMatch
        if identifiedField.waitForExistence(timeout: timeout) {
            return identifiedField
        }

        let identifiedTextField = app.textFields.matching(identifier: "history_searchField").firstMatch
        if identifiedTextField.waitForExistence(timeout: timeout) {
            return identifiedTextField
        }

        let placeholderField = app.searchFields["Search history"].firstMatch
        if placeholderField.waitForExistence(timeout: timeout) {
            return placeholderField
        }

        let genericSearchField = app.searchFields.firstMatch
        if genericSearchField.waitForExistence(timeout: timeout) {
            return genericSearchField
        }

        let fallbackField = app.textFields["Search history"].firstMatch
        if fallbackField.waitForExistence(timeout: timeout) {
            return fallbackField
        }

        let genericToolbarTextField = app.textFields.firstMatch
        XCTAssertTrue(
            genericToolbarTextField.waitForExistence(timeout: timeout),
            "History search field should exist within \(timeout)s"
        )
        return genericToolbarTextField
    }

    func waitForHistorySortPicker(timeout: TimeInterval = 5) -> XCUIElement {
        let identifiedPicker = app.descendants(matching: .any).matching(identifier: "history_sortPicker").firstMatch
        if identifiedPicker.waitForExistence(timeout: timeout) {
            return identifiedPicker
        }

        let identifiedMenuButton = app.menuButtons.matching(identifier: "history_sortPicker").firstMatch
        if identifiedMenuButton.waitForExistence(timeout: timeout) {
            return identifiedMenuButton
        }

        let toolbarPopup = app.popUpButtons.matching(identifier: "history_toolbar").firstMatch
        if toolbarPopup.waitForExistence(timeout: timeout) {
            return toolbarPopup
        }

        let labeledToolbarPopup = app.popUpButtons.matching(
            NSPredicate(format: "identifier == %@ AND label CONTAINS[c] %@", "history_toolbar", "Sort history")
        ).firstMatch
        if labeledToolbarPopup.waitForExistence(timeout: timeout) {
            return labeledToolbarPopup
        }

        let labeledPopup = app.popUpButtons["Sort history"].firstMatch
        if labeledPopup.waitForExistence(timeout: timeout) {
            return labeledPopup
        }

        let labeledMenuButton = app.menuButtons["Sort history"].firstMatch
        if labeledMenuButton.waitForExistence(timeout: timeout) {
            return labeledMenuButton
        }

        let labeledButton = app.buttons["Sort history"].firstMatch
        if labeledButton.waitForExistence(timeout: timeout) {
            return labeledButton
        }

        let sortButton = app.buttons["Sort"].firstMatch
        if sortButton.waitForExistence(timeout: timeout) {
            return sortButton
        }

        let sortMenuButton = app.menuButtons["Sort"].firstMatch
        if sortMenuButton.waitForExistence(timeout: timeout) {
            return sortMenuButton
        }

        let currentValueButton = app.buttons["Newest"].firstMatch
        if currentValueButton.waitForExistence(timeout: timeout) {
            return currentValueButton
        }

        let currentValueMenuButton = app.menuButtons["Newest"].firstMatch
        if currentValueMenuButton.waitForExistence(timeout: timeout) {
            return currentValueMenuButton
        }

        let toolbar = app.descendants(matching: .any).matching(identifier: "history_toolbar").firstMatch
        if toolbar.waitForExistence(timeout: timeout) {
            let toolbarButton = toolbar.buttons.firstMatch
            if toolbarButton.waitForExistence(timeout: timeout) {
                return toolbarButton
            }

            let toolbarMenuButton = toolbar.menuButtons.firstMatch
            if toolbarMenuButton.waitForExistence(timeout: timeout) {
                return toolbarMenuButton
            }

            let toolbarPopup = toolbar.popUpButtons.firstMatch
            XCTAssertTrue(
                toolbarPopup.waitForExistence(timeout: timeout),
                "History sort picker should exist within \(timeout)s"
            )
            return toolbarPopup
        }

        XCTFail("History sort picker should exist within \(timeout)s")
        return identifiedPicker
    }

    private func openSettingsWindow() {
        app.activate()
        app.typeKey(",", modifierFlags: .command)
    }

    private func cleanupGeneratedIsolationArtifacts() {
        if let generatedIsolationRoot {
            try? FileManager.default.removeItem(at: generatedIsolationRoot)
            self.generatedIsolationRoot = nil
        }

        if let generatedDefaultsSuiteName {
            UserDefaults(suiteName: generatedDefaultsSuiteName)?.removePersistentDomain(forName: generatedDefaultsSuiteName)
            self.generatedDefaultsSuiteName = nil
        }
    }

    func waitForElement(
        _ identifier: String,
        type: XCUIElement.ElementType = .any,
        timeout: TimeInterval = 5
    ) -> XCUIElement {
        let element = app.descendants(matching: type).matching(identifier: identifier).firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Element '\(identifier)' should exist within \(timeout)s"
        )
        return element
    }

    func waitForElementToBecomeEnabled(
        _ identifier: String,
        type: XCUIElement.ElementType = .any,
        timeout: TimeInterval = 5
    ) -> XCUIElement {
        let element = waitForElement(identifier, type: type, timeout: timeout)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isEnabled {
                return element
            }
            usleep(200_000)
        }
        XCTFail("Element '\(identifier)' should become enabled within \(timeout)s")
        return element
    }

    func waitForCustomVoiceSpeakerPicker(timeout: TimeInterval = 5) -> XCUIElement {
        let identified = app.descendants(matching: .any)
            .matching(identifier: "customVoice_speakerPicker")
            .firstMatch
        if identified.waitForExistence(timeout: min(timeout, 1.5)) {
            return identified
        }

        let voiceSetup = app.descendants(matching: .any)
            .matching(identifier: "customVoice_voiceSetup")
            .firstMatch
        if voiceSetup.waitForExistence(timeout: timeout) {
            let containedPopup = voiceSetup.descendants(matching: .popUpButton).firstMatch
            if containedPopup.waitForExistence(timeout: 1) {
                return containedPopup
            }
        }

        let labeledPopup = app.popUpButtons["Speaker"].firstMatch
        if labeledPopup.waitForExistence(timeout: timeout) {
            return labeledPopup
        }

        let firstPopup = app.popUpButtons.firstMatch
        if firstPopup.waitForExistence(timeout: timeout) {
            return firstPopup
        }

        XCTFail("Custom Voice speaker picker should exist within \(timeout)s")
        return identified
    }

    func activateSidebarItem(_ element: XCUIElement, identifier: String) {
        let targetScreen = UITestScreen(rawValue: identifier.replacingOccurrences(of: "sidebar_", with: ""))

        if element.isHittable {
            element.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if let targetScreen {
                if isScreenVisible(targetScreen) {
                    return
                }
            } else {
                return
            }
        }

        if let targetScreen,
           let currentScreen = visibleSidebarScreen(),
           let targetIndex = orderedSidebarScreens.firstIndex(of: targetScreen),
           let currentIndex = orderedSidebarScreens.firstIndex(of: currentScreen) {
            let outline = app.outlines.firstMatch
            if outline.exists {
                outline.click()

                let distance = targetIndex - currentIndex
                let key: XCUIKeyboardKey = distance >= 0 ? .downArrow : .upArrow
                for _ in 0..<abs(distance) {
                    app.typeKey(key, modifierFlags: [])
                }

                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                if isScreenVisible(targetScreen) {
                    return
                }
            }

            if let shortcutKey = targetScreen.commandShortcutKey {
                app.typeKey(shortcutKey, modifierFlags: .command)
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                if isScreenVisible(targetScreen) {
                    return
                }
            }
        }

        let outline = app.outlines.firstMatch
        if outline.exists {
            outline.click()
            app.typeKey(.home, modifierFlags: [])
            app.typeKey(.space, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        if element.isHittable {
            element.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if let targetScreen {
                if isScreenVisible(targetScreen) {
                    return
                }
            } else {
                return
            }
        }

        let fallbackCoordinate = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        fallbackCoordinate.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        if let targetScreen,
           !isScreenVisible(targetScreen),
           let shortcutKey = targetScreen.commandShortcutKey {
            app.typeKey(shortcutKey, modifierFlags: .command)
        }
    }

    private var orderedSidebarScreens: [UITestScreen] {
        [.customVoice, .voiceDesign, .voiceCloning, .history, .voices, .models]
    }

    private func visibleSidebarScreen() -> UITestScreen? {
        guard let identifier = activeMainWindowScreenIdentifier() else {
            return nil
        }

        return orderedSidebarScreens.first(where: { $0.rootIdentifier == identifier })
    }

    func revealElementIfNeeded(_ element: XCUIElement, maxScrolls: Int = 4) {
        guard !element.isHittable else { return }

        let scrollView = app.scrollViews.firstMatch
        guard scrollView.exists else { return }

        for _ in 0..<maxScrolls where !element.isHittable {
            scrollView.swipeUp()
        }
    }

    func assertElementExists(_ identifier: String, timeout: TimeInterval = 5) {
        _ = waitForElement(identifier, timeout: timeout)
    }

    func assertElementAboveFold(
        _ element: XCUIElement,
        bottomInset: CGFloat = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "App window should exist", file: file, line: line)
        XCTAssertTrue(element.exists, "Element should exist before verifying above-the-fold layout", file: file, line: line)
        XCTAssertGreaterThan(
            element.frame.maxY,
            element.frame.minY,
            "Element frame should be non-empty",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            element.frame.maxY,
            window.frame.maxY - bottomInset,
            "Element should be visible without scrolling at the active window size",
            file: file,
            line: line
        )
    }

    func dismissTransientUI() {
        let cancelButtons = ["Cancel", "Close", "Done"]
        let alerts = app.alerts

        if alerts.firstMatch.exists {
            for label in cancelButtons {
                let button = alerts.buttons[label]
                if button.exists {
                    button.click()
                    return
                }
            }
        }

        let sheets = app.sheets
        if sheets.firstMatch.exists {
            for label in cancelButtons {
                let button = sheets.buttons[label]
                if button.exists {
                    button.click()
                    return
                }
            }
        }
    }

    // MARK: - Failure Diagnostics

    private func attachFailureArtifactsIfNeeded() {
        guard let run = testRun, run.totalFailureCount > 0 else { return }

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Failure Screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Accessibility Hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
