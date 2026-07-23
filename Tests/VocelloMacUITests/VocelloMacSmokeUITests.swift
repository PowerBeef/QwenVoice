import AVFoundation
@preconcurrency import XCTest

/// The macOS smoke suite: seven focused journeys that run in the numbered
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

    /// Ordinary line-separated batch on the unified sequential streaming
    /// path: two short lines generate as streamed takes with mandatory engine
    /// QC and land in History individually.
    func test07_LineBatchJourney() {
        beginSession()
        defer { endSession() }

        let nonce = "smoke-batch-\(Self.pronounceableNonce())"
        prepare(mode: .custom)

        XCTAssertTrue(VocelloUIPrimaryAction.perform(on: button("textInput_batchButton"), timeout: 30))
        let editor = element("batch_textEditor")
        XCTAssertTrue(VocelloUIWait.exists(editor, timeout: 30))
        let lines = "First batch line about the morning tide \(nonce).\nSecond batch line about the evening harbor \(nonce)."
        XCTAssertTrue(VocelloUITextEntry.replace(in: editor, with: lines, timeout: 20))

        let generateAll = button("batch_generateAllButton")
        XCTAssertTrue(VocelloUIWait.exists(generateAll, timeout: 20))
        XCTAssertTrue(VocelloUIPrimaryAction.perform(on: generateAll, timeout: 20))

        let done = button("batch_doneButton")
        XCTAssertTrue(
            VocelloUIWait.condition("line batch to settle", timeout: 600) {
                done.exists && done.isEnabled
            }
        )
        VocelloUIScreenshot.attach(app, named: "mac-smoke-linebatch-complete")
        XCTAssertTrue(VocelloUIPrimaryAction.perform(on: done, timeout: 20))

        // Both takes must be visible in History exactly once each.
        assertHistoryRows(matching: nonce, expected: 2)
    }

    /// Emits the project wall time (Generate All → settled outcome) for the
    /// lane to combine with the newest v4 manifest — the Xcode 26 test runner
    /// cannot read another app's Application Support (see `virtualClipURL`),
    /// so filesystem work stays lane-side (`scripts/ui_test.sh`). Attached
    /// evidence only; canonical registry publication stays with the benchmark
    /// pipeline and its schema review.
    private func attachLongFormProjectSummary(wallSeconds: TimeInterval) {
        let line = String(format: "LONGFORM_WALL_SECONDS=%.1f", wallSeconds)
        XCTContext.runActivity(named: line) { activity in
            let attachment = XCTAttachment(string: line)
            attachment.name = "long-form-project-wall-seconds"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        print(line)
    }

    /// Random lowercase pseudo-word: unique enough for History matching while
    /// reading as one spoken token. Hex/UUID nonces are spelled out character
    /// by character with pauses that can trip the punctuation-budget dropout
    /// QC rule on real generations.
    private static func pronounceableNonce() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return String((0..<8).map { _ in letters.randomElement()! })
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

        let nonce = "smoke-complete-\(Self.pronounceableNonce())"
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

        let nonce = "smoke-cancel-\(Self.pronounceableNonce())"
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

    /// Live long-form v4 acceptance: a >900-character script routes to the
    /// long-form sheet, plans multiple segments, streams them sequentially,
    /// joins the output, and lands in History as a project row with an
    /// expandable segment map. Real generation: expect several minutes.
    func test06_LongFormProjectJourney() {
        beginSession()
        defer { endSession() }

        let nonce = "smoke-longform-\(Self.pronounceableNonce())"
        // Varied natural narration (~1,900 characters -> two planned segments):
        // verbatim sentence repetition can push the model into degenerate
        // delivery, which would test the corpus rather than the pipeline.
        let paragraphs = [
            "Long-form acceptance token \(nonce) opens this narration with a calm, steady voice.",
            "The morning train slipped quietly out of the station, carrying a handful of sleepy travelers toward the coast.",
            "Outside the fogged windows, pale fields gave way to grey water, and the rhythm of the rails settled into a low, hypnotic hum.",
            "By the time the sun finally broke through, most of the passengers had drifted into an unhurried silence.",
            "A conductor moved down the aisle with practiced ease, greeting familiar faces and pausing to answer a question about the tides.",
            "Somewhere behind the last carriage, gulls wheeled over the harbor, their cries thin against the wind.",
            "The narrator lingered on small details: a folded newspaper, a chipped enamel mug, the smell of salt drifting through a cracked window.",
            "Later, the town appeared all at once, stacked in weathered rows above the seawall, chimneys leaning into the light.",
            "People stepped down onto the platform and scattered toward their mornings, and the train breathed out and rested.",
            "The story closed the way it began, with the sea keeping its own patient time beneath a widening sky.",
            "Every ending leaves a little room, the narrator said, for whatever the afternoon decides to become.",
            "And with that, the recording came gently to a close, its final sentence trailing into the sound of distant water.",
            "A second movement began further up the coast, where the road narrowed between dry stone walls and fields of late clover.",
            "Cyclists passed in twos and threes, and an old dog watched them from a doorway without much opinion either way.",
            "In the market square, awnings snapped softly in the breeze while crates of plums and greens changed hands with easy talk.",
            "The clock above the chemist ran four minutes fast, a fact the whole town had agreed to forgive decades ago.",
            "When the rain finally came, it arrived politely, more mist than storm, silvering the slate roofs one street at a time.",
            "Children ran the long way home past the bakery, trading exaggerated stories about the size of the waves beyond the pier.",
            "Evening settled in without ceremony, and the lamps along the seafront warmed to their work one by one.",
            "The narrator let the last image stand on its own: a small boat turning for home, its wake folding back into the dark water.",
        ]
        let script = paragraphs.joined(separator: " ")
        XCTAssertGreaterThan(script.count, 1_300)

        prepare(mode: .custom)
        replaceScript(with: script)

        // Long scripts route the visible Generate action to the long-form sheet.
        XCTAssertTrue(VocelloUIPrimaryAction.perform(on: button("textInput_generateButton"), timeout: 30))
        let generateAll = button("batch_generateAllButton")
        XCTAssertTrue(VocelloUIWait.exists(generateAll, timeout: 30))
        let projectStartedAt = Date()
        XCTAssertTrue(VocelloUIPrimaryAction.perform(on: generateAll, timeout: 20))

        // Completion: the long-form outcome exposes per-segment regeneration
        // and, on a clean run, no resume affordance.
        let firstRegenerate = button("batch_regenerateSegment_0")
        let resume = button("batch_resumeLongFormButton")
        XCTAssertTrue(
            VocelloUIWait.condition("long-form outcome to settle", timeout: 900) {
                firstRegenerate.exists || resume.exists
            },
            "long-form generation must reach a terminal project outcome"
        )
        XCTAssertTrue(
            firstRegenerate.exists && !resume.exists,
            "a clean long-form run must save every segment (resume affordance means a segment failed)"
        )
        let projectWallSeconds = Date().timeIntervalSince(projectStartedAt)
        attachLongFormProjectSummary(wallSeconds: projectWallSeconds)
        VocelloUIScreenshot.attach(app, named: "mac-smoke-longform-complete")

        let done = button("batch_doneButton")
        XCTAssertTrue(VocelloUIPrimaryAction.perform(on: done, timeout: 20))

        // Search renders flat: the nonce appears in the joined row and the
        // first segment row.
        assertHistoryRows(matching: nonce, expected: 2)

        // Cleared search groups the project: the joined row exposes the
        // segment-map toggle.
        let search = element("history_searchField", type: .searchField)
        XCTAssertTrue(VocelloUITextEntry.replace(in: search, with: "", timeout: 20))
        let togglePredicate = NSPredicate(
            format: "identifier BEGINSWITH 'history_longFormSegmentsToggle_'"
        )
        let toggle = app.descendants(matching: .any).matching(togglePredicate).firstMatch
        XCTAssertTrue(
            VocelloUIWait.condition("long-form project row to expose its segment map toggle", timeout: 30) {
                toggle.exists
            }
        )
        XCTAssertTrue(VocelloUIPrimaryAction.perform(on: toggle, timeout: 20))
        VocelloUIScreenshot.attach(app, named: "mac-smoke-longform-history-project")

        // Expanded map shows the nonce twice even without search (joined row
        // plus the first segment row).
        assertHistoryRows(matching: nonce, expected: 2)
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
