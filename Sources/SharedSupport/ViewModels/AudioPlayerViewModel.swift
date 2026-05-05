import Foundation
import AVFoundation
import Combine

#if canImport(QwenVoiceCore)
import QwenVoiceCore
#endif

#if canImport(QwenVoiceNative)
import QwenVoiceNative
#endif

#if canImport(QwenVoiceNative)
typealias PlaybackGenerationResult = QwenVoiceNative.GenerationResult
#elseif canImport(QwenVoiceCore)
typealias PlaybackGenerationResult = QwenVoiceCore.GenerationResult
#endif

/// Manages playback state for the persistent sidebar player bar.
@MainActor
final class AudioPlayerViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate {

    enum PlaybackPresentationContext: Equatable, Sendable {
        case none
        case generatePreview
        case library
    }

    enum GeneratePreviewVisibilityState: Equatable, Sendable {
        case hidden
        case preparing
        case ready
    }

    // MARK: - High-frequency playback progress (isolated to avoid fan-out)

    /// Lightweight observable that holds timer-driven properties (currentTime, duration).
    /// Only views that need per-frame progress (e.g. SidebarPlayerView) should subscribe.
    @MainActor
    final class PlaybackProgress: ObservableObject {
        @Published var currentTime: TimeInterval = 0
        @Published var duration: TimeInterval = 0

        var progress: Double {
            guard duration > 0 else { return 0 }
            return min(max(currentTime / duration, 0), 1)
        }

        var formattedCurrentTime: String { AudioPlayerViewModel.formatTime(currentTime) }
        var formattedDuration: String { AudioPlayerViewModel.formatTime(duration) }
    }

    let playbackProgress = PlaybackProgress()

    // MARK: - Published State (low-frequency)

    @Published var isPlaying = false
    @Published var currentFilePath: String?
    @Published var currentTitle: String = ""
    @Published var waveformSamples: [Float] = []
    @Published var playbackError: String?
    @Published private(set) var isLiveStream = false
    @Published private(set) var livePreviewQueueDepth = 0
    @Published private(set) var livePreviewPhase: LivePreviewPhase = .idle
    @Published private(set) var playbackPresentationContext: PlaybackPresentationContext = .none
    @Published private(set) var generatePreviewVisibilityState: GeneratePreviewVisibilityState = .hidden

    private enum PlaybackMode {
        case none
        case file
        case live
    }

    enum LivePreviewPhase: String, Sendable, Equatable {
        case idle
        case buffering
        case playing
        case draining
        case finalizing
    }

    struct FinalPlaybackHandoff: Equatable, Sendable {
        let preserveCurrentTime: TimeInterval
        let shouldAutoPlay: Bool
    }

    private struct LivePreviewConfiguration {
        let prebufferThreshold: Int
        let minimumBufferedDuration: TimeInterval

        static func current(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> LivePreviewConfiguration {
            let rawThreshold = environment["QWENVOICE_LIVE_PREVIEW_PREBUFFER_CHUNKS"]
            let parsedThreshold = rawThreshold.flatMap(Int.init).map { min(max($0, 1), 8) }
            let rawDuration = environment["QWENVOICE_LIVE_PREVIEW_PREBUFFER_SECONDS"]
            let parsedDuration = rawDuration.flatMap(Double.init).map { min(max($0, 0), 8) }
            return LivePreviewConfiguration(
                prebufferThreshold: parsedThreshold ?? 3,
                minimumBufferedDuration: parsedDuration ?? 2.25
            )
        }
    }

    /// Decides whether the live-preview player has enough buffered
    /// audio to begin (or resume) playback.
    ///
    /// Two policies, picked per-call:
    ///
    /// 1. **Predictive (smooth playback ON, has session estimate)** —
    ///    Computes the production deficit `expectedAudio × (RTF − 1)`
    ///    and requires the queue to hold at least that much buffered
    ///    audio before starting. Once playback begins, the queue
    ///    monotonically drains to zero exactly at generation end —
    ///    no underruns. TTFA grows with text length. Cap the buffer
    ///    at `expectedAudio` so unrealistic deficits (e.g. 5-min
    ///    scripts) effectively wait for completion rather than
    ///    overshooting.
    ///
    /// 2. **Adaptive (default, fallback)** — Each underrun multiplies
    ///    the prebuffer requirement by +75 % up to a 4× cap. Trades
    ///    fast first-audio for periodic mid-playback pauses that
    ///    grow further apart on subsequent resumes.
    ///
    /// The `expectedAudioDuration`/`estimatedRTF` parameters arrive
    /// via `setLivePreviewEstimate` from the generation coordinator;
    /// `smoothPlaybackEnabled` is the user's `Preferences` toggle
    /// (`AudioService.smoothPlaybackEnabled`, default OFF).
    private static func shouldStartLivePlayback(
        autoplayEnabled: Bool,
        queuedChunks: Int,
        queuedDuration: TimeInterval,
        prebufferThreshold: Int,
        minimumBufferedDuration: TimeInterval,
        finalFileAvailable: Bool,
        underrunCount: Int = 0,
        expectedAudioDuration: TimeInterval? = nil,
        estimatedRTF: Double? = nil,
        smoothPlaybackEnabled: Bool = false
    ) -> Bool {
        guard autoplayEnabled else { return false }
        guard !finalFileAvailable else { return true }

        // Policy 1 — Smooth ON: aggressive predictive prebuffer.
        if smoothPlaybackEnabled,
           let expected = expectedAudioDuration,
           expected > 0,
           let rtf = estimatedRTF,
           rtf > 1.0 {
            let safetyMargin: TimeInterval = 1.0
            let deficit = expected * (rtf - 1.0) + safetyMargin
            // Secondary cap at 60 % of expected audio length keeps
            // Smooth ON usable for high-RTF modes (Voice Cloning
            // ~2.3×, Custom Voice ~2.0× warm). Without this cap the
            // raw `deficit` saturates against the `expected_audio`
            // ceiling for any RTF ≥ 2, which means Smooth ON
            // degenerates into "wait for full generation". The 0.6
            // factor caps user-perceived TTFA at roughly 60 % of
            // audio length × RTF (i.e. the user always starts
            // hearing within ~60 % of the audio's wall-time). May
            // 2026 bench: VC long ON had TTFA 53 s for 41 s of
            // audio under the old cap; this trims to a bounded
            // smooth-ish UX rather than a "no-streaming" outcome.
            let usableCap = expected * 0.6
            let requiredBuffer = min(deficit, usableCap, expected)
            return queuedDuration >= requiredBuffer
        }

        // Policy 1b — Smooth OFF: light predictive prebuffer derived
        // from queue dynamics. Even with Smooth disabled, when an
        // estimated RTF + audio duration are available we can
        // size the prebuffer so the AVAudioEngine queue does NOT
        // run dry mid-playback. The minimum buffer that survives a
        // generation at RTF `r` for audio length `D` is exactly:
        //
        //     B_min = D × (1 - 1/r)        (= D × (r-1)/r)
        //
        // Derivation: playback drains at 1× real-time; generation
        // produces at 1/r real-time; net queue drain = (r-1)/r
        // audio-seconds per wall-second; buffer must last for the
        // full audio length ⇒ B_min = D × (r-1)/r.
        //
        // The pre-Phase 2c-investigation code path here was Policy 2
        // (3 chunks AND 2.25 s), which under-provisioned for any
        // medium+ script: a 21.76 s CV cold gen at observed RTF
        // 1.56× needs B_min = 7.81 s; Policy 2 started at 3.2 s and
        // the buffer drained empty at audio_played_s = 6.7 s,
        // triggering a 5 s `underrun_paused` stall while the engine
        // caught up — repeating later in the script. The user heard
        // these stalls as the live preview "getting interrupted."
        //
        // Cap at 35 % of audio length so TTFA stays usable for very
        // long scripts (TTFA ≈ requiredBuffer × r). For a 60 s clip
        // at RTF 1.56× that ceilings TTFA at 60 × 0.35 × 1.56 ≈ 33 s
        // rather than the unbounded ~22 s of accurate B_min × r.
        // Floor at `minimumBufferedDuration` (2.25 s default) so
        // micro / short scripts still get the existing chunk-burst
        // start-up behavior.
        if let expected = expectedAudioDuration, expected > 0,
           let rtf = estimatedRTF, rtf > 1.0 {
            let exactBuffer = expected * (rtf - 1.0) / rtf
            let usableCap = expected * 0.35
            // Outer `min(..., expected)` ensures `requiredBuffer`
            // never exceeds the audio length itself — important for
            // micro / short scripts where `minimumBufferedDuration`
            // (2.25 s default) would otherwise demand a buffer
            // larger than the entire clip and gate playback on the
            // `finalFileAvailable` short-circuit at the top of this
            // function.
            let requiredBuffer = min(
                expected,
                max(minimumBufferedDuration, min(exactBuffer, usableCap))
            )
            return queuedDuration >= requiredBuffer
        }

        // Policy 2 — fallback adaptive scaling (no estimate).
        // Reached when `setLivePreviewEstimate` was not called or
        // returned 0 / RTF ≤ 1. Keeps the historical chunk-count +
        // duration thresholds with underrun-driven scaling so a
        // session that does drain dry adapts after the first stall.
        let multiplier = min(1.0 + 0.75 * Double(max(underrunCount, 0)), 4.0)
        let scaledChunks = max(
            prebufferThreshold,
            Int((Double(prebufferThreshold) * multiplier).rounded(.up))
        )
        let scaledDuration = minimumBufferedDuration * multiplier

        return queuedChunks >= scaledChunks && queuedDuration >= scaledDuration
    }

    private var playbackMode: PlaybackMode = .none
    private var player: AVAudioPlayer?
    private var liveEngine: AVAudioEngine?
    private var livePlayerNode: AVAudioPlayerNode?
    private var liveScheduledCount = 0
    // Real audio-second queue depth used by `shouldStartLivePlayback`.
    // Bumped on every `scheduleLiveBuffer` and decremented in
    // `handleLiveBufferPlaybackCompletion` (FIFO via
    // `liveBufferDurations`). Distinct from `livePreviewDuration`,
    // which is monotonically-cumulative total received audio used
    // for UI / `final_handoff` audio-length reporting. Audit
    // Finding #3 (May 2026): the prior code path reused
    // `livePreviewDuration` for queue health, which after an
    // underrun read multi-second-stale, and the
    // `shouldStartLivePlayback` predicate would resume playback
    // with a buffer claim of 6+ s while the AVAudioEngine queue
    // actually held one fresh chunk (~0.6 s). Repeated
    // resume/cutoff cycles followed.
    private var liveQueuedAudioSeconds: TimeInterval = 0
    private var liveBufferDurations: [TimeInterval] = []
    private var liveFormat: AVAudioFormat?
    // Live-preview anomaly tracking (DEBUG-only telemetry consumed by
    // `scripts/bench_ui_generation.sh --log-file` for the desktop-UI
    // benchmark anomaly columns: underrun_count, total_stall_ms,
    // ttfa_ms, chunk_jitter_max_ms, etc.). Stripped from release.
    private var liveSessionStartedAt: Date?
    private var liveLastUnderrunStartedAt: Date?
    private var liveTotalStallMS: Int = 0
    private var liveChunkArrivalCount: Int = 0
    private var liveLastChunkArrivedAt: Date?
    private var liveMaxChunkGapMS: Int = 0
    private var liveDecodeFailureCount: Int = 0
    private var liveStreamErrorCount: Int = 0
    // Predictive prebuffer state — set by setLivePreviewEstimate
    // before generation starts, picked up by startLiveSession,
    // cleared at session end. See `shouldStartLivePlayback` policy 1.
    private var pendingExpectedAudioDuration: TimeInterval?
    private var pendingEstimatedRTF: Double?
    private var liveExpectedAudioDuration: TimeInterval?
    private var liveEstimatedRTF: Double?
    private var liveSessionID: String?
    private var liveSessionDirectory: String?
    private var liveFinalFilePath: String?
    private var liveAutoplayEnabled = false
    private var pendingFirstChunkInterval: AppPerformanceSignposts.Interval?
    private var pendingAutoplaySignpost = false
    private var livePlaybackStarted = false
    private var livePreviewDuration: TimeInterval = 0
    private var livePlaybackTimeOffset: TimeInterval = 0
    private var liveUnderrunCount = 0
    private var completedLiveSessionIDs: Set<String> = []
    private var completedLiveSessionOrder: [String] = []
    private let livePreviewConfiguration: LivePreviewConfiguration
    private var chunkObserver: NSObjectProtocol?
    private var chunkCancellable: AnyCancellable?
    private var timer: Timer?

    private func setLivePreviewQueueDepth(_ value: Int) {
        guard livePreviewQueueDepth != value else { return }
        livePreviewQueueDepth = value
    }

    private func setLivePreviewPhase(_ value: LivePreviewPhase) {
        guard livePreviewPhase != value else { return }
        livePreviewPhase = value
    }

    var hasAudio: Bool { currentFilePath != nil || isLiveStream || liveSessionID != nil }
    var canSeek: Bool { playbackMode == .file || liveFinalFilePath != nil }
    var durationDisplayText: String { isLiveStream && liveFinalFilePath == nil ? "Live" : playbackProgress.formattedDuration }
    var activeGeneratePreviewVisibilityState: GeneratePreviewVisibilityState {
        playbackPresentationContext == .generatePreview ? generatePreviewVisibilityState : .hidden
    }

    /// True when the global now-playing rail should be mounted above the studio dock.
    /// Covers Generate-preview preparing/ready states and any Library playback.
    var isShowingNowPlayingRail: Bool {
        if generatePreviewVisibilityState != .hidden { return true }
        return currentFilePath != nil || isLiveStream
    }

    /// Label for the rail's context chip, or nil when no chip should render.
    var nowPlayingContextChipLabel: String? {
        switch playbackPresentationContext {
        case .generatePreview: return "Preview"
        case .library: return "Library"
        case .none: return nil
        }
    }

    /// Non-published pass-through for callers that need the current value without subscribing.
    var currentTime: TimeInterval {
        get { playbackProgress.currentTime }
        set { playbackProgress.currentTime = newValue }
    }

    var duration: TimeInterval {
        get { playbackProgress.duration }
        set { playbackProgress.duration = newValue }
    }

    override init() {
        livePreviewConfiguration = .current()
        super.init()
#if QW_TEST_SUPPORT
        if !Self.isRunningUnderXCTest {
            bindGenerationEventSource()
        }
#else
        bindGenerationEventSource()
#endif
    }

#if QW_TEST_SUPPORT
    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
    }

    func startLivePreviewChunkSubscriptionForTesting() {
        guard chunkCancellable == nil, chunkObserver == nil else { return }
        bindGenerationEventSource()
    }

    static func livePreviewPrebufferThresholdForTesting(
        environment: [String: String] = [:]
    ) -> Int {
        LivePreviewConfiguration.current(environment: environment).prebufferThreshold
    }

    static func livePreviewMinimumBufferedDurationForTesting(
        environment: [String: String] = [:]
    ) -> TimeInterval {
        LivePreviewConfiguration.current(environment: environment).minimumBufferedDuration
    }

    static func shouldStartLivePlaybackForTesting(
        autoplayEnabled: Bool = true,
        queuedChunks: Int,
        queuedDuration: TimeInterval = 10,
        prebufferThreshold: Int,
        minimumBufferedDuration: TimeInterval = 2.25,
        finalFileAvailable: Bool = false,
        underrunCount: Int = 0,
        expectedAudioDuration: TimeInterval? = nil,
        estimatedRTF: Double? = nil,
        smoothPlaybackEnabled: Bool = false
    ) -> Bool {
        shouldStartLivePlayback(
            autoplayEnabled: autoplayEnabled,
            queuedChunks: queuedChunks,
            queuedDuration: queuedDuration,
            prebufferThreshold: prebufferThreshold,
            minimumBufferedDuration: minimumBufferedDuration,
            finalFileAvailable: finalFileAvailable,
            underrunCount: underrunCount,
            expectedAudioDuration: expectedAudioDuration,
            estimatedRTF: estimatedRTF,
            smoothPlaybackEnabled: smoothPlaybackEnabled
        )
    }

    /// Read-only window into the live preview's real audio-second
    /// queue depth (audit Finding #3 fix). Counts the duration of
    /// every scheduled-but-not-yet-fully-played AVAudioEngine
    /// buffer. Returns 0 when live preview is idle.
    var liveQueuedAudioSecondsForTesting: TimeInterval {
        liveQueuedAudioSeconds
    }

    /// Snapshot of the FIFO of buffer audio durations currently in
    /// the AVAudioEngine queue. Head = next-to-complete buffer.
    var liveBufferDurationsForTesting: [TimeInterval] {
        liveBufferDurations
    }

    /// Test hooks for the queue accounting that's normally driven
    /// by `appendLiveChunk` / `handleLiveBufferPlaybackCompletion`.
    /// These let tests verify the FIFO contract without spinning
    /// up a real AVAudioEngine session (which the
    /// `playbackMode == .live` guard inside the production path
    /// requires). They mirror the production state mutations
    /// exactly so the assertions are meaningful for audit
    /// Finding #3 coverage.
    func enqueueLiveBufferDurationForTesting(_ audioSeconds: TimeInterval) {
        liveScheduledCount += 1
        liveBufferDurations.append(audioSeconds)
        liveQueuedAudioSeconds += audioSeconds
        livePreviewDuration += audioSeconds
    }

    @discardableResult
    func drainLiveBufferDurationForTesting() -> TimeInterval? {
        guard !liveBufferDurations.isEmpty else { return nil }
        let drained = liveBufferDurations.removeFirst()
        liveQueuedAudioSeconds = max(0, liveQueuedAudioSeconds - drained)
        liveScheduledCount = max(0, liveScheduledCount - 1)
        return drained
    }

    /// Test hooks for audit Finding #2 coverage. Let tests
    /// construct the "live preview session active, result just
    /// delivered" state and inspect the late-chunk gate without
    /// driving a real AVAudioEngine pipeline.
    func setLiveSessionIDForTesting(_ id: String?) {
        liveSessionID = id
    }

    func setLivePlaybackStartedForTesting(_ started: Bool) {
        livePlaybackStarted = started
    }

    func completedLiveSessionIDsContainsForTesting(_ id: String) -> Bool {
        completedLiveSessionIDs.contains(id)
    }

    func finishLivePlaybackAfterDrainingBuffersForTesting() {
        finishLivePlaybackAfterDrainingBuffers()
    }
#endif

    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
            if let chunkObserver {
                NotificationCenter.default.removeObserver(chunkObserver)
            }
            chunkCancellable?.cancel()
        }
    }

    // MARK: - Playback

    func load(
        filePath: String,
        title: String = "",
        presentationContext: PlaybackPresentationContext = .library
    ) {
        pendingAutoplaySignpost = false
        teardownLivePlayback(clearSession: true)
        stopFilePlayback(clearPlayer: true)

        do {
            try applyFilePlayback(
                filePath: filePath,
                title: title,
                preserveCurrentTime: 0,
                autoPlay: false,
                transitionFromLive: false,
                presentationContext: presentationContext
            )
        } catch {
            clearLoadedAudio()
            resetPresentationState()
            playbackError = error.localizedDescription
        }
    }

    func play() {
        switch playbackMode {
        case .live:
            attemptLivePlay()
        case .file:
            attemptFilePlay()
        case .none:
            break
        }
    }

    func pause() {
        switch playbackMode {
        case .live:
            livePlayerNode?.pause()
            isPlaying = false
            stopTimer()
        case .file:
            player?.pause()
            isPlaying = false
            stopTimer()
        case .none:
            break
        }
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func stop() {
        switch playbackMode {
        case .live:
            stopLivePlayback(resetCurrentTime: true)
        case .file:
            stopFilePlayback(clearPlayer: false)
            currentTime = 0
        case .none:
            break
        }
    }

    func dismiss() {
        pendingAutoplaySignpost = false
        stop()
        teardownLivePlayback(clearSession: true)
        stopFilePlayback(clearPlayer: true)
        clearLoadedAudio()
        playbackError = nil
        playbackMode = .none
        isLiveStream = false
        setLivePreviewQueueDepth(0)
        setLivePreviewPhase(.idle)
        resetPresentationState()
    }

    func seek(to fraction: Double) {
        guard canSeek else { return }

        let clampedFraction = max(0, min(1, fraction))
        let targetTime = clampedFraction * duration

        if playbackMode == .live, liveFinalFilePath != nil {
            switchToFinalFilePlayback(
                preserveCurrentTime: targetTime,
                autoPlay: isPlaying
            )
            return
        }

        guard let player else { return }
        player.currentTime = targetTime
        currentTime = targetTime
    }

    func playFile(
        _ path: String,
        title: String = "",
        isAutoplay: Bool = false,
        presentationContext: PlaybackPresentationContext = .library
    ) {
        load(filePath: path, title: title, presentationContext: presentationContext)
        if isAutoplay {
            pendingAutoplaySignpost = true
        }
        guard player != nil else { return }
        play()
    }

    /// Sets a forecast for the upcoming live-preview session — used by
    /// the smooth-playback policy in `shouldStartLivePlayback` to size
    /// the prebuffer so playback runs through to completion without
    /// underruns. Call from the generation coordinator just before
    /// triggering generation; the values are picked up by
    /// `startLiveSession` when the first chunk arrives, then cleared.
    /// Pass `nil` for either to opt out and fall back to the adaptive
    /// scaling policy.
    func setLivePreviewEstimate(audioDuration: TimeInterval?, rtf: Double?) {
        pendingExpectedAudioDuration = audioDuration
        pendingEstimatedRTF = rtf
    }

    func prepareStreamingPreview(title: String, shouldAutoPlay: Bool) {
        teardownLivePlayback(clearSession: true)
        stopFilePlayback(clearPlayer: true)
        clearPendingFirstChunkInterval()

        playbackMode = .live
        liveSessionID = "pending-\(UUID().uuidString)"
        liveSessionDirectory = nil
        liveFinalFilePath = nil
        liveAutoplayEnabled = shouldAutoPlay
        pendingAutoplaySignpost = shouldAutoPlay
        pendingFirstChunkInterval = AppPerformanceSignposts.begin("Preview To First Chunk")
        liveScheduledCount = 0
        livePlaybackStarted = false
        livePreviewDuration = 0
        livePlaybackTimeOffset = 0
        liveUnderrunCount = 0
        liveFormat = nil
        currentTitle = title
        currentFilePath = nil
        duration = 0
        currentTime = 0
        waveformSamples = []
        playbackError = nil
        isPlaying = false
        isLiveStream = true
        setLivePreviewQueueDepth(0)
        setLivePreviewPhase(.buffering)
        playbackPresentationContext = .generatePreview
        generatePreviewVisibilityState = .preparing
        // Pre-warm the AVAudioEngine + player node + audio graph with
        // the engine's expected output format (24 kHz Int16 mono per
        // the Qwen3-TTS streaming contract). The cross-layer probe
        // bench (May 2026) showed `t2u_max_ms` paid 110-220 ms on the
        // first chunk specifically because `configureLiveEngine` ran
        // lazily there — the cost is engine allocation +
        // `engine.attach` + `engine.connect` + mainMixerNode access,
        // all of which can run safely before any audio arrives.
        // `configureLiveEngine` is idempotent against an identical
        // format so the chunk-arrival site is a cheap no-op when the
        // format matches; if it ever mismatches (different model or
        // contract change) the chunk site falls back to reconfiguring.
        if let prewarmFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ) {
            configureLiveEngine(with: prewarmFormat)
        }
        CustomVoiceUIPerformanceTrace.markOnce(.previewSetupFinished)
    }

    func completeStreamingPreview(result: PlaybackGenerationResult, title: String, shouldAutoPlay: Bool) {
        guard result.usedStreaming else {
            if shouldAutoPlay {
                playFile(
                    result.audioPath,
                    title: title,
                    isAutoplay: true,
                    presentationContext: .generatePreview
                )
            }
            return
        }

        CustomVoiceUIPerformanceTrace.markOnce(
            .finalHandoffStarted,
            metadata: [
                "used_streaming": "true",
            ],
            metrics: [
                "duration_ms": Int(result.durationSeconds * 1_000),
            ]
        )
        currentTitle = title
        currentFilePath = result.audioPath
        liveFinalFilePath = result.audioPath
        // Audit Finding #2 — DO NOT add `liveSessionID` to
        // `completedLiveSessionIDs` here. Two independent XPC paths
        // race on MainActor: the awaited generation result (this
        // function's caller) and the chunk broker
        // (`Task { @MainActor in subject.send }` inside
        // `GenerationChunkBroker.publish`). If the result-channel
        // continuation runs first and we record the session ID
        // immediately, any chunk still queued on the broker is
        // rejected by the guard at the top of
        // `handleGenerationChunk` and silently dropped. Defer the
        // record to the actual drain points below
        // (`finishLivePlaybackAfterDrainingBuffers` for the
        // live-still-playing path, the `if` block below for the
        // immediate-handoff path, and `teardownLivePlayback` for
        // dismissed sessions). All three call
        // `recordCompletedLiveSessionID` which is idempotent
        // (`Set.insert(_:).inserted`), so multiple invocations
        // from different paths are safe.
        if let streamSessionDirectory = result.streamSessionDirectory {
            liveSessionDirectory = streamSessionDirectory
        }
        duration = max(duration, result.durationSeconds)

        // Only transition immediately if live playback never started or all
        // buffers have already drained. Otherwise the existing buffer-drain
        // mechanism (handleLiveBufferPlaybackCompletion -> finishLivePlaybackAfterDrainingBuffers)
        // keeps playback moving from the heard preview position into the final file.
        if !livePlaybackStarted || liveScheduledCount == 0 {
            // Immediate-handoff branch: live preview is over (never
            // started or already drained). Any chunk arriving from
            // the broker now is genuinely stale. Record the session
            // as completed so the `handleGenerationChunk` guard
            // drops it.
            recordCompletedLiveSessionID(liveSessionID)
            let handoff = Self.finalPlaybackHandoff(
                heardLivePreview: livePlaybackStarted,
                currentTime: currentTime,
                previewDuration: livePreviewDuration,
                duration: duration,
                autoPlayEnabled: shouldAutoPlay
            )
            switchToFinalFilePlayback(
                preserveCurrentTime: handoff.preserveCurrentTime,
                autoPlay: handoff.shouldAutoPlay
            )
        }
        // Else: live preview still draining. Late chunks that
        // arrive between now and the drain are appended naturally
        // by `appendLiveChunk` (the session ID is NOT in
        // `completedLiveSessionIDs` yet, so the guard lets them
        // through). When the queue drains and
        // `finishLivePlaybackAfterDrainingBuffers` fires, the
        // session ID is recorded there.
    }

    func abortLivePreviewIfNeeded() {
        guard playbackMode == .live || liveSessionID != nil else { return }
        dismiss()
    }

    // MARK: - Notifications

    private struct ChunkInfo: Sendable {
        let requestID: Int
        let title: String
        let chunkPath: String?
        let previewAudio: StreamingAudioChunk?
        let sessionDirectory: String?
        let cumulativeDuration: Double?
        /// Engine-assigned monotonic per-generation seq. Carries through
        /// to `[LivePreview] event=chunk_arrived engine_seq=N` and the
        /// new `[Probe.UI] event=chunk_consumed seq=N` so the bench
        /// helper can join with `[Probe.Engine]` / `[Probe.Transport]`.
        let probeSeq: Int?
    }

    private func bindGenerationEventSource() {
#if canImport(QwenVoiceNative)
        // The broker is `@MainActor` and its `publish(_:)` always
        // sends from a `Task { @MainActor in ... }`, so the sink
        // already runs on the MainActor. Dropping the previous
        // `.receive(on: DispatchQueue.main)` saves the second
        // scheduling hop on every chunk; the cross-layer probe
        // bench (May 2026) showed this layer added 20–60 ms to
        // first-chunk `t2u_max_ms`.
        chunkCancellable = GenerationChunkBroker.shared.publisher
            .sink { [weak self] event in
                guard let self,
                      let requestID = event.requestID,
                      let title = event.title,
                      event.chunkPath != nil || event.previewAudio != nil else { return }
                let chunk = ChunkInfo(
                    requestID: requestID,
                    title: title,
                    chunkPath: event.chunkPath,
                    previewAudio: event.previewAudio,
                    sessionDirectory: event.streamSessionDirectory,
                    cumulativeDuration: event.cumulativeDurationSeconds,
                    probeSeq: event.probeMetadata?.seq
                )
                self.handleGenerationChunk(chunk)
            }
#else
        chunkObserver = NotificationCenter.default.addObserver(
            forName: .generationChunkReceived,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let requestID = userInfo["requestID"] as? Int,
                  let title = userInfo["title"] as? String,
                  let chunkPath = userInfo["chunkPath"] as? String
            else { return }
            let chunk = ChunkInfo(
                requestID: requestID,
                title: title,
                chunkPath: chunkPath,
                previewAudio: nil,
                sessionDirectory: userInfo["streamSessionDirectory"] as? String,
                cumulativeDuration: userInfo["cumulativeDurationSeconds"] as? Double,
                probeSeq: userInfo["probeSeq"] as? Int
            )
            Task { @MainActor [weak self] in
                self?.handleGenerationChunk(chunk)
            }
        }
#endif
    }

    private func handleGenerationChunk(_ chunk: ChunkInfo) {
        let sessionID = String(chunk.requestID)
        guard !completedLiveSessionIDs.contains(sessionID) else { return }
        CustomVoiceUIPerformanceTrace.markOnce(
            .firstLiveChunkEvent,
            metadata: [
                "has_chunk_path": chunk.chunkPath == nil ? "false" : "true",
                "has_preview_audio": chunk.previewAudio == nil ? "false" : "true",
                "has_session_directory": chunk.sessionDirectory == nil ? "false" : "true",
            ],
            metrics: [
                "request_id": chunk.requestID,
            ]
        )

        let sessionDirectory = chunk.sessionDirectory
        let cumulativeDuration = chunk.cumulativeDuration

        if liveSessionID != sessionID {
            startLiveSession(
                id: sessionID,
                title: chunk.title,
                sessionDirectory: sessionDirectory,
                autoPlay: AudioService.shouldAutoPlay
            )
        }

        if let previewAudio = chunk.previewAudio {
            appendLiveChunk(
                previewAudio,
                cumulativeDuration: cumulativeDuration,
                probeSeq: chunk.probeSeq
            )
        } else if let chunkPath = chunk.chunkPath {
            appendLiveChunk(
                from: URL(fileURLWithPath: chunkPath),
                cumulativeDuration: cumulativeDuration,
                probeSeq: chunk.probeSeq
            )
        }
    }

    // MARK: - Live Playback

    private func recordCompletedLiveSessionID(_ sessionID: String?) {
        guard let sessionID, !sessionID.hasPrefix("pending-") else { return }
        guard completedLiveSessionIDs.insert(sessionID).inserted else { return }
        completedLiveSessionOrder.append(sessionID)

        let maximumRetainedSessionIDs = 16
        while completedLiveSessionOrder.count > maximumRetainedSessionIDs {
            let expiredID = completedLiveSessionOrder.removeFirst()
            completedLiveSessionIDs.remove(expiredID)
        }
    }

    private func startLiveSession(id: String, title: String, sessionDirectory: String?, autoPlay: Bool) {
        teardownLivePlayback(clearSession: true)
        stopFilePlayback(clearPlayer: true)

        playbackMode = .live
        liveSessionID = id
        liveSessionDirectory = sessionDirectory
        liveFinalFilePath = nil
        liveAutoplayEnabled = autoPlay
        liveScheduledCount = 0
        liveQueuedAudioSeconds = 0
        liveBufferDurations.removeAll(keepingCapacity: true)
        livePlaybackStarted = false
        livePreviewDuration = 0
        livePlaybackTimeOffset = 0
        liveUnderrunCount = 0
        liveFormat = nil
        // Anomaly-tracking reset (paired with teardownLivePlayback).
        liveSessionStartedAt = Date()
        liveLastUnderrunStartedAt = nil
        liveTotalStallMS = 0
        liveChunkArrivalCount = 0
        liveLastChunkArrivedAt = nil
        liveMaxChunkGapMS = 0
        liveDecodeFailureCount = 0
        liveStreamErrorCount = 0
        // Predictive prebuffer estimate handoff: pending values
        // captured pre-generation become the active session's
        // estimate, then are cleared so a future session that arrives
        // without a fresh estimate falls back to adaptive scaling.
        liveExpectedAudioDuration = pendingExpectedAudioDuration
        liveEstimatedRTF = pendingEstimatedRTF
        pendingExpectedAudioDuration = nil
        pendingEstimatedRTF = nil
        currentTitle = title
        currentFilePath = nil
        duration = 0
        currentTime = 0
        waveformSamples = []
        playbackError = nil
        isPlaying = false
        isLiveStream = true
        setLivePreviewQueueDepth(0)
        setLivePreviewPhase(.buffering)
        playbackPresentationContext = .generatePreview
        generatePreviewVisibilityState = .preparing
        logLivePreviewEvent("session_start", ["session": id])
    }

    private func appendLiveChunk(from url: URL, cumulativeDuration: TimeInterval?, probeSeq: Int?) {
        LivePreviewDiagnostics.logChunkEvent(
            "appendLiveChunk.enter",
            viewModel: self,
            url: url
        )
        guard let (buffer, fileFormat) = loadPCMBuffer(from: url) else {
            LivePreviewDiagnostics.logChunkEvent(
                "appendLiveChunk.decode_failed",
                viewModel: self,
                url: url
            )
            liveDecodeFailureCount += 1
            logLivePreviewEvent("decode_failed", ["branch": "file"])
            playbackError = "Live audio preview could not decode the latest chunk."
            return
        }
        CustomVoiceUIPerformanceTrace.markOnce(
            .firstLiveChunkDecoded,
            metadata: [
                "source": "file",
            ],
            metrics: [
                "frames": Int(buffer.frameLength),
                "sample_rate": Int(fileFormat.sampleRate),
            ]
        )

        if liveEngine == nil || livePlayerNode == nil {
            configureLiveEngine(with: fileFormat)
        }

        let chunkAudioSeconds = TimeInterval(buffer.frameLength) / fileFormat.sampleRate
        liveScheduledCount += 1
        liveBufferDurations.append(chunkAudioSeconds)
        liveQueuedAudioSeconds += chunkAudioSeconds
        setLivePreviewQueueDepth(liveScheduledCount)
        scheduleLiveBuffer(buffer)
        CustomVoiceUIPerformanceTrace.markOnce(
            .firstLiveChunkScheduled,
            metrics: [
                "queue_depth": liveScheduledCount,
            ]
        )

        livePreviewDuration = cumulativeDuration
            ?? (livePreviewDuration + chunkAudioSeconds)
        duration = max(duration, livePreviewDuration)
        markGeneratePreviewReadyIfNeeded()
        if let pendingFirstChunkInterval {
            AppPerformanceSignposts.end(pendingFirstChunkInterval)
            AppPerformanceSignposts.emit("First Chunk Received")
            self.pendingFirstChunkInterval = nil
        }
        recordChunkArrivalForTrace(audioSeconds: chunkAudioSeconds, probeSeq: probeSeq)

        if Self.shouldStartLivePlayback(
            autoplayEnabled: liveAutoplayEnabled,
            queuedChunks: liveScheduledCount,
            queuedDuration: liveQueuedAudioSeconds,
            prebufferThreshold: livePreviewConfiguration.prebufferThreshold,
            minimumBufferedDuration: livePreviewConfiguration.minimumBufferedDuration,
            finalFileAvailable: liveFinalFilePath != nil,
            underrunCount: liveUnderrunCount,
            expectedAudioDuration: liveExpectedAudioDuration,
            estimatedRTF: liveEstimatedRTF,
            smoothPlaybackEnabled: AudioService.smoothPlaybackEnabled
        ) {
            attemptLivePlay()
        } else {
            setLivePreviewPhase(.buffering)
        }

        LivePreviewDiagnostics.logChunkEvent(
            "appendLiveChunk.delete",
            viewModel: self,
            url: url
        )
        try? FileManager.default.removeItem(at: url)
        cleanupLiveSessionDirectoryIfEmpty()
    }

    private func appendLiveChunk(_ previewAudio: StreamingAudioChunk, cumulativeDuration: TimeInterval?, probeSeq: Int?) {
        guard let (buffer, format) = makePCMBuffer(from: previewAudio) else {
            liveDecodeFailureCount += 1
            logLivePreviewEvent("decode_failed", ["branch": "inline"])
            playbackError = "Live audio preview could not decode the latest chunk."
            return
        }
        CustomVoiceUIPerformanceTrace.markOnce(
            .firstLiveChunkDecoded,
            metadata: [
                "source": "inline",
            ],
            metrics: [
                "frames": Int(buffer.frameLength),
                "sample_rate": Int(format.sampleRate),
            ]
        )

        if liveEngine == nil || livePlayerNode == nil {
            configureLiveEngine(with: format)
        }

        let chunkAudioSeconds = TimeInterval(buffer.frameLength) / format.sampleRate
        liveScheduledCount += 1
        liveBufferDurations.append(chunkAudioSeconds)
        liveQueuedAudioSeconds += chunkAudioSeconds
        setLivePreviewQueueDepth(liveScheduledCount)
        scheduleLiveBuffer(buffer)
        CustomVoiceUIPerformanceTrace.markOnce(
            .firstLiveChunkScheduled,
            metrics: [
                "queue_depth": liveScheduledCount,
            ]
        )

        livePreviewDuration = cumulativeDuration
            ?? (livePreviewDuration + chunkAudioSeconds)
        duration = max(duration, livePreviewDuration)
        markGeneratePreviewReadyIfNeeded()
        if let pendingFirstChunkInterval {
            AppPerformanceSignposts.end(pendingFirstChunkInterval)
            AppPerformanceSignposts.emit("First Chunk Received")
            self.pendingFirstChunkInterval = nil
        }
        recordChunkArrivalForTrace(audioSeconds: chunkAudioSeconds, probeSeq: probeSeq)

        if Self.shouldStartLivePlayback(
            autoplayEnabled: liveAutoplayEnabled,
            queuedChunks: liveScheduledCount,
            queuedDuration: liveQueuedAudioSeconds,
            prebufferThreshold: livePreviewConfiguration.prebufferThreshold,
            minimumBufferedDuration: livePreviewConfiguration.minimumBufferedDuration,
            finalFileAvailable: liveFinalFilePath != nil,
            underrunCount: liveUnderrunCount,
            expectedAudioDuration: liveExpectedAudioDuration,
            estimatedRTF: liveEstimatedRTF,
            smoothPlaybackEnabled: AudioService.smoothPlaybackEnabled
        ) {
            attemptLivePlay()
        } else {
            setLivePreviewPhase(.buffering)
        }
    }

    /// Tracks chunk arrival timestamps + max inter-chunk gap for the
    /// DEBUG-only `[LivePreview]` trace. Emits the `chunk_arrived`
    /// event with the gap from the previous chunk in milliseconds.
    private func recordChunkArrivalForTrace(audioSeconds: TimeInterval, probeSeq: Int?) {
        liveChunkArrivalCount += 1
        let now = Date()
        let gapMS: Int
        if let last = liveLastChunkArrivedAt {
            gapMS = Int(now.timeIntervalSince(last) * 1000.0)
            liveMaxChunkGapMS = max(liveMaxChunkGapMS, gapMS)
        } else {
            gapMS = 0
        }
        liveLastChunkArrivedAt = now
        // Existing UI-side trace; gains `engine_seq` for cross-correlation.
        logLivePreviewEvent("chunk_arrived", [
            "seq": "\(liveChunkArrivalCount)",
            "engine_seq": probeSeq.map { "\($0)" } ?? "",
            "audio_s": String(format: "%.3f", audioSeconds),
            "cumulative_s": String(format: "%.3f", livePreviewDuration),
            "queue_depth": "\(liveScheduledCount)",
            "gap_ms": "\(gapMS)",
        ])
        // Cross-layer probe (UI side). Joined offline by the bench
        // helper with `[Probe.Engine]` / `[Probe.Transport]` on `seq`
        // to compute per-chunk e2e + transport-to-ui latencies.
        if let probeSeq {
            logProbeEvent("UI", event: "chunk_consumed", details: [
                "seq": "\(probeSeq)",
                "ui_at_ms": String(format: "%.3f", now.timeIntervalSince1970 * 1000.0),
            ])
        }
    }

    private func attemptLivePlay() {
        if liveFinalFilePath != nil, !isPlaying {
            let handoff = Self.finalPlaybackHandoff(
                heardLivePreview: livePlaybackStarted,
                currentTime: currentTime,
                previewDuration: livePreviewDuration,
                duration: duration,
                autoPlayEnabled: liveAutoplayEnabled
            )
            switchToFinalFilePlayback(
                preserveCurrentTime: handoff.preserveCurrentTime,
                autoPlay: handoff.shouldAutoPlay
            )
            return
        }

        guard let liveEngine, let livePlayerNode else { return }

        let wasResume = livePlaybackStarted
        do {
            if !liveEngine.isRunning {
                try liveEngine.start()
            }
            if !livePlayerNode.isPlaying {
                if livePlaybackStarted {
                    livePlaybackTimeOffset = currentTime
                    scheduleLeadingSilence()
                }
                livePlayerNode.play()
                livePlaybackStarted = true
            }
            isPlaying = true
            setLivePreviewPhase(.playing)
            playbackError = nil
            startTimer()
            consumeAutoplaySignpostIfNeeded()

            // Trace: distinguish first-time start (playback_started) from
            // post-underrun resume (underrun_resumed). Each path captures
            // a different latency: TTFA on first start, stall_ms on resume.
            if !wasResume {
                let ttfaMS: Int
                if let sessionStart = liveSessionStartedAt {
                    ttfaMS = Int(Date().timeIntervalSince(sessionStart) * 1000.0)
                } else {
                    ttfaMS = 0
                }
                logLivePreviewEvent("playback_started", [
                    "ttfa_ms": "\(ttfaMS)",
                    "queue_depth": "\(liveScheduledCount)",
                ])
            } else if let underrunStart = liveLastUnderrunStartedAt {
                let stallMS = Int(Date().timeIntervalSince(underrunStart) * 1000.0)
                liveTotalStallMS += stallMS
                liveLastUnderrunStartedAt = nil
                logLivePreviewEvent("underrun_resumed", [
                    "stall_ms": "\(stallMS)",
                    "queue_depth": "\(liveScheduledCount)",
                ])
            }
        } catch {
            playbackError = "Playback could not start."
        }
    }

    private func configureLiveEngine(with format: AVAudioFormat) {
        // Idempotent: if a prior pre-warm or chunk-arrival call already
        // configured the engine with this exact format, skip the
        // expensive allocation + attach + connect path. This is what
        // makes the `prepareStreamingPreview` pre-warm a free win at
        // the first chunk's arrival site.
        if let existingEngine = liveEngine,
           let existingNode = livePlayerNode,
           let existingFormat = liveFormat,
           existingFormat == format {
            // Belt-and-suspenders: the engine could have been torn
            // down between pre-warm and chunk arrival (e.g. a panic
            // path called `engine.stop()`); confirm it's still running
            // a valid graph before reusing.
            if existingEngine.attachedNodes.contains(existingNode) {
                return
            }
        }

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        liveEngine = engine
        livePlayerNode = playerNode
        liveFormat = format
    }

    private func scheduleLiveBuffer(_ buffer: AVAudioPCMBuffer) {
        livePlayerNode?.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            // AVFAudio invokes completion handlers on its own queue, so keep
            // the callback nonisolated and hop back to MainActor explicitly.
            Task { @MainActor [weak self] in
                self?.handleLiveBufferPlaybackCompletion()
            }
        }
    }

    private func scheduleLeadingSilence() {
        guard let format = liveFormat, let livePlayerNode else { return }
        let silenceFrames: AVAudioFrameCount = 1024
        guard let silentBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: silenceFrames) else { return }
        silentBuffer.frameLength = silenceFrames
        // AVAudioPCMBuffer is zero-filled on creation
        livePlayerNode.scheduleBuffer(silentBuffer)
    }

    private func handleLiveBufferPlaybackCompletion() {
        guard playbackMode == .live else { return }
        liveScheduledCount = max(0, liveScheduledCount - 1)
        // Decrement the audio-second queue depth in lock-step with
        // `liveScheduledCount`. AVAudioEngine plays scheduled
        // buffers FIFO, so the head of `liveBufferDurations` is
        // the buffer that just completed (`.dataPlayedBack`).
        if !liveBufferDurations.isEmpty {
            let drained = liveBufferDurations.removeFirst()
            liveQueuedAudioSeconds = max(0, liveQueuedAudioSeconds - drained)
        }
        setLivePreviewQueueDepth(liveScheduledCount)
        if liveScheduledCount > 0 {
            setLivePreviewPhase(isPlaying ? .playing : .draining)
        }
        if liveScheduledCount == 0, liveFinalFilePath != nil {
            setLivePreviewPhase(.finalizing)
            finishLivePlaybackAfterDrainingBuffers()
        } else if liveScheduledCount == 0 {
            liveUnderrunCount += 1
            livePlayerNode?.pause()
            isPlaying = false
            stopTimer()
            setLivePreviewPhase(.buffering)
            liveLastUnderrunStartedAt = Date()
            logLivePreviewEvent("underrun_paused", [
                "underrun_n": "\(liveUnderrunCount)",
                "audio_played_s": String(format: "%.3f", currentTime),
            ])
        }
    }

    private func finishLivePlaybackAfterDrainingBuffers() {
        // Audit Finding #2 — record the session as completed at
        // drain time, not when the result was delivered to
        // `completeStreamingPreview`. By now, all scheduled
        // buffers have played out (`.dataPlayedBack` callback for
        // the last buffer fired immediately before this function
        // was called); any chunk arriving now is truly stale.
        recordCompletedLiveSessionID(liveSessionID)

        let heardTime = max(currentTime, livePreviewDuration)
        stopLivePlayback(resetCurrentTime: false)
        currentTime = heardTime

        if liveFinalFilePath != nil {
            let handoff = Self.finalPlaybackHandoff(
                heardLivePreview: livePlaybackStarted,
                currentTime: currentTime,
                previewDuration: livePreviewDuration,
                duration: duration,
                autoPlayEnabled: liveAutoplayEnabled
            )
            switchToFinalFilePlayback(
                preserveCurrentTime: handoff.preserveCurrentTime,
                autoPlay: handoff.shouldAutoPlay
            )
        }
    }

    private func switchToFinalFilePlayback(preserveCurrentTime: TimeInterval, autoPlay: Bool) {
        guard let finalFilePath = liveFinalFilePath else { return }
        setLivePreviewPhase(.finalizing)
        CustomVoiceUIPerformanceTrace.markOnce(.finalHandoffStarted)

        // Capture preview vs final-file duration delta for the
        // [LivePreview] trace BEFORE applyFilePlayback resets the
        // live-* state. Reading file duration via AVAudioFile is
        // cheap (header-only) and matches the bench helper's
        // `afinfo` source of truth.
        let previewAudio = livePreviewDuration
        let finalAudio: TimeInterval = (try? AVAudioFile(forReading: URL(fileURLWithPath: finalFilePath)))
            .map { Double($0.length) / max($0.processingFormat.sampleRate, 1) } ?? 0
        if finalAudio > 0 {
            logLivePreviewEvent("final_handoff", [
                "preview_audio_s": String(format: "%.3f", previewAudio),
                "final_audio_s": String(format: "%.3f", finalAudio),
                "delta_s": String(format: "%.3f", finalAudio - previewAudio),
            ])
        }
        emitPreviewCompletedTrace(totalAudioSeconds: max(previewAudio, finalAudio))

        do {
            try applyFilePlayback(
                filePath: finalFilePath,
                title: currentTitle,
                preserveCurrentTime: preserveCurrentTime,
                autoPlay: autoPlay,
                transitionFromLive: true,
                presentationContext: playbackPresentationContext
            )
        } catch {
            playbackError = error.localizedDescription
        }
    }

    /// Emits the `preview_completed` summary line at the end of a live
    /// session. Idempotent — guarded by `liveSessionStartedAt` so a
    /// second handoff or teardown doesn't emit twice.
    private func emitPreviewCompletedTrace(totalAudioSeconds: TimeInterval) {
        guard liveSessionStartedAt != nil else { return }
        logLivePreviewEvent("preview_completed", [
            "total_audio_s": String(format: "%.3f", totalAudioSeconds),
            "underruns": "\(liveUnderrunCount)",
            "total_stall_ms": "\(liveTotalStallMS)",
            "decode_fails": "\(liveDecodeFailureCount)",
            "stream_errors": "\(liveStreamErrorCount)",
            "max_chunk_gap_ms": "\(liveMaxChunkGapMS)",
            "chunk_count": "\(liveChunkArrivalCount)",
        ])
        liveSessionStartedAt = nil
    }

    private func teardownLivePlayback(clearSession: Bool) {
        // Audit Finding #2 — defensive record. If teardown is
        // reached without a completion-handoff path having fired
        // (user-driven dismiss, error-path teardown, etc.), the
        // session ID still belongs in `completedLiveSessionIDs` so
        // a later straggler chunk doesn't accidentally restart a
        // new live session via `startLiveSession`'s
        // `liveSessionID != sessionID` branch. Idempotent.
        recordCompletedLiveSessionID(liveSessionID)

        // Emit the preview_completed summary BEFORE we wipe live-*
        // counters. emitPreviewCompletedTrace is idempotent (no-op when
        // already fired by a successful handoff), so this only fires
        // for aborted / dismissed previews.
        emitPreviewCompletedTrace(totalAudioSeconds: livePreviewDuration)
        stopLivePlayback(resetCurrentTime: true)
        liveScheduledCount = 0
        liveQueuedAudioSeconds = 0
        liveBufferDurations.removeAll(keepingCapacity: true)
        livePlaybackStarted = false
        livePreviewDuration = 0
        livePlaybackTimeOffset = 0
        liveUnderrunCount = 0
        liveFormat = nil
        liveExpectedAudioDuration = nil
        liveEstimatedRTF = nil
        setLivePreviewQueueDepth(0)
        clearPendingFirstChunkInterval()

        if clearSession {
            cleanupLiveSessionDirectory()
            liveSessionID = nil
            liveSessionDirectory = nil
            liveFinalFilePath = nil
            liveAutoplayEnabled = false
            isLiveStream = false
            setLivePreviewPhase(.idle)
        }
    }

    private func stopLivePlayback(resetCurrentTime: Bool) {
        livePlayerNode?.stop()
        liveEngine?.stop()
        liveEngine?.reset()
        isPlaying = false
        stopTimer()
        if resetCurrentTime {
            currentTime = 0
        }
    }

    private func cleanupLiveSessionDirectoryIfEmpty() {
        guard liveFinalFilePath != nil else { return }
        guard let liveSessionDirectory else { return }
        let directoryURL = URL(fileURLWithPath: liveSessionDirectory, isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        if contents.isEmpty {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    private func cleanupLiveSessionDirectory() {
        guard let liveSessionDirectory else { return }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: liveSessionDirectory, isDirectory: true))
    }

    private func loadPCMBuffer(from url: URL) -> (AVAudioPCMBuffer, AVAudioFormat)? {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            LivePreviewDiagnostics.logDecodeFailure(
                "AVAudioFile(forReading:)",
                viewModel: self,
                url: url,
                error: error
            )
            return nil
        }
        let format = audioFile.processingFormat
        let frameCapacity = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            LivePreviewDiagnostics.logDecodeFailure(
                "AVAudioPCMBuffer(frameCapacity: \(frameCapacity))",
                viewModel: self,
                url: url,
                error: nil
            )
            return nil
        }

        do {
            try audioFile.read(into: buffer)
            return (buffer, format)
        } catch {
            LivePreviewDiagnostics.logDecodeFailure(
                "audioFile.read(into:)",
                viewModel: self,
                url: url,
                error: error
            )
            return nil
        }
    }

    private func makePCMBuffer(from previewAudio: StreamingAudioChunk) -> (AVAudioPCMBuffer, AVAudioFormat)? {
        guard previewAudio.frameCount > 0,
              previewAudio.pcm16LE.count >= previewAudio.frameCount * MemoryLayout<Int16>.stride,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: Double(previewAudio.sampleRate),
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(previewAudio.frameCount)
              ),
              let channelData = buffer.int16ChannelData?[0] else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(previewAudio.frameCount)
        previewAudio.pcm16LE.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            channelData.update(from: baseAddress, count: previewAudio.frameCount)
        }
        return (buffer, format)
    }

    private func applyFilePlayback(
        filePath: String,
        title: String,
        preserveCurrentTime: TimeInterval,
        autoPlay: Bool,
        transitionFromLive: Bool,
        presentationContext: PlaybackPresentationContext
    ) throws {
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw NSError(domain: "AudioPlayerViewModel", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Audio file not found."
            ])
        }

        let audioPlayer = try AVAudioPlayer(contentsOf: url)
        audioPlayer.delegate = self
        audioPlayer.prepareToPlay()

        if transitionFromLive {
            stopLivePlayback(resetCurrentTime: false)
            liveScheduledCount = 0
            livePlaybackStarted = false
            livePreviewDuration = 0
            livePlaybackTimeOffset = 0
            liveUnderrunCount = 0
            liveFormat = nil
            cleanupLiveSessionDirectory()
            liveSessionID = nil
            liveSessionDirectory = nil
            liveFinalFilePath = nil
            liveAutoplayEnabled = false
        } else {
            teardownLivePlayback(clearSession: true)
        }

        stopFilePlayback(clearPlayer: true)

        player = audioPlayer
        playbackMode = .file
        currentFilePath = filePath
        currentTitle = title.isEmpty ? url.lastPathComponent : title
        duration = audioPlayer.duration
        let clampedTime = min(max(preserveCurrentTime, 0), audioPlayer.duration)
        audioPlayer.currentTime = clampedTime
        currentTime = clampedTime
        playbackError = nil
        isLiveStream = false
        setLivePreviewQueueDepth(0)
        setLivePreviewPhase(.idle)
        playbackPresentationContext = presentationContext
        generatePreviewVisibilityState = presentationContext == .generatePreview ? .ready : .hidden
        extractWaveform(from: url, replace: true)
        if presentationContext == .generatePreview {
            CustomVoiceUIPerformanceTrace.markOnce(
                .finalPlayerLoaded,
                metadata: [
                    "transition_from_live": transitionFromLive ? "true" : "false",
                    "auto_play": autoPlay ? "true" : "false",
                ],
                metrics: [
                    "duration_ms": Int(audioPlayer.duration * 1_000),
                ]
            )
        }

        if autoPlay {
            attemptFilePlay()
        }
    }

    // MARK: - File Playback

    private func stopFilePlayback(clearPlayer: Bool) {
        player?.stop()
        if clearPlayer {
            player = nil
        }
        isPlaying = false
        stopTimer()
    }

    private func attemptFilePlay() {
        guard var player else { return }

        if player.currentTime >= player.duration, player.duration > 0 {
            player.currentTime = 0
        }

        if player.play() {
            playbackError = nil
            isPlaying = true
            currentTime = player.currentTime
            startTimer()
            consumeAutoplaySignpostIfNeeded()
            return
        }

        guard let path = currentFilePath else {
            playbackError = "Playback could not start."
            return
        }

        let url = URL(fileURLWithPath: path)
        guard let rebuilt = try? AVAudioPlayer(contentsOf: url) else {
            playbackError = "Playback could not start."
            return
        }
        rebuilt.delegate = self
        rebuilt.prepareToPlay()
        self.player = rebuilt
        player = rebuilt

        if player.play() {
            playbackError = nil
            isPlaying = true
            currentTime = player.currentTime
            startTimer()
            consumeAutoplaySignpostIfNeeded()
        } else {
            playbackError = "Playback could not start."
        }
    }

    private func clearPendingFirstChunkInterval() {
        guard let pendingFirstChunkInterval else { return }
        AppPerformanceSignposts.end(pendingFirstChunkInterval)
        self.pendingFirstChunkInterval = nil
    }

    private func consumeAutoplaySignpostIfNeeded() {
        guard pendingAutoplaySignpost else { return }
        pendingAutoplaySignpost = false
        AppPerformanceSignposts.emit("Autoplay Start")
    }

    private func clearLoadedAudio() {
        currentFilePath = nil
        currentTitle = ""
        duration = 0
        currentTime = 0
        waveformSamples = []
    }

    private func markGeneratePreviewReadyIfNeeded() {
        guard playbackPresentationContext == .generatePreview else { return }
        guard generatePreviewVisibilityState != .ready else { return }
        generatePreviewVisibilityState = .ready
    }

    private func resetPresentationState() {
        playbackPresentationContext = .none
        generatePreviewVisibilityState = .hidden
    }

    static func finalPlaybackHandoff(
        heardLivePreview: Bool,
        currentTime: TimeInterval,
        previewDuration: TimeInterval = 0,
        duration: TimeInterval,
        autoPlayEnabled: Bool
    ) -> FinalPlaybackHandoff {
        guard heardLivePreview else {
            return FinalPlaybackHandoff(
                preserveCurrentTime: 0,
                shouldAutoPlay: autoPlayEnabled
            )
        }

        guard autoPlayEnabled else {
            return FinalPlaybackHandoff(
                preserveCurrentTime: 0,
                shouldAutoPlay: false
            )
        }

        let safeDuration = max(duration, 0)
        let heardTime = max(currentTime, previewDuration)
        let safeCurrentTime = min(max(heardTime, 0), safeDuration)
        let replayThreshold: TimeInterval = 0.12
        guard safeDuration > replayThreshold,
              safeCurrentTime < safeDuration - replayThreshold else {
            return FinalPlaybackHandoff(
                preserveCurrentTime: 0,
                shouldAutoPlay: false
            )
        }

        return FinalPlaybackHandoff(
            preserveCurrentTime: safeCurrentTime,
            shouldAutoPlay: true
        )
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updatePlaybackProgress()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updatePlaybackProgress() {
        switch playbackMode {
        case .file:
            guard let player else { return }
            currentTime = duration > 0 ? min(player.currentTime, duration) : player.currentTime
            if !player.isPlaying {
                isPlaying = false
                stopTimer()
            }
        case .live:
            guard let livePlayerNode else { return }
            if let lastRenderTime = livePlayerNode.lastRenderTime,
               let playerTime = livePlayerNode.playerTime(forNodeTime: lastRenderTime),
               playerTime.sampleRate > 0 {
                let renderedTime = Double(playerTime.sampleTime) / playerTime.sampleRate
                let adjustedTime = renderedTime + livePlaybackTimeOffset
                currentTime = duration > 0 ? min(adjustedTime, duration) : adjustedTime
            }

            if !livePlayerNode.isPlaying, liveFinalFilePath != nil {
                isPlaying = false
                stopTimer()
                let handoff = Self.finalPlaybackHandoff(
                    heardLivePreview: livePlaybackStarted,
                    currentTime: currentTime,
                    previewDuration: livePreviewDuration,
                    duration: duration,
                    autoPlayEnabled: liveAutoplayEnabled
                )
                switchToFinalFilePlayback(
                    preserveCurrentTime: handoff.preserveCurrentTime,
                    autoPlay: handoff.shouldAutoPlay
                )
            }
        case .none:
            stopTimer()
        }
    }

    // MARK: - Waveform

    private func extractWaveform(from url: URL, replace: Bool) {
        Task.detached {
            let extracted = WaveformService.extractSamples(from: url, targetCount: replace ? 120 : 32)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if replace || self.waveformSamples.isEmpty {
                    self.waveformSamples = extracted
                } else {
                    self.waveformSamples = Self.mergeWaveformSamples(
                        existing: self.waveformSamples,
                        incoming: extracted,
                        targetCount: 120
                    )
                }
            }
        }
    }

    private static func mergeWaveformSamples(existing: [Float], incoming: [Float], targetCount: Int) -> [Float] {
        let combined = existing + incoming
        guard combined.count > targetCount else { return combined }

        var reduced: [Float] = []
        reduced.reserveCapacity(targetCount)
        let step = Double(combined.count) / Double(targetCount)
        for index in 0..<targetCount {
            let lowerBound = Int(Double(index) * step)
            let upperBound = min(Int(Double(index + 1) * step), combined.count)
            let slice = combined[lowerBound..<max(lowerBound + 1, upperBound)]
            let average = slice.reduce(0, +) / Float(slice.count)
            reduced.append(average)
        }
        return reduced
    }

    // MARK: - Formatting

    static func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Live-preview anomaly trace (DEBUG-only)

    #if DEBUG
    /// Structured `[LivePreview]` event log consumed by
    /// `scripts/bench_ui_generation.sh --log-file` for the desktop-UI
    /// benchmark's anomaly columns. Stripped from release builds.
    ///
    /// Writes to `stderr` (not `print()`/stdout) so the bench helper
    /// sees events line-by-line in real time. Swift's `print()` is
    /// block-buffered (4KB) when stdout is redirected to a file, which
    /// would leave the log empty until generation finished. stderr is
    /// line-buffered, matching the existing `LivePreviewDiagnostics`
    /// behaviour and unsurprising under `nohup … > log 2>&1`.
    ///
    /// Schema:
    ///   [LivePreview] event=<name> [key=value ...]
    /// Events:
    ///   session_start    → session=<id>
    ///   chunk_arrived    → seq=N audio_s=X cumulative_s=Y queue_depth=Q gap_ms=G
    ///   playback_started → ttfa_ms=T queue_depth=Q
    ///   underrun_paused  → underrun_n=N audio_played_s=X
    ///   underrun_resumed → stall_ms=S queue_depth=Q
    ///   decode_failed    → branch=<name>
    ///   stream_error     → message=<text>
    ///   final_handoff    → preview_audio_s=X final_audio_s=Y delta_s=D
    ///   preview_completed → underruns=N total_stall_ms=S decode_fails=D
    ///                       stream_errors=E max_chunk_gap_ms=G chunk_count=C
    fileprivate func logLivePreviewEvent(
        _ event: String,
        _ details: KeyValuePairs<String, String> = [:]
    ) {
        var line = "[LivePreview] event=\(event)"
        for (key, value) in details {
            line += " \(key)=\(value)"
        }
        line += "\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
    #else
    fileprivate func logLivePreviewEvent(
        _ event: String,
        _ details: KeyValuePairs<String, String> = [:]
    ) {}
    #endif

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let snapshotTime = player.currentTime
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == playerID else { return }
            self.isPlaying = false
            self.currentTime = flag ? self.duration : snapshotTime
            self.stopTimer()
            if !flag {
                self.playbackError = "Playback stopped unexpectedly."
            }
        }
    }
}

#if DEBUG
/// Mirror of `XPCNativeEngineClient.logProbeEvent`. Emits cross-layer
/// chunk probe lines to stderr so the desktop-UI bench helper can join
/// `[Probe.Engine]`, `[Probe.Transport]`, and `[Probe.UI]` records on
/// the engine-assigned `seq` to derive per-chunk latency aggregates.
/// DEBUG-only — release builds compile to a no-op.
fileprivate func logProbeEvent(
    _ layer: String,
    event: String,
    details: KeyValuePairs<String, String> = [:]
) {
    var line = "[Probe.\(layer)] event=\(event)"
    for (key, value) in details {
        line += " \(key)=\(value)"
    }
    line += "\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}
#else
fileprivate func logProbeEvent(
    _ layer: String,
    event: String,
    details: KeyValuePairs<String, String> = [:]
) {}
#endif
