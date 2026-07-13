import Foundation
@preconcurrency import XCTest

enum VocelloMacScreen: String, CaseIterable {
    case customVoice
    case voiceDesign
    case voiceCloning
    case history
    case voices
    case settings

    var sidebarID: String { "sidebar_\(rawValue)" }

    var screenID: String { "screen_\(rawValue)" }
}

@MainActor
class VocelloMacUITestCase: XCTestCase {
    private(set) var session: VocelloUIApplicationSession!
    private var pendingAutoplayPreferenceRestore: Bool?

    var app: XCUIApplication { session.app }

    var additionalLaunchEnvironment: [String: String] { [:] }

    func beginSession() {
        continueAfterFailure = false
        session = VocelloUIApplicationSession()
        launchApp(additionalEnvironment: additionalLaunchEnvironment)
    }

    func endSession() {
        cleanUpPerTest()
        session?.terminate()
        session = nil
    }

    func cleanUpPerTest() {
        restorePendingAutoplayPreference()
    }

    func launchApp(additionalEnvironment: [String: String] = [:]) {
        var environment = [
            "QWENVOICE_DEBUG": "1",
            "QWENVOICE_NATIVE_TELEMETRY_MODE": "verbose",
        ]
        for (key, value) in additionalEnvironment {
            environment[key] = value
        }

        session.launch(environment: environment)
        XCTAssertTrue(
            VocelloUIWait.exists(app.windows.firstMatch, timeout: 30),
            "Vocello must expose one host-app window after launch"
        )
        navigate(to: .customVoice)
    }

    func relaunchApp(additionalEnvironment: [String: String]) {
        session.terminate()
        launchApp(additionalEnvironment: additionalEnvironment)
    }

    func element(_ id: String) -> XCUIElement {
        VocelloUIWait.element(app, id: id)
    }

    func navigate(to screen: VocelloMacScreen) {
        let sidebar = element(screen.sidebarID)
        XCTAssertTrue(VocelloUIPrimaryAction.perform(on: sidebar, timeout: 20))
        XCTAssertTrue(VocelloUIWait.exists(element(screen.screenID), timeout: 20))
        XCTAssertTrue(
            VocelloUIWait.condition("sidebar destination to become selected", timeout: 10) {
                guard let value = sidebar.value as? String else { return false }
                return value == "selected" || value.hasPrefix("selected, ")
            }
        )
    }

    /// Requires the three visible Speed package rows to report Ready. This is
    /// deliberately not replaced by a headless inventory check.
    func assertVisibleSpeedModelReadiness() {
        navigate(to: .settings)
        XCTAssertTrue(
            VocelloUIWait.exists(element("settings_modelDownloadsSummary"), timeout: 60)
        )
        for id in [
            "settings_packageStatus_pro_custom_speed",
            "settings_packageStatus_pro_design_speed",
            "settings_packageStatus_pro_clone_speed",
        ] {
            XCTAssertTrue(VocelloUIWait.value(element(id), contains: "Ready", timeout: 60))
        }
    }

    /// Benchmarks require one genuine player scheduling event. Use the visible
    /// production preference and restore the user's original value afterward;
    /// telemetry must never synthesize this milestone.
    @discardableResult
    func ensureAutoplayEnabled() -> Bool {
        navigate(to: .settings)
        let toggle = element("preferences_autoPlayToggle")
        XCTAssertTrue(VocelloUIWait.exists(toggle, timeout: 20))
        guard let wasEnabled = autoplayState(of: toggle) else {
            XCTFail("Could not read the visible Auto-play toggle state")
            return true
        }
        if !wasEnabled {
            pendingAutoplayPreferenceRestore = false
            XCTAssertTrue(VocelloUIPrimaryAction.perform(on: toggle, timeout: 20))
            XCTAssertTrue(
                VocelloUIWait.condition("Auto-play toggle to become enabled", timeout: 15) {
                    self.autoplayState(of: toggle) == true
                }
            )
        }
        return wasEnabled
    }

    func restoreAutoplayPreference(originallyEnabled: Bool) {
        guard !originallyEnabled else { return }
        pendingAutoplayPreferenceRestore = false
        restorePendingAutoplayPreference()
    }

    private func restorePendingAutoplayPreference() {
        guard pendingAutoplayPreferenceRestore == false, session != nil else { return }
        navigate(to: .settings)
        let toggle = element("preferences_autoPlayToggle")
        XCTAssertTrue(VocelloUIWait.exists(toggle, timeout: 20))
        if autoplayState(of: toggle) != false {
            XCTAssertTrue(VocelloUIPrimaryAction.perform(on: toggle, timeout: 20))
            XCTAssertTrue(
                VocelloUIWait.condition("Auto-play toggle to restore disabled", timeout: 15) {
                    self.autoplayState(of: toggle) == false
                }
            )
        }
        if autoplayState(of: toggle) == false {
            pendingAutoplayPreferenceRestore = nil
        }
    }

    private func autoplayState(of toggle: XCUIElement) -> Bool? {
        if let value = toggle.value as? Bool { return value }
        if let value = toggle.value as? NSNumber { return value.boolValue }
        guard let value = toggle.value as? String else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "on", "true", "selected": return true
        case "0", "off", "false", "not selected": return false
        default: return nil
        }
    }

    func assertSavedCloneVoice() {
        navigate(to: .voices)
        XCTAssertTrue(
            VocelloUIWait.exists(
                element("voicesRow_\(VocelloUIBenchMatrix.cloneVoiceID)"),
                timeout: 20
            ),
            "The benchmark clone voice must be visibly present in Saved Voices"
        )
        XCTAssertTrue(
            VocelloUIWait.exists(
                element("voicesRow_use_\(VocelloUIBenchMatrix.cloneVoiceID)"),
                timeout: 20
            )
        )
    }

    func prepare(mode: VocelloUIBenchMatrix.Mode) {
        switch mode {
        case .custom:
            navigate(to: .customVoice)
        case .design:
            navigate(to: .voiceDesign)
            let brief = element("voiceDesign_voiceDescriptionField")
            if (brief.value as? String) != VocelloUIBenchMatrix.voiceDesignBrief {
                XCTAssertTrue(
                    VocelloUITextEntry.replace(
                        in: brief,
                        with: VocelloUIBenchMatrix.voiceDesignBrief,
                        timeout: 20
                    )
                )
            }
            XCTAssertTrue(
                VocelloUIWait.value(
                    brief,
                    contains: VocelloUIBenchMatrix.voiceDesignBrief,
                    timeout: 10
                )
            )
        case .clone:
            navigate(to: .voices)
            let useButton = element("voicesRow_use_\(VocelloUIBenchMatrix.cloneVoiceID)")
            XCTAssertTrue(VocelloUIPrimaryAction.perform(on: useButton, timeout: 20))
            XCTAssertTrue(VocelloUIWait.exists(element("screen_voiceCloning"), timeout: 20))
            XCTAssertTrue(VocelloUIWait.exists(element("voiceCloning_activeReference"), timeout: 20))
        }
    }

    func replaceScript(with text: String) {
        let editor = element("textInput_textEditor")
        if (editor.value as? String) != text {
            XCTAssertTrue(VocelloUITextEntry.replace(in: editor, with: text, timeout: 20))
        }
        XCTAssertTrue(
            VocelloUIWait.value(
                element("textInput_charCount"),
                contains: "\(text.count) characters",
                timeout: 10
            )
        )
    }

    func assertReadyToGenerate(mode: VocelloUIBenchMatrix.Mode) {
        let readinessID: String
        switch mode {
        case .custom: readinessID = "customVoice_readiness"
        case .design: readinessID = "voiceDesign_readiness"
        case .clone: readinessID = "voiceCloning_readiness"
        }
        XCTAssertTrue(
            VocelloUIWait.value(element(readinessID), contains: "ready=true", timeout: 60)
        )
        XCTAssertTrue(VocelloUIWait.enabled(element("textInput_generateButton"), timeout: 60))
    }

    /// Player visibility is first-chunk proof; the re-enabled Generate control
    /// is the visible completion condition.
    func generateAndWaitForCompletion(
        mode: VocelloUIBenchMatrix.Mode,
        timeout: TimeInterval
    ) {
        assertReadyToGenerate(mode: mode)
        let generate = element("textInput_generateButton")
        let cancel = element("textInput_cancelButton")
        let player = element("sidebarPlayer_bar")
        let backendError = element("sidebar_backendStatus_error")
        let backendCrash = element("sidebar_backendStatus_crashed")

        XCTAssertTrue(VocelloUIPrimaryAction.perform(on: generate, timeout: 30))
        XCTAssertTrue(
            VocelloUIWait.condition("generation to visibly start", timeout: 30) {
                cancel.exists || !generate.exists || !generate.isEnabled
            }
        )
        XCTAssertTrue(
            VocelloUIWait.condition(
                "generation to complete with Generate enabled and the player visible",
                timeout: timeout
            ) {
                generate.exists
                    && generate.isEnabled
                    && !cancel.exists
                    && player.exists
                    && !backendError.exists
                    && !backendCrash.exists
            }
        )
        XCTAssertFalse(backendError.exists, "Generation must not expose a backend error")
        XCTAssertFalse(backendCrash.exists, "Generation must not expose a backend crash")
    }

    func timeout(for take: VocelloUIBenchMatrix.Take) -> TimeInterval {
        switch take.length {
        case .long: return take.warmState == .cold ? 360 : 300
        case .medium: return take.warmState == .cold ? 240 : 180
        case .short: return take.warmState == .cold ? 180 : 120
        }
    }
}
