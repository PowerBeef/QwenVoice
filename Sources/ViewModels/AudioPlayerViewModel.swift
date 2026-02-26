import Foundation
import AVFoundation
import Combine

/// Manages audio playback state for the persistent bottom player bar.
@MainActor
final class AudioPlayerViewModel: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var currentFilePath: String?
    @Published var currentTitle: String = ""
    @Published var waveformSamples: [Float] = []

    private var player: AVAudioPlayer?
    private var timer: Timer?

    var hasAudio: Bool { currentFilePath != nil }

    var formattedCurrentTime: String { Self.formatTime(currentTime) }
    var formattedDuration: String { Self.formatTime(duration) }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    // MARK: - Playback

    func load(filePath: String, title: String = "") {
        stop()

        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else { return }

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            currentFilePath = filePath
            currentTitle = title.isEmpty ? URL(fileURLWithPath: filePath).lastPathComponent : title
            duration = player?.duration ?? 0
            currentTime = 0
            extractWaveform(from: url)
        } catch {
            currentFilePath = nil
        }
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTimer()
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
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        stopTimer()
    }

    func dismiss() {
        stop()
        currentFilePath = nil
        currentTitle = ""
        duration = 0
        waveformSamples = []
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        let time = fraction * duration
        player.currentTime = time
        currentTime = time
    }

    /// Load and immediately play a file.
    func playFile(_ path: String, title: String = "") {
        load(filePath: path, title: title)
        play()
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
}
