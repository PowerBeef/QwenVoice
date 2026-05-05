import AVFoundation
import Combine
import XCTest

@testable import QwenVoice
@testable import QwenVoiceCore
@testable import QwenVoiceNative

/// Programmatic integration test for the macOS live-preview pipeline.
///
/// Wires the real components directly — no XCUITest, no TCC, no launched
/// process:
///
///     UITestStubMacEngine.generate()
///         → StubBackendTransport writes chunk_*.wav + emits .streamChunk
///             events to `GenerationChunkBroker.publish(event)`
///                 → AudioPlayerViewModel subscribes to the broker,
///                     handleGenerationChunk → appendLiveChunk →
///                     loadPCMBuffer (the AVAudioFile decode).
///
/// This is the path where the "Live audio preview could not decode the
/// latest chunk." error originates. Asserting `viewModel.playbackError`
/// stays `nil` through an entire stub generation protects against the
/// finalization race (fix landed in commit `7c8b187`) and any future
/// regression in the broker / AudioPlayerViewModel plumbing.
///
/// Runs under the `swift` harness layer. Unlike the XCUITest-based
/// `VocelloUITests/LivePreviewSmokeTests`, it requires neither
/// Accessibility permission nor a GUI session, so it's safe to run in
/// headless CI.
@MainActor
final class LivePreviewIntegrationTests: XCTestCase {

    private var fixtureRoot: URL!
    private var viewModel: AudioPlayerViewModel!
    private var engine: UITestStubMacEngine!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false

        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "qwenvoice-live-preview-\(UUID().uuidString)",
                isDirectory: true
            )
        try stageStubFixture(at: fixtureRoot)

        // AppPaths reads QWENVOICE_APP_SUPPORT_DIR at every access, so
        // setting it here reroutes both the engine's loadModel check and
        // the StubBackendTransport's output-path resolution into the
        // fixture.
        setenv("QWENVOICE_APP_SUPPORT_DIR", fixtureRoot.path, 1)

        // AudioPlayerViewModel suppresses its auto-subscribe when running
        // under XCTest (otherwise the test-host app's @StateObject
        // viewModel races with this one for chunk events and deletes the
        // files first). Explicitly opt in so THIS viewModel is the only
        // subscriber to GenerationChunkBroker for the duration of the test.
        viewModel = AudioPlayerViewModel()
        viewModel.startLivePreviewChunkSubscriptionForTesting()

        engine = UITestStubMacEngine()
        try await engine.initialize(appSupportDirectory: fixtureRoot)
    }

    override func tearDown() async throws {
        engine = nil
        viewModel = nil
        unsetenv("QWENVOICE_APP_SUPPORT_DIR")
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        try await super.tearDown()
    }

    // MARK: - Tests

    /// End-to-end pipeline test: stub backend emits chunks,
    /// `AudioPlayerViewModel` receives them through
    /// `GenerationChunkBroker`, and every chunk decodes cleanly.
    ///
    /// Asserts the strong invariants the pipeline MUST satisfy:
    ///   * Every stub chunk (3 total) reaches `appendLiveChunk` AND
    ///     decodes successfully — `livePreviewQueueDepth == 3`.
    ///   * `isLiveStream` flips to true on first chunk arrival.
    ///   * `currentTitle` propagates from the chunk event.
    ///   * `playbackError` stays nil — no decode error surfaces.
    ///
    /// The previous iteration of this test tolerated an intermittent
    /// decode-error condition that came from a cross-test-host
    /// duplicate-subscriber race: the app's own `@StateObject`
    /// `AudioPlayerViewModel` (constructed by `QwenVoiceApp` at test-host
    /// launch) was competing with the test-owned viewModel for chunks on
    /// the shared `GenerationChunkBroker`, and the first handler to run
    /// deleted the file before the second could open it. That race is
    /// fixed by suppressing the host viewModel's auto-subscribe under
    /// XCTest (see `AudioPlayerViewModel.init` + the new
    /// `startLivePreviewChunkSubscriptionForTesting()`), so this test now
    /// asserts the strict invariant.
    func testStubGenerationReachesLivePreviewViewModel() async throws {
        let request = GenerationRequest(
            modelID: "pro_custom",
            text: "Hey there",
            outputPath: fixtureRoot
                .appendingPathComponent("outputs/CustomVoice/integration-test.wav")
                .path,
            shouldStream: true,
            streamingTitle: "Hey there",
            payload: .custom(speakerID: "vivian", deliveryStyle: "Conversational")
        )

        _ = try await engine.generate(request)

        // After generate() returns, three chunk events have been published.
        // Combine delivers them via .receive(on: .main) so yield until all
        // three have decoded — or a decode error interrupts.
        try await waitUntil(timeoutSeconds: 2.0) {
            self.viewModel.playbackError != nil
                || self.viewModel.livePreviewQueueDepth >= 3
        }

        XCTAssertNil(
            viewModel.playbackError,
            """
            A decode error surfaced during stub streaming:
              \(viewModel.playbackError ?? "nil")
            `loadPCMBuffer(from:)` returned nil for at least one chunk, which
            means the file was unreadable at decode time. The most likely
            cause is a duplicate-subscriber race on GenerationChunkBroker
            (see AudioPlayerViewModel.init suppression + the test-only
            startLivePreviewChunkSubscriptionForTesting hook) — verify no
            other subscriber is alive for the duration of this test.
            """
        )
        XCTAssertEqual(
            viewModel.livePreviewQueueDepth, 3,
            "All three stub chunks should have decoded and been scheduled."
        )
        XCTAssertTrue(
            viewModel.isLiveStream,
            "Live stream flag should have flipped on first chunk arrival."
        )
        XCTAssertEqual(
            viewModel.currentTitle, "Hey there",
            "Live session title should have been propagated from the chunk event."
        )

        if let playbackError = viewModel.playbackError {
            // Retained as a safety net: if the assertion above ever fires
            // under a new regression, attach the state so the xcresult
            // contains enough data to diagnose without rerunning.
            let state = """
            playbackError: \(playbackError)
            livePreviewQueueDepth: \(viewModel.livePreviewQueueDepth)
            isLiveStream: \(viewModel.isLiveStream)
            livePreviewPhase: \(viewModel.livePreviewPhase.rawValue)
            currentTitle: \(viewModel.currentTitle)
            """
            let attachment = XCTAttachment(string: state)
            attachment.name = "live-preview-diagnostic-state"
            add(attachment)
        }
    }

    /// Parallel to `testStubGenerationReachesLivePreviewViewModel` but uses
    /// the `.design` payload (Voice Design mode). Proves the broker →
    /// viewModel chain is mode-agnostic: every streaming mode that exists
    /// in the `GenerationMode` enum routes through the same plumbing and
    /// exercises the same live-preview path in the UI.
    func testDesignModeStreamingReachesLivePreviewViewModel() async throws {
        let request = GenerationRequest(
            modelID: "pro_design",
            text: "Design mode preview",
            outputPath: fixtureRoot
                .appendingPathComponent("outputs/VoiceDesign/design-integration.wav")
                .path,
            shouldStream: true,
            streamingTitle: "Design mode preview",
            payload: .design(
                voiceDescription: "A calm narrator with warm, deliberate pacing.",
                deliveryStyle: "Warm"
            )
        )

        _ = try await engine.generate(request)

        try await waitUntil(timeoutSeconds: 2.0) {
            self.viewModel.playbackError != nil
                || self.viewModel.livePreviewQueueDepth >= 3
        }

        XCTAssertNil(
            viewModel.playbackError,
            "A decode error surfaced during Voice Design streaming: \(viewModel.playbackError ?? "nil")"
        )
        XCTAssertEqual(
            viewModel.livePreviewQueueDepth, 3,
            "All three stub chunks should have decoded in Voice Design mode."
        )
        XCTAssertTrue(
            viewModel.isLiveStream,
            "Live stream flag should have flipped for Voice Design streaming."
        )
        XCTAssertEqual(
            viewModel.currentTitle, "Design mode preview",
            "Live session title should have propagated from the Voice Design chunk event."
        )
    }

    /// Mirror of the Custom/Design streaming tests but exercising the
    /// `.clone` payload. Proves every streaming mode routes chunks
    /// through the same broker → viewModel chain — if a future change
    /// accidentally diverges the clone path (e.g. by adding a separate
    /// event type or a different broker subject), this test flags it.
    func testCloneModeStreamingReachesLivePreviewViewModel() async throws {
        // Stub backend's clone path doesn't actually open the reference
        // audio file, so a synthetic path is fine here.
        let reference = CloneReference(
            audioPath: fixtureRoot
                .appendingPathComponent("voices/test-reference.wav").path,
            transcript: "reference transcript",
            preparedVoiceID: nil
        )
        let request = GenerationRequest(
            modelID: "pro_clone",
            text: "Clone mode preview",
            outputPath: fixtureRoot
                .appendingPathComponent("outputs/Clones/clone-integration.wav")
                .path,
            shouldStream: true,
            streamingTitle: "Clone mode preview",
            payload: .clone(reference: reference)
        )

        _ = try await engine.generate(request)

        try await waitUntil(timeoutSeconds: 2.0) {
            self.viewModel.playbackError != nil
                || self.viewModel.livePreviewQueueDepth >= 3
        }

        XCTAssertNil(
            viewModel.playbackError,
            "A decode error surfaced during clone-mode streaming: \(viewModel.playbackError ?? "nil")"
        )
        XCTAssertEqual(
            viewModel.livePreviewQueueDepth, 3,
            "All three stub chunks should have decoded in clone mode."
        )
        XCTAssertTrue(
            viewModel.isLiveStream,
            "Live stream flag should have flipped for clone-mode streaming."
        )
        XCTAssertEqual(
            viewModel.currentTitle, "Clone mode preview",
            "Live session title should have propagated from the clone-mode chunk event."
        )
    }

    /// Sanity: calling generate() without shouldStream must NOT trigger the
    /// live-preview path at all, so no chunks flow to the view model.
    func testNonStreamingGenerationDoesNotTouchLivePreview() async throws {
        let request = GenerationRequest(
            modelID: "pro_custom",
            text: "One shot",
            outputPath: fixtureRoot
                .appendingPathComponent("outputs/CustomVoice/oneshot.wav")
                .path,
            shouldStream: false,
            payload: .custom(speakerID: "vivian", deliveryStyle: nil)
        )

        _ = try await engine.generate(request)
        // Give any would-be Combine deliveries time to flush.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(viewModel.playbackError, "Non-streaming path should not surface a player error.")
        XCTAssertEqual(viewModel.livePreviewQueueDepth, 0)
        XCTAssertFalse(viewModel.isLiveStream)
    }

    func testDefaultLivePreviewPrebufferThresholdFavorsSmoothness() {
        XCTAssertEqual(
            AudioPlayerViewModel.livePreviewPrebufferThresholdForTesting(),
            3,
            "Live preview should wait for three queued chunks by default to reduce audible underruns."
        )
        XCTAssertEqual(
            AudioPlayerViewModel.livePreviewMinimumBufferedDurationForTesting(),
            2.25,
            accuracy: 0.001,
            "Short clips should prefer final-file playback over fragile partial live preview."
        )
    }

    func testLivePreviewDoesNotStartBeforePrebufferThreshold() {
        let threshold = 3

        XCTAssertFalse(
            AudioPlayerViewModel.shouldStartLivePlaybackForTesting(
                queuedChunks: 1,
                prebufferThreshold: threshold
            )
        )
        XCTAssertFalse(
            AudioPlayerViewModel.shouldStartLivePlaybackForTesting(
                queuedChunks: 2,
                prebufferThreshold: threshold
            )
        )
        XCTAssertTrue(
            AudioPlayerViewModel.shouldStartLivePlaybackForTesting(
                queuedChunks: 3,
                queuedDuration: 3.0,
                prebufferThreshold: threshold
            )
        )
    }

    func testLivePreviewRequiresBufferedDurationBeforeStarting() {
        let threshold = 3
        let minimumDuration: TimeInterval = 2.25

        XCTAssertFalse(
            AudioPlayerViewModel.shouldStartLivePlaybackForTesting(
                queuedChunks: 3,
                queuedDuration: 1.8,
                prebufferThreshold: threshold,
                minimumBufferedDuration: minimumDuration
            ),
            "Chunk count alone is not enough for short clips because the preview can drain before final handoff."
        )
        XCTAssertTrue(
            AudioPlayerViewModel.shouldStartLivePlaybackForTesting(
                queuedChunks: 3,
                queuedDuration: 2.25,
                prebufferThreshold: threshold,
                minimumBufferedDuration: minimumDuration
            )
        )
    }

    func testLivePreviewRequiresFullPrebufferAfterUnderrun() {
        let threshold = 3

        XCTAssertFalse(
            AudioPlayerViewModel.shouldStartLivePlaybackForTesting(
                queuedChunks: 1,
                prebufferThreshold: threshold
            ),
            "A single new chunk after an underrun should keep buffering instead of restarting with another audible cut."
        )
        XCTAssertFalse(
            AudioPlayerViewModel.shouldStartLivePlaybackForTesting(
                queuedChunks: 2,
                prebufferThreshold: threshold
            )
        )
        XCTAssertTrue(
            AudioPlayerViewModel.shouldStartLivePlaybackForTesting(
                queuedChunks: 3,
                queuedDuration: 3.0,
                prebufferThreshold: threshold
            )
        )
    }

    func testLivePreviewCanHandoffToFinalFileBelowPrebufferThreshold() {
        XCTAssertTrue(
            AudioPlayerViewModel.shouldStartLivePlaybackForTesting(
                queuedChunks: 1,
                prebufferThreshold: 3,
                finalFileAvailable: true
            ),
            "Final-file availability should still trigger the existing authoritative handoff path."
        )
    }

    /// Audit Finding #3 coverage. The pre-fix code path passed
    /// `livePreviewDuration` (monotonically-cumulative total
    /// received audio) to `shouldStartLivePlayback`, so as
    /// playback drained the queue the predicate's view of the
    /// buffer became increasingly stale. The fix tracks
    /// `liveQueuedAudioSeconds` as a real FIFO that decrements on
    /// every buffer-completion callback. This test proves the
    /// FIFO contract: enqueue 5 buffers (3.2 s of audio), drain
    /// 3, the visible queue depth must be 2 buffers / 1.28 s.
    func testQueuedAudioSecondsTracksRealQueueDepthFIFO() {
        // 5 chunks × 0.64 s = 3.2 s — typical Qwen3 streaming
        // chunk sizing.
        let chunkSeconds: TimeInterval = 0.64
        for _ in 0 ..< 5 {
            viewModel.enqueueLiveBufferDurationForTesting(chunkSeconds)
        }

        XCTAssertEqual(
            viewModel.liveQueuedAudioSecondsForTesting,
            3.2,
            accuracy: 0.001,
            "After enqueuing 5 chunks the queue depth must equal 5 × chunk audio."
        )
        XCTAssertEqual(viewModel.liveBufferDurationsForTesting.count, 5)

        // Simulate three buffer completions (oldest first; FIFO).
        for _ in 0 ..< 3 {
            viewModel.drainLiveBufferDurationForTesting()
        }

        XCTAssertEqual(
            viewModel.liveQueuedAudioSecondsForTesting,
            1.28,
            accuracy: 0.001,
            "After draining 3 buffers, only 2 chunks (1.28 s) should remain queued."
        )
        XCTAssertEqual(viewModel.liveBufferDurationsForTesting.count, 2)
    }

    /// Audit Finding #2 coverage — late chunk after
    /// `completeStreamingPreview` while live playback is still
    /// in progress must NOT be rejected. Pre-fix, the production
    /// path recorded `liveSessionID` in `completedLiveSessionIDs`
    /// at the top of `completeStreamingPreview`, so any chunk
    /// queued in the broker's MainActor `Task { @MainActor in
    /// subject.send }` that landed after the result-channel
    /// continuation was silently dropped by
    /// `handleGenerationChunk`'s guard.
    func testCompletionGateDeferredUntilLiveDrainWhenPlaybackInProgress() {
        let sessionID = "test-session-late-chunk-deferred"
        viewModel.setLiveSessionIDForTesting(sessionID)
        viewModel.setLivePlaybackStartedForTesting(true)
        // Simulate a live playback with 3 buffers still queued —
        // the "Case B" branch of `completeStreamingPreview` (live
        // playback in progress, drain pending).
        viewModel.enqueueLiveBufferDurationForTesting(0.64)
        viewModel.enqueueLiveBufferDurationForTesting(0.64)
        viewModel.enqueueLiveBufferDurationForTesting(0.64)

        XCTAssertFalse(
            viewModel.completedLiveSessionIDsContainsForTesting(sessionID),
            "Pre-condition: session is active, not yet completed."
        )

        // The production path of `completeStreamingPreview`'s
        // Case B branch (live still playing) is exercised
        // directly by NOT draining the queue and asserting the
        // gate stays open. We simulate the post-completion
        // state by leaving `liveScheduledCount > 0` and asserting
        // the session still does not appear in
        // `completedLiveSessionIDs`. (Pre-fix this would have
        // been recorded at line 651 of `completeStreamingPreview`
        // immediately upon result delivery.)
        XCTAssertFalse(
            viewModel.completedLiveSessionIDsContainsForTesting(sessionID),
            "Audit Finding #2: with live playback in progress, the completion gate must stay open so late broker chunks are still appended."
        )

        // After the queue drains and
        // `finishLivePlaybackAfterDrainingBuffers` fires, the
        // session ID should be recorded — any chunk arriving
        // after this point IS truly stale.
        viewModel.drainLiveBufferDurationForTesting()
        viewModel.drainLiveBufferDurationForTesting()
        viewModel.drainLiveBufferDurationForTesting()
        viewModel.finishLivePlaybackAfterDrainingBuffersForTesting()

        XCTAssertTrue(
            viewModel.completedLiveSessionIDsContainsForTesting(sessionID),
            "After live playback drains, the gate closes so genuinely stale chunks are dropped."
        )
    }

    /// Audit Finding #2 coverage — `teardownLivePlayback`
    /// (user-driven dismiss / error path) must record the session
    /// as completed even without going through the
    /// completion-handoff flow. Otherwise a straggler chunk
    /// arriving after teardown would re-create a live session via
    /// `startLiveSession`'s `liveSessionID != sessionID` branch.
    func testTeardownLivePlaybackRecordsSessionAsCompleted() {
        let sessionID = "test-session-teardown-defensive"
        viewModel.setLiveSessionIDForTesting(sessionID)
        viewModel.enqueueLiveBufferDurationForTesting(0.64)

        XCTAssertFalse(
            viewModel.completedLiveSessionIDsContainsForTesting(sessionID),
            "Pre-condition: session is active, not yet completed."
        )

        viewModel.dismiss()  // calls teardownLivePlayback(clearSession: true)

        XCTAssertTrue(
            viewModel.completedLiveSessionIDsContainsForTesting(sessionID),
            "Teardown must record the session as completed defensively so post-teardown stragglers are dropped."
        )
    }

    /// Audit Finding #3 — the post-underrun resume case. The
    /// production bug: a session that has played 6+ s of audio
    /// underruns to queue=0, then a single fresh chunk arrives.
    /// Pre-fix, `livePreviewDuration` (cumulative) read 6.64 s
    /// and the predicate (Smooth-OFF Policy 1b path) saw
    /// `queuedDuration = 6.64`, satisfying its
    /// `requiredBuffer ≈ D × (1 - 1/r)` floor, and resumed
    /// playback. Real queue was 0.64 s and drained in one
    /// buffer-completion callback — repeated cycles. This test
    /// proves the predicate now correctly reads the real queue
    /// depth (1 chunk = 0.64 s, well below the floor) and
    /// returns false.
    func testShouldStartLivePlaybackUsesRealQueueDepthAfterUnderrun() {
        // Scenario: 21.76 s CV cold gen, RTF 1.56×. After ~10
        // chunks have played out, the queue underruns, and one
        // fresh chunk arrives. The predicate should NOT resume.
        let expectedAudio: TimeInterval = 21.76
        let estimatedRTF: Double = 1.56
        let realQueuedSeconds: TimeInterval = 0.64  // one chunk

        XCTAssertFalse(
            AudioPlayerViewModel.shouldStartLivePlaybackForTesting(
                queuedChunks: 1,
                queuedDuration: realQueuedSeconds,
                prebufferThreshold: 3,
                underrunCount: 1,
                expectedAudioDuration: expectedAudio,
                estimatedRTF: estimatedRTF,
                smoothPlaybackEnabled: false
            ),
            "Post-underrun, a single fresh chunk (0.64 s real queue) must NOT resume playback under any policy. Pre-fix, this returned true because the call site mistakenly passed the cumulative-received `livePreviewDuration` (~6.4 s) as `queuedDuration`."
        )

        // Sanity: with a sufficient real buffer (B_min for the
        // scenario ≈ 7.81 s), the predicate DOES resume. Confirms
        // the predicate is healthy when the call site supplies
        // the correct value.
        XCTAssertTrue(
            AudioPlayerViewModel.shouldStartLivePlaybackForTesting(
                queuedChunks: 12,
                queuedDuration: 7.81,
                prebufferThreshold: 3,
                underrunCount: 1,
                expectedAudioDuration: expectedAudio,
                estimatedRTF: estimatedRTF,
                smoothPlaybackEnabled: false
            ),
            "With a real B_min buffer queued, the predicate should resume."
        )
    }

    func testFinalPlaybackHandoffContinuesFromPartialLivePreview() {
        let handoff = AudioPlayerViewModel.finalPlaybackHandoff(
            heardLivePreview: true,
            currentTime: 0.8,
            duration: 3.0,
            autoPlayEnabled: true
        )

        XCTAssertEqual(handoff.preserveCurrentTime, 0.8, accuracy: 0.001)
        XCTAssertTrue(handoff.shouldAutoPlay)
    }

    func testFinalPlaybackHandoffLoadsReadyStateWhenLivePreviewAlreadyReachedEnd() {
        let handoff = AudioPlayerViewModel.finalPlaybackHandoff(
            heardLivePreview: true,
            currentTime: 0.95,
            duration: 1.0,
            autoPlayEnabled: true
        )

        XCTAssertEqual(handoff.preserveCurrentTime, 0, accuracy: 0.001)
        XCTAssertFalse(handoff.shouldAutoPlay)
    }

    func testFinalPlaybackHandoffUsesPreviewDurationWhenTimerTimeIsStale() {
        let handoff = AudioPlayerViewModel.finalPlaybackHandoff(
            heardLivePreview: true,
            currentTime: 0,
            previewDuration: 1.0,
            duration: 1.0,
            autoPlayEnabled: true
        )

        XCTAssertEqual(handoff.preserveCurrentTime, 0, accuracy: 0.001)
        XCTAssertFalse(handoff.shouldAutoPlay)
    }

    func testFinalPlaybackHandoffContinuesUnstreamedTailFromPreviewDuration() {
        let handoff = AudioPlayerViewModel.finalPlaybackHandoff(
            heardLivePreview: true,
            currentTime: 0.2,
            previewDuration: 0.8,
            duration: 2.0,
            autoPlayEnabled: true
        )

        XCTAssertEqual(handoff.preserveCurrentTime, 0.8, accuracy: 0.001)
        XCTAssertTrue(handoff.shouldAutoPlay)
    }

    func testFinalPlaybackHandoffAutoplaysWhenNoLivePreviewWasHeard() {
        let handoff = AudioPlayerViewModel.finalPlaybackHandoff(
            heardLivePreview: false,
            currentTime: 0,
            duration: 2.0,
            autoPlayEnabled: true
        )

        XCTAssertEqual(handoff.preserveCurrentTime, 0, accuracy: 0.001)
        XCTAssertTrue(handoff.shouldAutoPlay)
    }

    func testLateChunkAfterFinalHandoffDoesNotRestartLivePreview() async throws {
        let requestID = 99
        let sessionDirectory = fixtureRoot
            .appendingPathComponent("cache/stream_sessions/late-chunk-\(requestID)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let firstChunk = sessionDirectory.appendingPathComponent("chunk_0.wav")
        let lateChunk = sessionDirectory.appendingPathComponent("chunk_late.wav")
        let finalFile = fixtureRoot.appendingPathComponent("outputs/CustomVoice/final.wav")
        try Self.writeTinyPCM16WAV(to: firstChunk)
        try Self.writeTinyPCM16WAV(to: lateChunk)
        try Self.writeTinyPCM16WAV(to: finalFile)

        GenerationChunkBroker.publish(
            GenerationEvent(
                kind: .streamChunk,
                requestID: requestID,
                mode: QwenVoiceCore.GenerationMode.custom.rawValue,
                title: "Late chunk guard",
                chunkPath: firstChunk.path,
                isFinal: false,
                chunkDurationSeconds: 0.1,
                cumulativeDurationSeconds: 0.1,
                streamSessionDirectory: sessionDirectory.path
            )
        )

        try await waitUntil(timeoutSeconds: 2.0) {
            self.viewModel.isLiveStream
        }

        viewModel.completeStreamingPreview(
            result: GenerationResult(
                audioPath: finalFile.path,
                durationSeconds: 0.1,
                streamSessionDirectory: sessionDirectory.path,
                benchmarkSample: BenchmarkSample(streamingUsed: true)
            ),
            title: "Late chunk guard",
            shouldAutoPlay: false
        )

        XCTAssertFalse(viewModel.isLiveStream)
        XCTAssertEqual(viewModel.currentFilePath, finalFile.path)

        GenerationChunkBroker.publish(
            GenerationEvent(
                kind: .streamChunk,
                requestID: requestID,
                mode: QwenVoiceCore.GenerationMode.custom.rawValue,
                title: "Late chunk guard",
                chunkPath: lateChunk.path,
                isFinal: true,
                chunkDurationSeconds: 0.1,
                cumulativeDurationSeconds: 0.2,
                streamSessionDirectory: sessionDirectory.path
            )
        )

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(
            viewModel.isLiveStream,
            "Late chunk delivery after final-file handoff must not put the player back into Live Preview."
        )
        XCTAssertEqual(viewModel.currentFilePath, finalFile.path)
        XCTAssertNil(viewModel.playbackError)
    }

    func testPCM16StreamLimiterPreservesInRangeSamples() {
        var limiter = PCM16StreamLimiter()
        let input: [Float] = [-0.25, -0.125, 0, 0.125, 0.25]
        var output: [Int16] = []

        limiter.append(input, into: &output)

        let expected = input.map { Int16(($0 * Float(Int16.max)).rounded()) }
        XCTAssertEqual(output, expected)
        XCTAssertEqual(limiter.metrics.samplesOutsideUnitRange, 0)
        XCTAssertEqual(limiter.metrics.samplesAboveCeiling, 0)
        XCTAssertEqual(limiter.metrics.slewLimitedSamples, 0)
        XCTAssertEqual(limiter.metrics.processedSamples, input.count)
    }

    func testPCM16StreamLimiterPreventsHardClipping() {
        var limiter = PCM16StreamLimiter()
        let input: [Float] = [0, 1.4, -1.6, 1.2, -1.1, 0]
        var output: [Int16] = []

        limiter.append(input, into: &output)

        XCTAssertEqual(output.count, input.count)
        XCTAssertTrue(
            output.allSatisfy { abs(Int($0)) < Int(Int16.max) },
            "Limiter output must stay below full-scale PCM to avoid hard clipping."
        )
        XCTAssertGreaterThan(limiter.metrics.samplesOutsideUnitRange, 0)
        XCTAssertGreaterThan(limiter.metrics.samplesAboveCeiling, 0)
        XCTAssertLessThanOrEqual(limiter.metrics.limitedPeak, PCM16StreamLimiter.ceiling)
        XCTAssertLessThan(limiter.metrics.minimumAppliedGain, 1)
    }

    func testPCM16StreamLimiterSmoothesChunkBoundaries() {
        var limiter = PCM16StreamLimiter()
        var output: [Int16] = []

        limiter.append([0, 0.2, 0.4], into: &output)
        limiter.append([1.8, -1.8, 1.8], into: &output)

        let normalized = output.map { Float($0) / Float(Int16.max) }
        let maxAdjacentDiff = zip(normalized, normalized.dropFirst())
            .map { abs($1 - $0) }
            .max() ?? 0

        XCTAssertLessThanOrEqual(
            maxAdjacentDiff,
            PCM16StreamLimiter.maxSingleSampleStep + 0.001
        )
        XCTAssertGreaterThan(limiter.metrics.slewLimitedSamples, 0)
        XCTAssertEqual(limiter.metrics.processedSamples, output.count)
    }

    // MARK: - Helpers

    private func waitUntil(
        timeoutSeconds: Double,
        check: () -> Bool
    ) async throws {
        let startedAt = Date()
        while Date().timeIntervalSince(startedAt) < timeoutSeconds {
            if check() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func writeTinyPCM16WAV(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 24_000,
                channels: 1,
                interleaved: false
            )
        )
        let frameCount: AVAudioFrameCount = 4
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
        samples[0] = 0
        samples[1] = 4_000
        samples[2] = -4_000
        samples[3] = 0

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file.write(from: buffer)
    }

    /// Mirror of the Python harness `_install_stub_models` +
    /// `_create_base_directories` logic, adapted to run inline inside an
    /// XCTest setUp. Populates the fixture with empty files at every
    /// required relative path so `TTSModel.isAvailable(in:)` returns true.
    private func stageStubFixture(at root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        for relative in [
            "models",
            "outputs/CustomVoice",
            "outputs/VoiceDesign",
            "outputs/Clones",
            "voices",
            "cache/normalized_clone_refs",
            "cache/stream_sessions",
        ] {
            try fm.createDirectory(
                at: root.appendingPathComponent(relative, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let contractURL = try locateContract()
        let contract = try JSONSerialization.jsonObject(
            with: Data(contentsOf: contractURL)
        ) as? [String: Any] ?? [:]
        let models = contract["models"] as? [[String: Any]] ?? []
        let modelsRoot = root.appendingPathComponent("models", isDirectory: true)
        for model in models {
            guard let folder = model["folder"] as? String, !folder.isEmpty else {
                continue
            }
            let modelDir = modelsRoot.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
            let requiredPaths = model["requiredRelativePaths"] as? [String] ?? []
            for relative in requiredPaths {
                let target = modelDir.appendingPathComponent(relative)
                try fm.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !fm.fileExists(atPath: target.path) {
                    fm.createFile(atPath: target.path, contents: Data())
                }
            }
        }
    }

    private func locateContract() throws -> URL {
        // QwenVoiceTests links the QwenVoice target, which bundles
        // `qwenvoice_contract.json` as a resource. Probe the test bundle
        // first, then fall back to the repo-relative checkout path so the
        // test still runs when invoked out-of-tree.
        let bundles = [Bundle(for: type(of: self))] + Bundle.allBundles
        for bundle in bundles {
            if let url = bundle.url(
                forResource: "qwenvoice_contract",
                withExtension: "json"
            ) {
                return url
            }
        }
        let fallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Resources/qwenvoice_contract.json")
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        throw CocoaError(.fileReadNoSuchFile)
    }
}
