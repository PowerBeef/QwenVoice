import SwiftUI

/// Compact vertical audio player designed for the sidebar's narrow width.
struct SidebarPlayerView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel

    var body: some View {
        if audioPlayer.hasAudio {
            VStack(alignment: .leading, spacing: 7) {
                // Row 1: Title + dismiss
                HStack {
                    Text(audioPlayer.currentTitle)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    if audioPlayer.isLiveStream {
                        Text("Live")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppTheme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(AppTheme.accent.opacity(0.14))
                            )
                            .accessibilityIdentifier("sidebarPlayer_liveBadge")
                    }

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
                            guard audioPlayer.canSeek else { return }
                            let fraction = max(0, min(1, location.x / geo.size.width))
                            audioPlayer.seek(to: fraction)
                        }
                }
                .frame(height: 30)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Waveform")
                .opacity(audioPlayer.canSeek ? 1.0 : 0.75)
                .accessibilityIdentifier("sidebarPlayer_waveform")
                .accessibilityValue(audioPlayer.canSeek ? "seek enabled" : "seek disabled")

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
                    .accessibilityIdentifier("sidebarPlayer_playPause")
                    .accessibilityValue(audioPlayer.isPlaying ? "pause" : "play")

                    Text("\(audioPlayer.formattedCurrentTime) / \(audioPlayer.durationDisplayText)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("sidebarPlayer_time")
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
            .padding(7)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(AppTheme.accent.opacity(0.15), lineWidth: 1)
                    )
            )
            .transition(
                AppLaunchConfiguration.current.animationsEnabled
                ? .move(edge: .bottom).combined(with: .opacity)
                : .identity
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sidebarPlayer_bar")
        }
    }
}
