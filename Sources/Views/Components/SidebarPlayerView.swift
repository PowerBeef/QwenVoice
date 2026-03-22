import SwiftUI

/// Compact vertical audio player designed for the sidebar's narrow width.
struct SidebarPlayerView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject var playbackProgress: AudioPlayerViewModel.PlaybackProgress

    var body: some View {
        if audioPlayer.hasAudio {
            VStack(alignment: .leading, spacing: 7) {
                Text("Player")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                HStack {
                    Text(audioPlayer.currentTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    if audioPlayer.isLiveStream {
                        Text("Live")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppTheme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            #if QW_UI_LIQUID
                            .glassBadge(tint: AppTheme.accent)
                            #else
                            .background(
                                Capsule()
                                    .fill(AppTheme.accent.opacity(0.14))
                            )
                            #endif
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

                GeometryReader { geo in
                    WaveformView(samples: audioPlayer.waveformSamples, progress: playbackProgress.progress)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            guard audioPlayer.canSeek else { return }
                            let fraction = max(0, min(1, location.x / geo.size.width))
                            audioPlayer.seek(to: fraction)
                        }
                }
                .frame(height: 24)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Waveform")
                .opacity(audioPlayer.canSeek ? 1.0 : 0.75)
                .accessibilityIdentifier("sidebarPlayer_waveform")
                .accessibilityValue(audioPlayer.canSeek ? "seek enabled" : "seek disabled")

                HStack(spacing: 6) {
                    Button {
                        AppLaunchConfiguration.performAnimated(.spring(response: 0.3, dampingFraction: 0.7)) {
                            audioPlayer.togglePlayPause()
                        }
                    } label: {
                        Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebarPlayer_playPause")
                    .accessibilityValue(audioPlayer.isPlaying ? "pause" : "play")

                    Text("\(playbackProgress.formattedCurrentTime) / \(audioPlayer.durationDisplayText)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("sidebarPlayer_time")

                    Spacer(minLength: 0)

                    Text(audioPlayer.isLiveStream ? "Preview" : "Playback")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
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
