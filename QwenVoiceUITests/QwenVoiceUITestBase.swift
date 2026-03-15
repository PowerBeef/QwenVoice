import XCTest

enum UITestLaunchPolicy {
    case sharedPerClass
    case freshPerTest
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

    private init() { }

    func launchSharedApp(
        initialScreen: UITestScreen?,
        debugCapture: Bool,
        additionalEnvironment: [String: String] = [:]
    ) -> XCUIApplication {
        if let sharedApp, sharedApp.state != .notRunning {
            sharedApp.activate()
            return sharedApp
        }

        let app = makeApplication(
            initialScreen: initialScreen,
            debugCapture: debugCapture,
            additionalEnvironment: additionalEnvironment
        )
        app.launch()
        sharedApp = app
        return app
    }

    func sharedApplication(
        initialScreen: UITestScreen?,
        debugCapture: Bool,
        additionalEnvironment: [String: String] = [:]
    ) -> XCUIApplication {
        launchSharedApp(
            initialScreen: initialScreen,
            debugCapture: debugCapture,
            additionalEnvironment: additionalEnvironment
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
/// Uses a shared app session per class by default to reduce launch overhead.
class QwenVoiceUITestBase: XCTestCase {
    private(set) var app: XCUIApplication!

    class var launchPolicy: UITestLaunchPolicy { .sharedPerClass }
    class var initialScreen: UITestScreen? { nil }
    class var additionalLaunchEnvironment: [String: String] { [:] }

    private var debugCaptureEnabled: Bool {
        let flag = ProcessInfo.processInfo.environment["QWENVOICE_DEBUG_ON_FAIL"] ?? ""
        return flag == "1" || flag == "true"
    }

    override class func setUp() {
        super.setUp()
        if launchPolicy == .sharedPerClass {
            _ = QwenVoiceUITestSession.shared.launchSharedApp(
                initialScreen: initialScreen,
                debugCapture: ProcessInfo.processInfo.environment["QWENVOICE_DEBUG_ON_FAIL"] == "1"
                    || ProcessInfo.processInfo.environment["QWENVOICE_DEBUG_ON_FAIL"] == "true",
                additionalEnvironment: additionalLaunchEnvironment
            )
        }
    }

    override class func tearDown() {
        if launchPolicy == .sharedPerClass {
            QwenVoiceUITestSession.shared.terminateSharedApp()
        }
        super.tearDown()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false

        switch type(of: self).launchPolicy {
        case .sharedPerClass:
            app = QwenVoiceUITestSession.shared.sharedApplication(
                initialScreen: type(of: self).initialScreen,
                debugCapture: debugCaptureEnabled,
                additionalEnvironment: type(of: self).additionalLaunchEnvironment
            )
        case .freshPerTest:
            app = QwenVoiceUITestSession.shared.launchFreshApp(
                initialScreen: type(of: self).initialScreen,
                debugCapture: debugCaptureEnabled,
                additionalEnvironment: type(of: self).additionalLaunchEnvironment
            )
        }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "App window should appear")

        dismissTransientUI()

        if let initialScreen = type(of: self).initialScreen {
            resetToScreen(initialScreen)
        }
    }

    override func tearDownWithError() throws {
        attachFailureArtifactsIfNeeded()

        if type(of: self).launchPolicy == .freshPerTest {
            app.terminate()
        }

        app = nil
    }

    // MARK: - Navigation Helpers

    func launchSharedApp(initialScreen: UITestScreen? = nil) {
        app = QwenVoiceUITestSession.shared.launchSharedApp(
            initialScreen: initialScreen,
            debugCapture: debugCaptureEnabled,
            additionalEnvironment: type(of: self).additionalLaunchEnvironment
        )
    }

    func relaunchFreshApp(
        initialScreen: UITestScreen? = nil,
        additionalEnvironment: [String: String] = [:]
    ) {
        if let app, app.state != .notRunning {
            app.terminate()
        }

        let mergedEnvironment = type(of: self).additionalLaunchEnvironment
            .merging(additionalEnvironment) { _, new in new }

        app = QwenVoiceUITestSession.shared.launchFreshApp(
            initialScreen: initialScreen,
            debugCapture: debugCaptureEnabled,
            additionalEnvironment: mergedEnvironment
        )

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "App window should appear after relaunch")
        dismissTransientUI()
    }

    func waitForScreen(_ screen: UITestScreen, timeout: TimeInterval = 5) -> XCUIElement {
        let element = screenElement(for: screen)
        let deadline = Date().addingTimeInterval(timeout)
        var lastSettingsOpenAttempt: Date?

        while Date() < deadline {
            if isScreenVisible(screen) {
                return element
            }
            if screen == .preferences {
                let shouldRetryOpen = lastSettingsOpenAttempt.map { Date().timeIntervalSince($0) > 1 } ?? true
                if shouldRetryOpen {
                    openSettingsWindow()
                    lastSettingsOpenAttempt = Date()
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
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
