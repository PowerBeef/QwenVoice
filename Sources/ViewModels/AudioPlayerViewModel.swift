import Foundation
import AVFoundation
import QwenVoiceNative
import Combine

/// Manages playback state for the persistent sidebar player bar.
@MainActor
final class AudioPlayerViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate {

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

    private enum PlaybackMode {
        case none
        case file
        case live
    }

    enum LivePreviewPhase: String, Sendable {
        case idle
        case buffering
        case playing
        case draining
        case finalizing
    }

    private struct LivePreviewConfiguration {
        let prebufferThreshold: Int

        static func current(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> LivePreviewConfiguration {
            let rawThreshold = environment["QWENVOICE_LIVE_PREVIEW_PREBUFFER_CHUNKS"]
            let parsedThreshold = rawThreshold.flatMap(Int.init).map { min(max($0, 1), 8) }
            return LivePreviewConfiguration(prebufferThreshold: parsedThreshold ?? 2)
        }
    }

    private var playbackMode: PlaybackMode = .none
    private var player: AVAudioPlayer?
    private var liveEngine: AVAudioEngine?
    private var livePlayerNode: AVAudioPlayerNode?
    private var liveScheduledCount = 0
    private var liveFormat: AVAudioFormat?
    private var liveSessionID: String?
    private var liveSessionDirectory: String?
    private var liveFinalFilePath: String?
    private var liveAutoplayEnabled = false
    private var pendingFirstChunkInterval: AppPerformanceSignposts.Interval?
    private var pendingAutoplaySignpost = false
    private var livePlaybackStarted = false
    private var livePlaybackTimeOffset: TimeInterval = 0
    private var liveUnderrunCount = 0
    private let livePreviewConfiguration: LivePreviewConfiguration
    private var chunkCancellable: AnyCancellable?
    private var timer: Timer?

    var hasAudio: Bool { currentFilePath != nil || isLiveStream || liveSessionID != nil }
    var canSeek: Bool { playbackMode == .file || liveFinalFilePath != nil }
    var durationDisplayText: String { isLiveStream && liveFinalFilePath == nil ? "Live" : playbackProgress.formattedDuration }

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
        bindChunkBroker()
    }

    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
            chunkCancellable?.cancel()
        }
    }

    // MARK: - Playback

    func load(filePath: String, title: String = "") {
        pendingAutoplaySignpost = false
        teardownLivePlayback(clearSession: true)
        stopFilePlayback(clearPlayer: true)

        do {
            try applyFilePlayback(
                filePath: filePath,
                title: title,
                preserveCurrentTime: 0,
                autoPlay: false,
                transitionFromLive: false
            )
        } catch {
            clearLoadedAudio()
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
        livePreviewQueueDepth = 0
        livePreviewPhase = .idle
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

    func playFile(_ path: String, title: String = "", isAutoplay: Bool = false) {
        load(filePath: path, title: title)
        if isAutoplay {
            pendingAutoplaySignpost = true
        }
        guard player != nil else { return }
        play()
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
        livePreviewQueueDepth = 0
        livePreviewPhase = .buffering
    }

    func completeStreamingPreview(
        result: QwenVoiceNative.GenerationResult,
        title: String,
        shouldAutoPlay: Bool
    ) {
        guard result.usedStreaming else {
            if shouldAutoPlay {
                playFile(result.audioPath, title: title)
            }
            return
        }

        currentTitle = title
        currentFilePath = result.audioPath
        liveFinalFilePath = result.audioPath
        if let streamSessionDirectory = result.streamSessionDirectory {
            liveSessionDirectory = streamSessionDirectory
        }
        duration = max(duration, result.durationSeconds)

        // Only transition immediately if live playback never started or all
        // buffers have already drained. Otherwise the existing buffer-drain
        // mechanism (handleLiveBufferPlaybackCompletion → finishLivePlaybackAfterDrainingBuffers)
        // handles the transition to avoid replaying audio that was already heard.
        if !livePlaybackStarted || liveScheduledCount == 0 {
            switchToFinalFilePlayback(
                preserveCurrentTime: 0,
                autoPlay: shouldAutoPlay
            )
        }
    }

    func abortLivePreviewIfNeeded() {
        guard playbackMode == .live || liveSessionID != nil else { return }
        dismiss()
    }

    // MARK: - Notifications

    private struct ChunkInfo: Sendable {
        let requestID: Int
        let title: String
        let chunkPath: String
        let sessionDirectory: String?
        let cumulativeDuration: Double?
    }

    private func bindChunkBroker() {
        chunkCancellable = GenerationChunkBroker.shared.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, let chunkPath = event.chunkPath else { return }
                let chunk = ChunkInfo(
                    requestID: event.requestID,
                    title: event.title,
                    chunkPath: chunkPath,
                    sessionDirectory: event.streamSessionDirectory,
                    cumulativeDuration: event.cumulativeDurationSeconds
                )
                self.handleGenerationChunk(chunk)
            }
    }

    private func handleGenerationChunk(_ chunk: ChunkInfo) {
        let sessionID = String(chunk.requestID)
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

        appendLiveChunk(
            from: URL(fileURLWithPath: chunk.chunkPath),
            cumulativeDuration: cumulativeDuration
        )
    }

    // MARK: - Live Playback

    private func startLiveSession(id: String, title: String, sessionDirectory: String?, autoPlay: Bool) {
        teardownLivePlayback(clearSession: true)
        stopFilePlayback(clearPlayer: true)

        playbackMode = .live
        liveSessionID = id
        liveSessionDirectory = sessionDirectory
        liveFinalFilePath = nil
        liveAutoplayEnabled = autoPlay
        liveScheduledCount = 0
        livePlaybackStarted = false
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
        livePreviewQueueDepth = 0
        livePreviewPhase = .buffering
    }

    private func appendLiveChunk(from url: URL, cumulativeDuration: TimeInterval?) {
        guard let (buffer, fileFormat) = loadPCMBuffer(from: url) else {
            playbackError = "Live audio preview could not decode the latest chunk."
            return
        }

        if liveEngine == nil || livePlayerNode == nil {
            configureLiveEngine(with: fileFormat)
        }

        liveScheduledCount += 1
        livePreviewQueueDepth = liveScheduledCount
        scheduleLiveBuffer(buffer)

        duration = cumulativeDuration ?? (duration + TimeInterval(buffer.frameLength) / fileFormat.sampleRate)
        if let pendingFirstChunkInterval {
            AppPerformanceSignposts.end(pendingFirstChunkInterval)
            AppPerformanceSignposts.emit("First Chunk Received")
            self.pendingFirstChunkInterval = nil
        }

        let prebufferThreshold = livePlaybackStarted && liveUnderrunCount > 0
            ? 1
            : livePreviewConfiguration.prebufferThreshold

        if liveAutoplayEnabled,
           liveScheduledCount >= prebufferThreshold || liveFinalFilePath != nil {
            attemptLivePlay()
        } else {
            livePreviewPhase = .buffering
        }

        try? FileManager.default.removeItem(at: url)
        cleanupLiveSessionDirectoryIfEmpty()
    }

    private func attemptLivePlay() {
        if liveFinalFilePath != nil, !isPlaying {
            switchToFinalFilePlayback(preserveCurrentTime: currentTime, autoPlay: true)
            return
        }

        guard let liveEngine, let livePlayerNode else { return }

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
            livePreviewPhase = .playing
            playbackError = nil
            startTimer()
            consumeAutoplaySignpostIfNeeded()
        } catch {
            playbackError = "Playback could not start."
        }
    }

    private func configureLiveEngine(with format: AVAudioFormat) {
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
            Task { [weak self] in
                await self?.handleLiveBufferPlaybackCompletion()
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
        livePreviewQueueDepth = liveScheduledCount
        if liveScheduledCount > 0 {
            livePreviewPhase = isPlaying ? .playing : .draining
        }
        if liveScheduledCount == 0, liveFinalFilePath != nil {
            livePreviewPhase = .finalizing
            finishLivePlaybackAfterDrainingBuffers()
        } else if liveScheduledCount == 0 {
            liveUnderrunCount += 1
            livePlayerNode?.pause()
            isPlaying = false
            stopTimer()
            livePreviewPhase = .buffering
        }
    }

    private func finishLivePlaybackAfterDrainingBuffers() {
        stopLivePlayback(resetCurrentTime: false)
        currentTime = 0

        if liveFinalFilePath != nil {
            // Don't autoplay — the user already heard the audio via live chunks.
            // Just load the final file so the player supports seek/replay.
            switchToFinalFilePlayback(
                preserveCurrentTime: 0,
                autoPlay: false
            )
        }
    }

    private func switchToFinalFilePlayback(preserveCurrentTime: TimeInterval, autoPlay: Bool) {
        guard let finalFilePath = liveFinalFilePath else { return }
        livePreviewPhase = .finalizing

        do {
            try applyFilePlayback(
                filePath: finalFilePath,
                title: currentTitle,
                preserveCurrentTime: preserveCurrentTime,
                autoPlay: autoPlay,
                transitionFromLive: true
            )
        } catch {
            playbackError = error.localizedDescription
        }
    }

    private func teardownLivePlayback(clearSession: Bool) {
        stopLivePlayback(resetCurrentTime: true)
        liveScheduledCount = 0
        livePlaybackStarted = false
        livePlaybackTimeOffset = 0
        liveUnderrunCount = 0
        liveFormat = nil
        livePreviewQueueDepth = 0
        clearPendingFirstChunkInterval()

        if clearSession {
            cleanupLiveSessionDirectory()
            liveSessionID = nil
            liveSessionDirectory = nil
            liveFinalFilePath = nil
            liveAutoplayEnabled = false
            isLiveStream = false
            livePreviewPhase = .idle
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
        guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }
        let format = audioFile.processingFormat
        let frameCapacity = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }

        do {
            try audioFile.read(into: buffer)
            return (buffer, format)
        } catch {
            return nil
        }
    }

    private func applyFilePlayback(
        filePath: String,
        title: String,
        preserveCurrentTime: TimeInterval,
        autoPlay: Bool,
        transitionFromLive: Bool
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
            livePlaybackTimeOffset = 0
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
        livePreviewQueueDepth = 0
        livePreviewPhase = .idle
        extractWaveform(from: url, replace: true)

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
                switchToFinalFilePlayback(preserveCurrentTime: 0, autoPlay: liveAutoplayEnabled)
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

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let snapshotTime = player.currentTime
        let playerID = ObjectIdentifier(player)
        Task { [weak self] in
            guard let self else { return }
            await self.finishPlaybackIfCurrent(
                playerID: playerID,
                succeeded: flag,
                snapshotTime: snapshotTime
            )
        }
    }

    private func finishPlaybackIfCurrent(
        playerID: ObjectIdentifier,
        succeeded: Bool,
        snapshotTime: TimeInterval
    ) {
        guard player.map(ObjectIdentifier.init) == playerID else { return }
        isPlaying = false
        currentTime = succeeded ? duration : snapshotTime
        stopTimer()
        if !succeeded {
            playbackError = "Playback stopped unexpectedly."
        }
    }
}
