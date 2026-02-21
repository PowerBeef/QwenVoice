import SwiftUI

/// Persistent audio player bar at the bottom of the window.
struct AudioPlayerBar: View {
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel

    var body: some View {
        if audioPlayer.hasAudio {
            VStack(spacing: 0) {
                // Waveform
                WaveformView(samples: audioPlayer.waveformSamples, progress: audioPlayer.progress)
                    .frame(height: 40)
                    .padding(.horizontal, 16)

                // Controls
                HStack(spacing: 16) {
                    // Play / Pause
                    Button {
                        audioPlayer.togglePlayPause()
                    } label: {
                        Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    .accessibilityIdentifier("audioPlayer_playPause")

                    // Stop
                    Button {
                        audioPlayer.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("audioPlayer_stop")

                    // Seek slider
                    Slider(
                        value: Binding(
                            get: { audioPlayer.progress },
                            set: { audioPlayer.seek(to: $0) }
                        ),
                        in: 0...1
                    )
                    .accessibilityIdentifier("audioPlayer_seekSlider")

                    // Time display
                    Text("\(audioPlayer.formattedCurrentTime) / \(audioPlayer.formattedDuration)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 90, alignment: .trailing)
                        .accessibilityIdentifier("audioPlayer_timeDisplay")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                // Title
                Text(audioPlayer.currentTitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .accessibilityIdentifier("audioPlayer_title")
            }
            .background(.bar)
            .accessibilityIdentifier("audioPlayer_bar")
        }
    }
}
