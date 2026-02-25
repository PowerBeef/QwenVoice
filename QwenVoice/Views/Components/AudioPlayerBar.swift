import SwiftUI

/// Persistent audio player bar at the bottom of the window.
struct AudioPlayerBar: View {
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel

    var body: some View {
        if audioPlayer.hasAudio {
            VStack(spacing: 0) {
                // Waveform
                WaveformView(samples: audioPlayer.waveformSamples, progress: audioPlayer.progress)
                    .frame(height: 32)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                // Controls & Scrubber Info
                HStack(spacing: 16) {
                    // Play / Pause
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            audioPlayer.togglePlayPause()
                        }
                    } label: {
                        Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(AppTheme.accent)
                            .symbolEffect(.bounce, value: audioPlayer.isPlaying)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    .accessibilityIdentifier("audioPlayer_playPause")

                    VStack(alignment: .leading, spacing: 4) {
                        Text(audioPlayer.currentTitle)
                            .font(.headline)
                            .lineLimit(1)
                            .accessibilityIdentifier("audioPlayer_title")
                        
                        HStack(spacing: 8) {
                            Text(audioPlayer.formattedCurrentTime)
                                .font(.caption2.monospacedDigit().weight(.medium))
                                .foregroundColor(.secondary)
                            
                            Slider(
                                value: Binding(
                                    get: { audioPlayer.progress },
                                    set: { audioPlayer.seek(to: $0) }
                                ),
                                in: 0...1
                            )
                            .tint(AppTheme.customVoice)
                            .controlSize(.mini)
                            .accessibilityIdentifier("audioPlayer_seekSlider")
                            
                            Text(audioPlayer.formattedDuration)
                                .font(.caption2.monospacedDigit().weight(.medium))
                                .foregroundColor(.secondary)
                        }
                    }

                    // Stop
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            audioPlayer.stop()
                        }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("audioPlayer_stop")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .padding(.top, 8)
            }
            .frame(width: 460)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .shadow(color: Color.black.opacity(0.12), radius: 20, y: 10)
            .overlay(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: audioPlayer.hasAudio)
            .accessibilityIdentifier("audioPlayer_bar")
        }
    }
}
