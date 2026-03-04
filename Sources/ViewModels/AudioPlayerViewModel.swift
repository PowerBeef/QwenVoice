import Foundation
import AVFoundation

/// Manages audio playback state for the persistent bottom player bar.
@MainActor
final class AudioPlayerViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var currentFilePath: String?
    @Published var currentTitle: String = ""
    @Published var waveformSamples: [Float] = []
    @Published var playbackError: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var streamFormat: AVAudioFormat?
    private var isStreamingActive = false
    private var hasStreamingAudio = false
    private var pendingStreamBuffers = 0
    private var streamFinalChunkReceived = false
    private var streamQueuedDuration: TimeInterval = 0

    var hasAudio: Bool { currentFilePath != nil || isStreamingActive || hasStreamingAudio }

    var formattedCurrentTime: String { Self.formatTime(currentTime) }
    var formattedDuration: String { Self.formatTime(duration) }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    // MARK: - Playback

    func load(filePath: String, title: String = "") {
        stop()
        hasStreamingAudio = false

        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            clearLoadedAudio()
            playbackError = "Audio file not found."
            return
        }

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.prepareToPlay()
            currentFilePath = filePath
            currentTitle = title.isEmpty ? URL(fileURLWithPath: filePath).lastPathComponent : title
            duration = player?.duration ?? 0
            currentTime = 0
            playbackError = nil
            extractWaveform(from: url)
        } catch {
            clearLoadedAudio()
            playbackError = "Playback could not load this file."
        }
    }

    func play() {
        if isStreamingActive {
            attemptStreamingPlay()
        } else {
            attemptPlay()
        }
    }

    func pause() {
        if isStreamingActive {
            playerNode?.pause()
            isPlaying = false
            stopTimer()
            return
        }

        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func stop() {
        player?.stop()
        player = nil
        stopStreamingPlayback(clearBufferedState: currentFilePath == nil)
        isPlaying = false
        currentTime = 0
        stopTimer()
    }

    func dismiss() {
        stop()
        clearLoadedAudio()
        playbackError = nil
    }

    func seek(to fraction: Double) {
        guard !isStreamingActive, let player else { return }
        let time = fraction * duration
        player.currentTime = time
        currentTime = time
    }

    func playFile(_ path: String, title: String = "") {
        load(filePath: path, title: title)
        guard player != nil else { return }
        play()
    }

    func enqueuePCMChunk(samples: [Float], sampleRate: Int, title: String) {
        guard !samples.isEmpty else { return }
        guard ensureStreamingPlayback(sampleRate: sampleRate, title: title) else { return }
        guard let streamFormat,
              let playerNode,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: streamFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
              ) else {
            playbackError = "Streaming playback could not prepare audio."
            return
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData?[0] {
            for (index, sample) in samples.enumerated() {
                channelData[index] = sample
            }
        }

        let chunkDuration = Double(samples.count) / Double(sampleRate)
        streamQueuedDuration += chunkDuration
        duration = max(duration, streamQueuedDuration)
        pendingStreamBuffers += 1
        hasStreamingAudio = true

        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingStreamBuffers = max(0, self.pendingStreamBuffers - 1)
                if self.streamFinalChunkReceived && self.pendingStreamBuffers == 0 {
                    self.finishStreamingPlayback()
                }
            }
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }
        isPlaying = true
        playbackError = nil
        startTimer()
    }

    func markStreamingInputComplete() {
        streamFinalChunkReceived = true
        if pendingStreamBuffers == 0 {
            finishStreamingPlayback()
        }
    }

    func finalizeStreamingOutput(filePath: String, title: String) {
        guard FileManager.default.fileExists(atPath: filePath) else { return }
        currentFilePath = filePath
        currentTitle = title.isEmpty ? URL(fileURLWithPath: filePath).lastPathComponent : title
        hasStreamingAudio = false

        if let audioFile = try? AVAudioFile(forReading: URL(fileURLWithPath: filePath)) {
            let fileDuration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
            duration = max(duration, fileDuration)
        }

        extractWaveform(from: URL(fileURLWithPath: filePath))
    }

    func cancelStreamingPlayback() {
        stopStreamingPlayback(clearBufferedState: currentFilePath == nil)
        if currentFilePath == nil {
            clearLoadedAudio()
        }
        playbackError = nil
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                if self.isStreamingActive,
                   let playerNode = self.playerNode,
                   let nodeTime = playerNode.lastRenderTime,
                   let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
                    let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
                    self.currentTime = min(self.duration, max(0, elapsed))
                    if !playerNode.isPlaying && self.pendingStreamBuffers == 0 {
                        self.isPlaying = false
                        self.stopTimer()
                    }
                    return
                }

                guard let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    self.stopTimer()
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func attemptPlay() {
        guard var player else { return }

        // Seek to beginning if playback already finished
        if player.currentTime >= player.duration, player.duration > 0 {
            player.currentTime = 0
        }

        if player.play() {
            playbackError = nil
            isPlaying = true
            currentTime = player.currentTime
            startTimer()
            return
        }

        // Player in bad state — recreate from disk and retry once
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
        } else {
            playbackError = "Playback could not start."
        }
    }

    private func attemptStreamingPlay() {
        guard let audioEngine, let playerNode else { return }

        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                playbackError = "Streaming playback could not start."
                return
            }
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }
        playbackError = nil
        isPlaying = true
        startTimer()
    }

    private func ensureStreamingPlayback(sampleRate: Int, title: String) -> Bool {
        if isStreamingActive {
            if let streamFormat,
               Int(streamFormat.sampleRate.rounded()) == sampleRate,
               audioEngine != nil,
               playerNode != nil {
                if currentTitle.isEmpty {
                    currentTitle = title
                }
                return true
            }
            cancelStreamingPlayback()
        }

        stop()
        clearLoadedAudio()

        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1) else {
            playbackError = "Streaming playback could not configure audio."
            return false
        }

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            playbackError = "Streaming playback could not start."
            return false
        }

        audioEngine = engine
        playerNode = node
        streamFormat = format
        isStreamingActive = true
        hasStreamingAudio = true
        pendingStreamBuffers = 0
        streamFinalChunkReceived = false
        streamQueuedDuration = 0
        currentFilePath = nil
        currentTitle = title
        waveformSamples = []
        duration = 0
        currentTime = 0
        isPlaying = true
        playbackError = nil
        return true
    }

    private func finishStreamingPlayback() {
        stopStreamingPlayback(clearBufferedState: currentFilePath == nil)
        isPlaying = false
        currentTime = duration
        stopTimer()
    }

    private func stopStreamingPlayback(clearBufferedState: Bool) {
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
        streamFormat = nil
        isStreamingActive = false
        pendingStreamBuffers = 0
        streamFinalChunkReceived = false
        streamQueuedDuration = 0
        if clearBufferedState {
            hasStreamingAudio = false
        }
    }

    private func clearLoadedAudio() {
        currentFilePath = nil
        currentTitle = ""
        duration = 0
        currentTime = 0
        waveformSamples = []
        hasStreamingAudio = false
    }

    // MARK: - Waveform

    private func extractWaveform(from url: URL) {
        Task.detached {
            let samples = WaveformService.extractSamples(from: url, targetCount: 120)
            await MainActor.run { [weak self] in
                self?.waveformSamples = samples
            }
        }
    }

    // MARK: - Formatting

    private static func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.isPlaying = false
            self.currentTime = flag ? self.duration : player.currentTime
            self.stopTimer()
            if !flag {
                self.playbackError = "Playback stopped unexpectedly."
            }
        }
    }
}
