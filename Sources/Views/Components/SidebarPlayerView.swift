import SwiftUI

/// Compact vertical audio player designed for the sidebar's narrow width.
struct SidebarPlayerView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel

    var body: some View {
        if audioPlayer.hasAudio {
            VStack(alignment: .leading, spacing: 8) {
                // Row 1: Title + dismiss
                HStack {
                    Text(audioPlayer.currentTitle)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Spacer()

                    Button {
                        AppLaunchConfiguration.performAnimated(.easeInOut(duration: 0.25)) {
                            audioPlayer.dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebarPlayer_dismiss")
                }

                // Row 2: Waveform (tap to seek)
                GeometryReader { geo in
                    WaveformView(samples: audioPlayer.waveformSamples, progress: audioPlayer.progress)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            let fraction = max(0, min(1, location.x / geo.size.width))
                            audioPlayer.seek(to: fraction)
                        }
                }
                .frame(height: 30)
                .accessibilityIdentifier("sidebarPlayer_waveform")

                // Row 3: Play/pause + time
                HStack(spacing: 8) {
                    Button {
                        AppLaunchConfiguration.performAnimated(.spring(response: 0.3, dampingFraction: 0.7)) {
                            audioPlayer.togglePlayPause()
                        }
                    } label: {
                        Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    .accessibilityIdentifier("sidebarPlayer_playPause")

                    Text("\(audioPlayer.formattedCurrentTime) / \(audioPlayer.formattedDuration)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let playbackError = audioPlayer.playbackError {
                    Text(playbackError)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("sidebarPlayer_error")
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.accent.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(AppTheme.accent.opacity(0.15), lineWidth: 1)
                    )
            )
            .transition(
                AppLaunchConfiguration.current.animationsEnabled
                ? .move(edge: .bottom).combined(with: .opacity)
                : .identity
            )
            .accessibilityIdentifier("sidebarPlayer_bar")
        }
    }
}
