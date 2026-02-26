import SwiftUI

/// Slim, full-width audio player bar at the bottom of the window.
struct AudioPlayerBar: View {
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel

    var body: some View {
        if audioPlayer.hasAudio {
            HStack(spacing: 10) {
                // Play / Pause
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        audioPlayer.togglePlayPause()
                    }
                } label: {
                    Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(AppTheme.accent)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityIdentifier("audioPlayer_playPause")

                Text(audioPlayer.currentTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                    .accessibilityIdentifier("audioPlayer_title")

                Spacer()

                Text(audioPlayer.formattedCurrentTime)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundColor(.secondary)

                Text("/")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.6))

                Text(audioPlayer.formattedDuration)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundColor(.secondary)

                Slider(
                    value: Binding(
                        get: { audioPlayer.progress },
                        set: { audioPlayer.seek(to: $0) }
                    ),
                    in: 0...1
                )
                .tint(AppTheme.accent)
                .controlSize(.mini)
                .frame(width: 120)
                .accessibilityIdentifier("audioPlayer_seekSlider")

                // Dismiss
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        audioPlayer.dismiss()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("audioPlayer_dismiss")
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .glassCard()
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: audioPlayer.hasAudio)
            .accessibilityIdentifier("audioPlayer_bar")
        }
    }
}
