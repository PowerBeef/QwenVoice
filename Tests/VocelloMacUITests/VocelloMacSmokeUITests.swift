import XCTest

/// macOS UI smoke suite — the standing automated pre-release gate.
///
/// Mirrors the iOS suite's pattern (Tests/VocelloiOSUITests): resolve elements
/// by stable `accessibilityIdentifier` (CLAUDE.md: identifiers are stable
/// surface area), tolerate missing models via the hidden window markers
/// (`mainWindow_disabledSidebarItems`), and keep every test independent.
///
/// Launches with `QWENVOICE_DEBUG=1` so all test data (History rows, output
/// WAVs) lands in the isolated `QwenVoice-Debug/` folder, never real data.
///
/// Run: `xcodebuild test -scheme QwenVoice -destination 'platform=macOS,arch=arm64'`
final class VocelloMacSmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["QWENVOICE_DEBUG"] = "1"
        app.launch()
        XCTAssertTrue(waitFor("mainWindow_ready", timeout: 30), "main window should mount")
    }

    override func tearDown() {
        app.terminate()
        app = nil
        super.tearDown()
    }

    // MARK: - Launch & navigation

    func testMainWindowReady() {
        XCTAssertTrue(element("sidebar_customVoice").exists, "sidebar should be present")
        XCTAssertTrue(element("sidebar_settings").exists, "settings item should be present")
    }

    func testSidebarNavigation() {
        let disabled = disabledSidebarItems()
        for item in ["customVoice", "voiceDesign", "voiceCloning", "history", "voices", "settings"] {
            guard !disabled.contains(item) else { continue }
            element("sidebar_\(item)").tap()
            XCTAssertTrue(
                activeScreenBecomes(item),
                "sidebar_\(item) should activate screen \(item)"
            )
        }
    }

    func testKeyboardNavigation() {
        let disabled = disabledSidebarItems()
        let shortcuts: [(String, String)] = [
            ("1", "customVoice"), ("2", "voiceDesign"), ("3", "voiceCloning"),
            ("4", "history"), ("5", "voices"), ("6", "settings"),
        ]
        for (key, item) in shortcuts {
            guard !disabled.contains(item) else { continue }
            app.typeKey(key, modifierFlags: .command)
            XCTAssertTrue(
                activeScreenBecomes(item),
                "Cmd+\(key) should activate screen \(item)"
            )
        }
    }

    // MARK: - Composer

    func testComposerTypingUpdatesCharCount() throws {
        try skipIfDisabled("customVoice")
        element("sidebar_customVoice").tap()
        XCTAssertTrue(waitFor("screen_customVoice"))

        XCTAssertTrue(typeScript("Smoke test sentence."), "typed text should land in the editor")

        let charCount = element("textInput_charCount")
        XCTAssertTrue(charCount.waitForExistence(timeout: 5), "char count badge should exist")
        let label = ((charCount.value as? String) ?? charCount.label)
        XCTAssertFalse(label.hasPrefix("0"), "char count should reflect the typed text (got: \(label))")
        clearEditor()
    }

    func testGenerateCustomVoiceSmoke() throws {
        try skipIfDisabled("customVoice")
        element("sidebar_customVoice").tap()
        XCTAssertTrue(waitFor("screen_customVoice"))

        XCTAssertTrue(typeScript("Automated smoke generation."), "typed text should land")

        let generate = element("textInput_generateButton")
        XCTAssertTrue(generate.waitForExistence(timeout: 5), "generate button should exist")
        guard waitForEnabled(generate) else {
            throw XCTSkip("generate disabled (model not ready in this environment)")
        }
        generate.tap()

        // Generation incl. a possible cold model load — generous timeout.
        XCTAssertTrue(
            element("sidebarPlayer_bar").waitForExistence(timeout: 180),
            "player bar should appear after generation"
        )
        XCTAssertFalse(element("sidebar_backendStatus_error").exists, "no engine error state")
        XCTAssertFalse(element("sidebar_backendStatus_crashed").exists, "no engine crash state")
        clearEditor()
    }

    func testCancelDuringGeneration() throws {
        try skipIfDisabled("customVoice")
        element("sidebar_customVoice").tap()
        XCTAssertTrue(waitFor("screen_customVoice"))

        guard typeScript(
            "A deliberately longer script so the generation runs long enough for the"
            + " cancel control to appear and be exercised by the automated smoke suite."
        ) else {
            throw XCTSkip("composer not ready (strict typing coverage lives in testComposerTypingUpdatesCharCount)")
        }
        let generate = element("textInput_generateButton")
        guard generate.waitForExistence(timeout: 5), waitForEnabled(generate) else {
            throw XCTSkip("generate unavailable (model not ready)")
        }
        generate.tap()

        let cancel = element("textInput_cancelButton")
        guard cancel.waitForExistence(timeout: 30) else {
            throw XCTSkip("generation finished before cancel appeared")
        }
        cancel.tap()
        // Cancel is cooperative; allow time for the UI to settle back.
        XCTAssertTrue(
            waitForDisappearance(cancel, timeout: 120),
            "cancel button should disappear after cancellation"
        )
        XCTAssertFalse(element("sidebar_backendStatus_error").exists, "cancel must not surface an error state")
        clearEditor()
    }

    // MARK: - Library screens

    func testHistoryScreen() throws {
        try skipIfDisabled("history")
        element("sidebar_history").tap()
        XCTAssertTrue(waitFor("screen_history"))
        XCTAssertTrue(element("history_searchField").exists, "search field should exist")
        XCTAssertTrue(element("history_sortPicker").exists, "sort picker should exist")
    }

    func testVoicesScreenAndEnrollSheet() throws {
        try skipIfDisabled("voices")
        element("sidebar_voices").tap()
        XCTAssertTrue(waitFor("screen_voices"))

        let enroll = element("voices_enrollButton")
        XCTAssertTrue(enroll.waitForExistence(timeout: 10), "enroll button should exist")
        enroll.tap()
        XCTAssertTrue(
            element("voicesEnroll_nameField").waitForExistence(timeout: 10),
            "enroll sheet should open with the name field"
        )
        let cancel = element("voicesEnroll_cancelButton")
        XCTAssertTrue(cancel.exists, "enroll sheet should have a cancel button")
        cancel.tap()
        XCTAssertTrue(
            waitForDisappearance(element("voicesEnroll_nameField"), timeout: 10),
            "enroll sheet should close on cancel"
        )
    }

    func testSettingsScreen() {
        element("sidebar_settings").tap()
        XCTAssertTrue(waitFor("screen_settings"))
        XCTAssertTrue(
            element("settings_modelDownloadsSummary").waitForExistence(timeout: 10),
            "model downloads summary should exist"
        )
        XCTAssertTrue(element("preferences_autoPlayToggle").exists, "auto-play toggle should exist")
        XCTAssertTrue(element("preferences_outputDirectory").exists, "output directory row should exist")
    }

    func testBatchSheetOpens() throws {
        try skipIfDisabled("customVoice")
        element("sidebar_customVoice").tap()
        XCTAssertTrue(waitFor("screen_customVoice"))

        let batch = element("textInput_batchButton")
        guard batch.waitForExistence(timeout: 10), batch.isEnabled else {
            throw XCTSkip("batch unavailable (model not ready)")
        }
        batch.tap()
        XCTAssertTrue(
            element("batch_textEditor").waitForExistence(timeout: 10),
            "batch sheet should open with its text editor"
        )
        let cancel = element("batch_cancelButton")
        XCTAssertTrue(cancel.exists, "batch sheet should have a cancel button")
        cancel.tap()
        XCTAssertTrue(
            waitForDisappearance(element("batch_textEditor"), timeout: 10),
            "batch sheet should close on cancel"
        )
    }

    // MARK: - Helpers (ported from the iOS suite)

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @discardableResult
    private func waitFor(_ identifier: String, timeout: TimeInterval = 15) -> Bool {
        element(identifier).waitForExistence(timeout: timeout)
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return !element.exists
    }

    /// The hidden `mainWindow_disabledSidebarItems` marker carries a
    /// comma-separated list of sidebar items disabled because their model is
    /// not installed — tests skip rather than fail in model-less environments.
    private func disabledSidebarItems() -> Set<String> {
        let marker = element("mainWindow_disabledSidebarItems")
        guard marker.exists else { return [] }
        let raw = (marker.value as? String) ?? marker.label
        guard raw != "none" else { return [] }
        // Marker carries accessibility IDs ("sidebar_customVoice,…") — strip
        // the prefix so callers use bare item names.
        return Set(raw.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "sidebar_", with: "")
        })
    }

    private func skipIfDisabled(_ item: String) throws {
        if disabledSidebarItems().contains(item) {
            throw XCTSkip("\(item) is disabled in this environment (model not installed)")
        }
    }

    private func activeScreenBecomes(_ item: String, timeout: TimeInterval = 10) -> Bool {
        let marker = element("mainWindow_activeScreen")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = ((marker.value as? String) ?? marker.label)
            if value.contains(item) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return false
    }

    /// The engine resolves model availability asynchronously after launch —
    /// poll for the generate button to enable before deciding to skip.
    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval = 45) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isEnabled { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return element.exists && element.isEnabled
    }

    /// SwiftUI's TextEditor on macOS exposes a scroll-area wrapper; clicking
    /// it doesn't always focus the inner AXTextArea. Click the element's
    /// center, then type at the APPLICATION level (routes to first responder)
    /// and verify the char-count badge moved — retrying once with a
    /// double-click if the first attempt didn't land.
    @discardableResult
    private func typeScript(_ text: String) -> Bool {
        let editor = element("textInput_textEditor")
        guard editor.waitForExistence(timeout: 10) else { return false }
        for attempt in 0..<2 {
            if attempt == 0 {
                editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).click()
            } else {
                editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).doubleClick()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            app.typeText(text)
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                let badge = element("textInput_charCount")
                let label = ((badge.value as? String) ?? badge.label)
                if badge.exists, !label.isEmpty, !label.hasPrefix("0") { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
        }
        return false
    }

    private func clearEditor() {
        let editor = element("textInput_textEditor")
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
    }
}
