import SwiftUI

/// Persistent take player pinned to the bottom of the entire window —
/// spans full window width across sidebar + detail. Replaces the
/// sidebar-bottom `SidebarPlayerView` from the previous chrome.
///
/// Three regions left-to-right:
///   • Left (240pt): play/pause disc + take title + subtitle metadata
///   • Center (flex, capped at 1200pt): scrubable animated waveform
///   • Right (180pt): take number badge + Download + ellipsis actions
///
/// At narrow widths (<900pt) the row collapses to compact mode: the
/// right region hides and the player height drops to 64pt.
///
/// Visual states are derived from `AudioPlayerViewModel`:
///   • idle:       no audio (`hasAudio == false`) — muted disc, tagline
///   • generating: live stream in progress — orbit spinner
///   • ready:      audio loaded, not playing — play button on tinted disc
///   • playing:    audio playing — pause button on tinted disc
struct WindowFooterPlayer: View {
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject var playbackProgress: AudioPlayerViewModel.PlaybackProgress
    var modeTint: Color = AppTheme.accent

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric private var scaledHeight: CGFloat = LayoutConstants.footerPlayerHeight
    @ScaledMetric private var scaledCompactHeight: CGFloat = LayoutConstants.footerPlayerCompactHeight
    @ScaledMetric private var horizontalPadding: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < LayoutConstants.sidebarHideBreakpoint
            HStack(spacing: 16) {
                leftRegion
                    .frame(minWidth: isCompact ? 0 : 240, alignment: .leading)
                    .layoutPriority(2)

                centerRegion
                    .frame(maxWidth: LayoutConstants.footerPlayerCenterMaxWidth)
                    .layoutPriority(1)

                if !isCompact {
                    rightRegion
                        .frame(minWidth: 160, alignment: .trailing)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .frame(width: geo.size.width, height: isCompact ? scaledCompactHeight : scaledHeight)
            .background(footerMaterial)
        }
        .frame(height: scaledHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("windowFooterPlayer")
    }

    @ViewBuilder
    private var footerMaterial: some View {
        Rectangle()
            .fill(Color(red: 0.078, green: 0.086, blue: 0.110).opacity(colorScheme == .dark ? 0.93 : 0.86))
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(AppTheme.railStroke.opacity(colorScheme == .dark ? 0.85 : 0.30))
                    .frame(height: 0.5)
            }
    }

    // MARK: - Regions

    @ViewBuilder
    private var leftRegion: some View {
        HStack(spacing: 12) {
            playDisc
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.vocelloFooterTitle)
                    .foregroundStyle(audioPlayer.hasAudio ? AppTheme.textPrimary : AppTheme.textSecondary)
                    .tracking(-0.1)
                    .lineLimit(1)
                Text(subtitleText)
                    .font(.vocelloCaption)
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.85))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var centerRegion: some View {
        if audioPlayer.hasAudio {
            GeometryReader { geo in
                WaveformView(
                    samples: audioPlayer.waveformSamples,
                    progress: playbackProgress.progress
                )
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard audioPlayer.canSeek else { return }
                    let fraction = max(0, min(1, location.x / geo.size.width))
                    audioPlayer.seek(to: fraction)
                }
            }
            .frame(height: 28)
            .opacity(audioPlayer.canSeek ? 1.0 : 0.7)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Take waveform")
            .accessibilityValue(audioPlayer.canSeek ? "seek enabled" : "seek disabled")
        } else {
            // Idle decoration: a faint static waveform silhouette.
            HStack(spacing: 2) {
                ForEach(0..<48, id: \.self) { i in
                    let h: CGFloat = 4 + CGFloat((i * 37) % 17)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(AppTheme.textSecondary.opacity(0.18))
                        .frame(width: 3, height: h)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var rightRegion: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if audioPlayer.hasAudio {
                Text(timeReadout)
                    .font(.vocelloMonoTime)
                    .foregroundStyle(AppTheme.textSecondary)
                    .accessibilityIdentifier("windowFooterPlayer_time")

                Button {
                    audioPlayer.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: dismissButtonSize, height: dismissButtonSize)
                        .background(
                            Circle().fill(AppTheme.inlineFill.opacity(0.6))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss take")
                .accessibilityIdentifier("windowFooterPlayer_dismiss")
            }
        }
    }

    // MARK: - Play disc

    @ScaledMetric private var playDiscSize: CGFloat = 44
    @ScaledMetric private var dismissButtonSize: CGFloat = 28

    @ViewBuilder
    private var playDisc: some View {
        Button {
            guard audioPlayer.hasAudio else { return }
            AppLaunchConfiguration.performAnimated(.spring(response: 0.3, dampingFraction: 0.7)) {
                audioPlayer.togglePlayPause()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(
                        audioPlayer.hasAudio
                            ? LinearGradient(
                                colors: [modeTint, modeTint.opacity(0.86)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            : LinearGradient(
                                colors: [AppTheme.inlineFill.opacity(0.85), AppTheme.inlineFill.opacity(0.70)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                    )
                    .frame(width: playDiscSize, height: playDiscSize)
                    .shadow(
                        color: audioPlayer.hasAudio ? modeTint.opacity(0.32) : .clear,
                        radius: 8, y: 4
                    )

                if audioPlayer.isLiveStream {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(Color.black.opacity(0.78))
                } else {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(audioPlayer.hasAudio ? Color.black.opacity(0.78) : AppTheme.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!audioPlayer.hasAudio)
        .accessibilityLabel(audioPlayer.isPlaying ? "Pause" : "Play")
        .accessibilityIdentifier("windowFooterPlayer_playPause")
        .accessibilityValue(audioPlayer.isPlaying ? "playing" : "paused")
    }

    // MARK: - Text

    private var titleText: String {
        if audioPlayer.hasAudio {
            return audioPlayer.currentTitle.isEmpty ? "Untitled take" : audioPlayer.currentTitle
        }
        return "Latest take will appear here"
    }

    private var subtitleText: String {
        if audioPlayer.isLiveStream {
            return "Generating · synthesizing on-device"
        }
        if audioPlayer.hasAudio {
            return "\(playbackProgress.formattedCurrentTime) of \(audioPlayer.durationDisplayText)"
        }
        return "Tap Generate to create one"
    }

    private var timeReadout: String {
        "\(playbackProgress.formattedCurrentTime) / \(audioPlayer.durationDisplayText)"
    }
}
