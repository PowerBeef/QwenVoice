import Foundation
import AVFoundation
import Combine

/// Manages audio playback state for the persistent bottom player bar.
@MainActor
final class AudioPlayerViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    private static let autoplayRetryScheduleNs: [UInt64] = [60_000_000, 180_000_000]

    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var currentFilePath: String?
    @Published var currentTitle: String = ""
    @Published var waveformSamples: [Float] = []
    @Published var playbackError: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var autoplayTask: Task<Void, Never>?

    var hasAudio: Bool { currentFilePath != nil }

    var formattedCurrentTime: String { Self.formatTime(currentTime) }
    var formattedDuration: String { Self.formatTime(duration) }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    // MARK: - Playback

    func load(filePath: String, title: String = "") {
        autoplayTask?.cancel()
        stop()

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
        autoplayTask?.cancel()
        _ = attemptPlay(reportFailure: true)
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func stop() {
        autoplayTask?.cancel()
        player?.stop()
        player = nil
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
        guard let player else { return }
        let time = fraction * duration
        player.currentTime = time
        currentTime = time
    }

    /// Load a file and optionally defer auto-start to avoid immediate post-write playback races.
    func playFile(_ path: String, title: String = "", deferAutoStart: Bool = false) {
        load(filePath: path, title: title)
        if deferAutoStart {
            scheduleAutoplay(for: path)
        } else {
            play()
        }
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
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

    @discardableResult
    private func attemptPlay(reportFailure: Bool) -> Bool {
        guard let player else { return false }

        let didStart = player.play()
        guard didStart else {
            isPlaying = false
            stopTimer()
            if reportFailure {
                playbackError = "Playback could not start."
            }
            return false
        }

        playbackError = nil
        isPlaying = true
        startTimer()
        return true
    }

    private func scheduleAutoplay(for path: String) {
        autoplayTask?.cancel()
        playbackError = nil
        autoplayTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for delay in Self.autoplayRetryScheduleNs {
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled || self.currentFilePath != path {
                    return
                }
                if self.attemptPlay(reportFailure: false) {
                    return
                }
            }

            if self.currentFilePath == path {
                self.playbackError = "Auto-play could not start. Press play to try again."
            }
        }
    }

    private func clearLoadedAudio() {
        currentFilePath = nil
        currentTitle = ""
        duration = 0
        currentTime = 0
        waveformSamples = []
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
