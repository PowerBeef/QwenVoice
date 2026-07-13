import Foundation
@preconcurrency import XCTest

enum VocelloiOSTab: String, CaseIterable {
    case studio
    case voices
    case history
    case settings

    var identifier: String { "rootTab_\(rawValue)" }
}

/// Physical-device-only UI-test base. Every XCTest method receives its own
/// application session; no process, observer, or mutable fixture is shared
/// between tests.
@MainActor
class VocelloiOSUITestCase: XCTestCase {
    private(set) var session: VocelloUIApplicationSession!
    private var pendingAutoplayPreferenceRestore: Bool?

    var app: XCUIApplication { session.app }

    func beginSession() {
        continueAfterFailure = false
        pendingAutoplayPreferenceRestore = nil
        session = VocelloUIApplicationSession()
        launchApp()
    }

    func endSession() {
        defer {
            session?.terminate()
            session = nil
            pendingAutoplayPreferenceRestore = nil
        }
        restorePendingAutoplayPreference()
    }

    /// Launches the production UI. First-run onboarding is completed through
    /// its visible Skip control; no onboarding bypass environment is injected.
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
            VocelloUIWait.condition("Vocello to enter the foreground", timeout: 30) {
                self.app.state == .runningForeground
            }
        )
        completeVisibleOnboardingIfNeeded()
        XCTAssertTrue(VocelloUIWait.exists(element(VocelloiOSTab.studio.identifier), timeout: 30))
        select(tab: .studio)
        XCTAssertTrue(VocelloUIWait.exists(element("generateSection_custom"), timeout: 30))
        XCTAssertTrue(VocelloUIWait.exists(element("textInput_textEditor"), timeout: 30))
    }

    func element(_ identifier: String) -> XCUIElement {
        VocelloUIWait.element(app, id: identifier)
    }

    func completeVisibleOnboardingIfNeeded() {
        let skip = element("onboarding_skip")
        let studio = element(VocelloiOSTab.studio.identifier)
        XCTAssertTrue(
            VocelloUIWait.condition("visible onboarding or the main tab dock", timeout: 30) {
                skip.exists || (studio.exists && studio.isHittable)
            }
        )
        guard skip.exists else { return }

        XCTAssertTrue(VocelloUIPrimaryAction.perform(on: skip, timeout: 15))
        XCTAssertTrue(VocelloUIWait.disappears(element("onboarding_cta"), timeout: 20))
    }

    func select(tab: VocelloiOSTab) {
        let control = element(tab.identifier)
        XCTAssertTrue(VocelloUIWait.exists(control, timeout: 20))
        if !control.isSelected {
            XCTAssertTrue(VocelloUIPrimaryAction.perform(on: control, timeout: 20))
        }
        XCTAssertTrue(
            VocelloUIWait.condition("tab \(tab.rawValue) to become selected", timeout: 15) {
                control.exists && control.isSelected
            }
        )
    }

    func select(mode: VocelloUIBenchMatrix.Mode) {
        select(tab: .studio)
        let control = element("generateSection_\(mode.rawValue)")
        XCTAssertTrue(VocelloUIWait.exists(control, timeout: 20))
        if !control.isSelected {
            XCTAssertTrue(VocelloUIPrimaryAction.perform(on: control, timeout: 20))
        }
        XCTAssertTrue(
            VocelloUIWait.condition("Studio mode \(mode.rawValue) to become selected", timeout: 15) {
                control.exists && control.isSelected
            }
        )
        XCTAssertTrue(VocelloUIWait.exists(element(modeVisibleControlIdentifier(mode)), timeout: 20))
    }

    /// Settings exposes each model's visible status as an accessibility value.
    /// `Active` is the readiness contract; the trash control additionally proves
    /// the installed package can be managed through genuine production UI.
    func assertVisibleModelReadiness() {
        select(tab: .settings)
        for modelID in ["pro_custom", "pro_design", "pro_clone"] {
            let status = element("iosModelStatus_\(modelID)")
            XCTAssertTrue(VocelloUIWait.exists(status, timeout: 60))
            XCTAssertTrue(VocelloUIWait.value(status, contains: "Active", timeout: 20))

            let installedControl = element("iosModelDelete_\(modelID)")
            XCTAssertTrue(VocelloUIWait.exists(installedControl, timeout: 60))
            XCTAssertTrue(
                VocelloUIWait.condition("installed model control \(modelID) to be visible", timeout: 20) {
                    installedControl.exists && installedControl.isHittable
                }
            )

            for unavailableState in ["Download", "Repair", "Cancel", "Retry"] {
                XCTAssertFalse(
                    self.element("iosModel\(unavailableState)_\(modelID)").exists,
                    "Installed model \(modelID) must not expose its \(unavailableState) control"
                )
            }
        }
    }

    /// Benchmarks require a real `play()` scheduling event so the typed
    /// frontend row can report playback latency and buffer health. Exercise
    /// the genuine visible Settings control and return the user's original
    /// preference so the caller can restore it after the matrix.
    @discardableResult
    func ensureAutoplayEnabled() -> Bool {
        select(tab: .settings)
        let toggle = element("iosSettings_autoPlayToggle")
        XCTAssertTrue(VocelloUIWait.exists(toggle, timeout: 20))
        let wasEnabled = (toggle.value as? String) == "On"
        if !wasEnabled {
            // Register the rollback before touching the production control.
            // If the tap or its assertion aborts, endSession still owns the
            // original preference and restores it through this same UI.
            pendingAutoplayPreferenceRestore = wasEnabled
            XCTAssertTrue(VocelloUIPrimaryAction.perform(on: toggle, timeout: 20))
            XCTAssertTrue(VocelloUIWait.value(toggle, contains: "On", timeout: 15))
        }
        return wasEnabled
    }

    func restoreAutoplayPreference(originallyEnabled: Bool) {
        guard !originallyEnabled else { return }
        pendingAutoplayPreferenceRestore = originallyEnabled
        restorePendingAutoplayPreference()
    }

    /// Idempotent visible-UI cleanup. The benchmark's explicit defer normally
    /// calls this first; endSession repeats it only when an earlier assertion
    /// prevented that defer from being registered or completed.
    private func restorePendingAutoplayPreference() {
        guard pendingAutoplayPreferenceRestore == false, session != nil else { return }
        select(tab: .settings)
        let toggle = element("iosSettings_autoPlayToggle")
        XCTAssertTrue(VocelloUIWait.exists(toggle, timeout: 20))
        if (toggle.value as? String) != "Off" {
            XCTAssertTrue(VocelloUIPrimaryAction.perform(on: toggle, timeout: 20))
            XCTAssertTrue(VocelloUIWait.value(toggle, contains: "Off", timeout: 15))
        }
        if (toggle.value as? String) == "Off" {
            pendingAutoplayPreferenceRestore = nil
        }
    }

    @discardableResult
    func assertRequiredCloneVoice() -> XCUIElement {
        select(tab: .voices)
        let savedVoice = element("voicesRow_saved_\(VocelloUIBenchMatrix.cloneVoiceID)")
        XCTAssertTrue(
            VocelloUIWait.exists(savedVoice, timeout: 60),
            "The exact benchmark clone voice must be present in Saved Voices"
        )
        XCTAssertTrue(
            VocelloUIWait.condition("benchmark clone voice to be visible", timeout: 20) {
                savedVoice.exists && savedVoice.isHittable
            }
        )
        return savedVoice
    }

    func prepare(mode: VocelloUIBenchMatrix.Mode) {
        switch mode {
        case .custom:
            select(mode: .custom)
        case .design:
            select(mode: .design)
            setExactVoiceDesignBrief()
        case .clone:
            let savedVoice = assertRequiredCloneVoice()
            XCTAssertTrue(VocelloUIPrimaryAction.perform(on: savedVoice, timeout: 20))
            XCTAssertTrue(
                VocelloUIWait.condition("saved voice handoff to select Clone mode", timeout: 30) {
                    let clone = self.element("generateSection_clone")
                    return clone.exists && clone.isSelected
                }
            )
            let selectedReference = element("studioChip_reference")
            XCTAssertTrue(VocelloUIWait.exists(selectedReference, timeout: 30))
            // Proactive priming is a best-effort optimization. The production
            // Generate action performs required preparation on demand.
            XCTAssertTrue(
                VocelloUIWait.label(
                    selectedReference,
                    contains: VocelloUIBenchMatrix.cloneVoiceID,
                    timeout: 30
                ),
                "The visible Clone reference must match the exact benchmark voice"
            )
        }

        XCTAssertFalse(
            element("textInput_installModelButton").exists,
            "The selected mode must use its visibly installed model"
        )
    }

    func replaceScript(with text: String) {
        let editor = element("textInput_textEditor")
        XCTAssertTrue(VocelloUIWait.exists(editor, timeout: 20))
        if (editor.value as? String) != text {
            if let current = editor.value as? String, !current.isEmpty {
                let clear = element("textInput_clearButton")
                XCTAssertTrue(VocelloUIPrimaryAction.perform(on: clear, timeout: 20))
                XCTAssertTrue(
                    VocelloUIWait.condition("composer to clear through its visible control", timeout: 15) {
                        let value = editor.value as? String
                        return !clear.exists && (value == nil || value?.isEmpty == true)
                    }
                )
            }
            XCTAssertTrue(VocelloUITextEntry.replace(in: editor, with: text, timeout: 20))
        }

        let lengthCount = element("textInput_lengthCount")
        XCTAssertTrue(
            VocelloUIWait.condition("composer to contain the entered script", timeout: 15) {
                guard lengthCount.exists, let displayed = editor.value as? String else { return false }
                return displayed == text
            }
        )

        // The production editor configures Return as Done, so this is a semantic
        // keyboard dismissal rather than a coordinate tap.
        if app.keyboards.firstMatch.exists {
            editor.typeText("\n")
        }
        XCTAssertTrue(
            VocelloUIWait.condition("software keyboard to dismiss", timeout: 15) {
                !self.app.keyboards.firstMatch.exists
            }
        )
    }

    /// Uses only visible production state: enabled Generate before the action,
    /// the completed inline player after it, and no visible generation error.
    func generateAndWaitForCompletedPlayer(timeout: TimeInterval) -> String {
        let generate = element("textInput_generateButton")
        let cancel = element("textInput_cancelButton")
        let livePlayer = element("studio_livePreview_playPause")
        let completedPlayer = element("studio_inlinePlayer_playPause")
        let generationError = element("textInput_generationError")
        let replacesCompletedPlayer = completedPlayer.exists

        XCTAssertTrue(VocelloUIWait.enabled(generate, timeout: 60))
        XCTAssertFalse(generationError.exists, "Generate must not begin from an error state")
        XCTAssertTrue(VocelloUIPrimaryAction.perform(on: generate, timeout: 20))
        XCTAssertTrue(
            VocelloUIWait.condition("generation to visibly start", timeout: 30) {
                cancel.exists || livePlayer.exists || !generate.exists || !generate.isEnabled
            }
        )
        if replacesCompletedPlayer {
            XCTAssertTrue(
                VocelloUIWait.condition("previous completed player to enter the next generation", timeout: 30) {
                    !completedPlayer.exists
                }
            )
        }
        XCTAssertTrue(
            VocelloUIWait.condition("generation to finish or expose an error", timeout: timeout) {
                completedPlayer.exists || generationError.exists
            }
        )
        XCTAssertFalse(generationError.exists, "Generation must not expose its visible error control")
        XCTAssertTrue(VocelloUIWait.exists(completedPlayer, timeout: 5))
        XCTAssertTrue(
            VocelloUIWait.condition("completed player to replace live generation UI", timeout: 20) {
                completedPlayer.exists && !livePlayer.exists && !cancel.exists && !generationError.exists
            }
        )
        let prefix = "studio_inlinePlayer_generation_"
        let identifiedCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .firstMatch
        XCTAssertTrue(VocelloUIWait.exists(identifiedCard, timeout: 10))
        let generationID = String(identifiedCard.identifier.dropFirst(prefix.count))
        XCTAssertNotNil(UUID(uuidString: generationID), "Completed player must expose its genuine generation UUID")
        return generationID
    }

    /// Clears a completed take through its visible production controls, then
    /// proves the Studio composer is ready for the next warm take.
    func dismissCompletedPlayerAndAssertGenerateReady() {
        let player = element("studio_inlinePlayer_playPause")
        let dismiss = element("studio_inlinePlayer_dismiss")
        let confirm = element("studio_inlinePlayer_dismissConfirm")
        XCTAssertTrue(VocelloUIWait.exists(player, timeout: 10))
        XCTAssertTrue(VocelloUIPrimaryAction.perform(on: dismiss, timeout: 15))
        XCTAssertTrue(VocelloUIPrimaryAction.perform(on: confirm, timeout: 15))
        XCTAssertTrue(VocelloUIWait.disappears(player, timeout: 20))
        XCTAssertTrue(VocelloUIWait.enabled(element("textInput_generateButton"), timeout: 30))
        XCTAssertFalse(element("textInput_generationError").exists)
    }

    func timeout(for take: VocelloUIBenchMatrix.Take) -> TimeInterval {
        switch take.length {
        case .long: return take.warmState == .cold ? 360 : 300
        case .medium: return take.warmState == .cold ? 300 : 240
        case .short: return take.warmState == .cold ? 240 : 180
        }
    }

    private func setExactVoiceDesignBrief() {
        XCTAssertTrue(
            VocelloUIPrimaryAction.perform(on: element("studioChip_voiceBrief"), timeout: 20)
        )
        let editor = element("voiceBrief_editor")
        XCTAssertTrue(VocelloUIWait.exists(editor, timeout: 20))
        XCTAssertTrue(
            VocelloUITextEntry.replace(
                in: editor,
                with: VocelloUIBenchMatrix.voiceDesignBrief,
                timeout: 20
            )
        )
        XCTAssertTrue(
            VocelloUIWait.condition("voice-design brief to match the benchmark fixture", timeout: 15) {
                (editor.value as? String) == VocelloUIBenchMatrix.voiceDesignBrief
            }
        )
        let confirm = element("voiceBrief_confirm")
        XCTAssertTrue(VocelloUIWait.enabled(confirm, timeout: 15))
        XCTAssertTrue(VocelloUIPrimaryAction.perform(on: confirm, timeout: 15))
        XCTAssertTrue(VocelloUIWait.disappears(confirm, timeout: 20))
    }

    private func modeVisibleControlIdentifier(_ mode: VocelloUIBenchMatrix.Mode) -> String {
        switch mode {
        case .custom: return "studioChip_voice"
        case .design: return "studioChip_voiceBrief"
        case .clone: return "studioChip_reference"
        }
    }
}
