import XCTest

/// One explicit physical-device journey. It exercises visible production UI
/// in a single app session, cancels one active streamed Custom generation,
/// and then completes exactly one Custom generation.
@MainActor
final class VocelloiOSSmokeUITests: VocelloiOSUITestCase {
    func testPhysicalDeviceSmokeJourney() {
        let runnerEnvironment = ProcessInfo.processInfo.environment
        guard let runID = runnerEnvironment["TEST_RUNNER_QVOICE_IOS_SMOKE_RUN_ID"],
              !runID.isEmpty else {
            XCTFail("Physical-device smoke requires a run-scoped diagnostics identity")
            return
        }
        let diagnosticsEnvironment = [
            "QVOICE_IOS_DEVICE_RUN_ID": runID,
            "QVOICE_MAC_BENCH_RUN_ID": runID,
        ]
        beginSession(additionalEnvironment: diagnosticsEnvironment)
        defer { endSession() }

        XCTAssertTrue(VocelloUIWait.exists(element("generateSection_custom"), timeout: 20))
        XCTAssertTrue(VocelloUIWait.exists(element("textInput_textEditor"), timeout: 20))

        for mode in VocelloUIBenchMatrix.Mode.allCases {
            select(mode: mode)
        }

        for tab in VocelloiOSTab.allCases {
            select(tab: tab)
        }

        assertVisibleModelReadiness()
        VocelloUIScreenshot.attach(app, named: "ios-smoke-models-ready")

        _ = assertRequiredCloneVoice()
        VocelloUIScreenshot.attach(app, named: "ios-smoke-clone-voice-ready")

        _ = ensureAutoplayEnabled()
        prepare(mode: .custom)
        let nonce = String(
            UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        ).lowercased()
        let cancellationToken = "cancel\(nonce)"
        let memoryCancellationToken = "memory\(nonce)"
        let completionToken = "complete\(nonce)"
        let cancellationPrefix = "Cancellation \(cancellationToken). "
        let cancellationPrompt = cancellationPrefix + String(
            VocelloUIBenchMatrix.text(for: .long)
                .prefix(150 - cancellationPrefix.count)
        )
        let completionPrompt = "Completion \(completionToken). The train left the station at dawn."

        replaceScript(with: cancellationPrompt)
        startGenerationAndWaitForLivePreview()
        VocelloUIScreenshot.attach(app, named: "ios-smoke-cancellation-active")
        cancelActiveGenerationAndAssertTerminalUI()
        VocelloUIScreenshot.attach(app, named: "ios-smoke-cancellation-terminal")

        // Relaunch once with the registered one-shot debug policy. The visible
        // UI starts a normal production generation; the app's real memory guard
        // must cancel it, await terminal ownership, unload, and remain reusable.
        launchApp(
            additionalEnvironment: diagnosticsEnvironment.merging([
                "QVOICE_IOS_MEMORY_GUARD_FORCE_CRITICAL_ONCE": "1",
            ]) { _, override in override }
        )
        prepare(mode: .custom)
        let memoryPrefix = "Memory \(memoryCancellationToken). "
        let memoryPrompt = memoryPrefix + String(
            VocelloUIBenchMatrix.text(for: .long)
                .prefix(150 - memoryPrefix.count)
        )
        replaceScript(with: memoryPrompt)
        startGenerationAndWaitForAutomaticMemoryPressureTerminal()
        VocelloUIScreenshot.attach(app, named: "ios-smoke-memory-pressure-terminal")

        replaceScript(with: completionPrompt)
        _ = generateAndWaitForCompletedPlayer(timeout: 240)
        VocelloUIScreenshot.attach(app, named: "ios-smoke-custom-complete")

        replaceHistorySearch(with: completionToken)
        XCTAssertTrue(
            VocelloUIWait.condition("completed generation to appear exactly once in History", timeout: 30) {
                self.historyRows().count == 1
            },
            "The completed Custom take must appear exactly once in History"
        )

        replaceHistorySearch(with: cancellationToken)
        XCTAssertTrue(VocelloUIWait.exists(element("history_noMatchesState"), timeout: 30))
        XCTAssertEqual(historyRows().count, 0, "A cancelled take must never be committed to History")

        replaceHistorySearch(with: memoryCancellationToken)
        XCTAssertTrue(VocelloUIWait.exists(element("history_noMatchesState"), timeout: 30))
        XCTAssertEqual(
            historyRows().count,
            0,
            "A memory-pressure-cancelled take must never be committed to History"
        )
        VocelloUIScreenshot.attach(app, named: "ios-smoke-history")
    }
}
