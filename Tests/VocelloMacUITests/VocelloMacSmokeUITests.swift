import AVFoundation
@preconcurrency import XCTest

/// The macOS smoke suite: five focused journeys that run in the numbered
/// order (XCTest executes methods alphabetically). Each test owns a fresh
/// app session and leaves no persisted state behind, so a mid-suite failure
/// never poisons the journeys after it and the suite passes back-to-back.
@MainActor
final class VocelloMacSmokeUITests: VocelloMacUITestCase {
    /// The 12 s fixture clears the 10 s minimum duration so the virtual
    /// capture auto-stops into the review stage. It lives in shared `/tmp`
    /// (like the benchmark take-manifest handshake) because the app reading
    /// a file from the test runner's per-app temporary directory triggers the
    /// macOS "access data from other apps" TCC prompt. The lane
    /// (`scripts/ui_test.sh`) synthesizes it — the Xcode 26 test runner
    /// cannot write to `/tmp` itself — and this initializer only writes a
    /// fallback for direct-from-Xcode runs, where the write may or may not
    /// be permitted; `test04` asserts the file exists either way.
    private static let virtualClipURL: URL = {
        let url = URL(fileURLWithPath: "/tmp/vocello-ui-virtual-mic.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? writeSpeechLikeClip(seconds: 12.0, to: url)
        }
        return url
    }()

    // The registered QWENVOICE_FAKE_MIC_WAV input-substitution knob (see
    // config/runtime-debug-knobs.json) is only read by the reference-clip
    // recorder, so carrying it for every journey is inert outside test04.
    override var additionalLaunchEnvironment: [String: String] {
        ["QWENVOICE_FAKE_MIC_WAV": Self.virtualClipURL.path]
    }

    func test01_NavigationAndReadiness() {
        beginSession()
        defer { endSession() }

        for screen in VocelloMacScreen.allCases {
            navigate(to: screen)
        }
        assertVisibleSpeedModelReadiness()
        ensureCloneConsentEnabled()
        assertSavedCloneVoice()
        VocelloUIScreenshot.attach(app, named: "mac-smoke-readiness")
    }

    func test02_CustomGenerationAndHistory() {
        beginSession()
        defer { endSession() }

        let nonce = "smoke-complete-\(UUID().uuidString.prefix(8))"
        prepare(mode: .custom)
        replaceScript(with: "Automated Custom Voice smoke generation \(nonce).")
        generateAndWaitForCompletion(mode: .custom, timeout: 240)
        VocelloUIScreenshot.attach(app, named: "mac-smoke-custom-complete")

        // The completed take must be visible in History exactly once.
        assertHistoryRows(matching: nonce, expected: 1)
        VocelloUIScreenshot.attach(app, named: "mac-smoke-history-completed")
    }

    func test03_GenerationCancellation() {
        beginSession()
        defer { endSession() }

        let nonce = "smoke-cancel-\(UUID().uuidString.prefix(8))"
        prepare(mode: .custom)
        replaceScript(
            with: VocelloUIBenchMatrix.text(for: .long) + " Cancellation token \(nonce)."
        )
        startGenerationAndAwaitCancelControl(mode: .custom)
        cancelActiveGenerationAndAssertCleanReset()
        VocelloUIScreenshot.attach(app, named: "mac-smoke-cancelled")

        // A user-cancelled take must never land in History.
        assertHistoryRows(matching: nonce, expected: 0)
    }

    func test04_RecordingFlow() {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: Self.virtualClipURL.path),
            "virtual-microphone fixture WAV must exist before launch"
        )

        beginSession()
        defer { endSession() }

        // Consent lives in Settings; enable it first, then land on Voice Cloning.
        ensureCloneConsentEnabled()
        navigate(to: .voiceCloning)

        XCTAssertTrue(
            VocelloUIPrimaryAction.perform(on: button("voiceCloning_recordReferenceButton"), timeout: 20),
            "record-reference button must be visible and clickable"
        )
        // Scope sheet queries to the sheet subtree: the level meter animates
        // ~12×/s while recording, and a full-tree query can time out taking
        // accessibility snapshots of the whole window.
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(VocelloUIWait.exists(element("recordClip_record", in: sheet), timeout: 20))
        XCTAssertTrue(VocelloUIWait.exists(element("recordClip_levelMeter", in: sheet), timeout: 10))
        XCTAssertTrue(VocelloUIWait.exists(element("recordClip_timer", in: sheet), timeout: 10))
        VocelloUIScreenshot.attach(app, named: "mac-recording-sheet")

        XCTAssertTrue(
            VocelloUIPrimaryAction.perform(on: button("recordClip_record", in: sheet), timeout: 10)
        )
        XCTAssertTrue(
            VocelloUIWait.exists(button("recordClip_stop", in: sheet), timeout: 10),
            "stop control must appear once capture is running"
        )

        // The 12 s virtual clip auto-stops at clip end (past the 10 s
        // minimum), landing the sheet in its review stage.
        XCTAssertTrue(
            VocelloUIWait.exists(button("recordClip_use", in: sheet), timeout: 45),
            "review stage must appear after the virtual clip auto-stops"
        )
        XCTAssertTrue(VocelloUIWait.exists(button("recordClip_retake", in: sheet), timeout: 10))
        XCTAssertTrue(
            VocelloUIWait.enabled(button("recordClip_use", in: sheet), timeout: 10),
            "a clip past the 10 s minimum must enable the accept button"
        )
        VocelloUIScreenshot.attach(app, named: "mac-recording-review")

        // Stop before the permission-sensitive scenario: accepting the clip
        // starts transcript auto-fill, which can raise the speech-recognition
        // TCC dialog — a system prompt only a human may answer (see
        // docs/reference/macos-permissions.md). Cancel discards the take and
        // leaves no persisted state behind for later journeys.
        XCTAssertTrue(
            VocelloUIPrimaryAction.perform(on: button("recordClip_cancel", in: sheet), timeout: 10)
        )
        XCTAssertTrue(
            VocelloUIWait.disappears(element("recordClip_use"), timeout: 20),
            "record sheet must dismiss after cancelling"
        )
        VocelloUIScreenshot.attach(app, named: "mac-recording-cancelled")
    }

    func test05_LibrarySurfaces() {
        beginSession()
        defer { endSession() }

        navigate(to: .history)
        XCTAssertTrue(
            VocelloUIWait.exists(element("history_searchField", type: .searchField), timeout: 20)
        )
        XCTAssertTrue(VocelloUIWait.exists(element("history_sortPicker"), timeout: 20))
        navigate(to: .settings)
        XCTAssertTrue(VocelloUIWait.exists(element("settings_modelDownloadsSummary"), timeout: 20))
        VocelloUIScreenshot.attach(app, named: "mac-smoke-library")
    }

    /// Writes a mono 24 kHz speech-like PCM WAV: a two-tone "voice" under a
    /// syllable-rate envelope with phrase pauses, so the live level meter
    /// moves through its range the way real speech does.
    private static func writeSpeechLikeClip(seconds: Double, to url: URL) throws {
        let sampleRate = 24_000.0
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              let channel = buffer.floatChannelData?.pointee else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            let syllable = abs(sin(2.0 * .pi * 2.4 * t))
            let phrase: Double = sin(2.0 * .pi * 0.22 * t) > -0.55 ? 1.0 : 0.0
            let tone = 0.7 * sin(2.0 * .pi * 175.0 * t) + 0.3 * sin(2.0 * .pi * 330.0 * t)
            channel[i] = Float(0.28 * tone * syllable * phrase)
        }
        try file.write(from: buffer)
    }
}
