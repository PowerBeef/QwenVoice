import AVFoundation
import SwiftUI
import QwenVoiceCore

/// Full-screen Player sheet from design_references/Vocello iOS/player.jsx.
/// Renders a mode-tinted waveform + scrubber, a karaoke transcript that
/// follows playback under linear word-timing (per the approved plan), and
/// Save / Download / Dismiss actions.
///
/// Self-contained: uses its own AVAudioPlayer so it doesn't compete with
/// the engine's live-preview state machine. Caller hands in an
/// `IOSPlayerSheetItem` and an optional save handler.
struct IOSPlayerSheet: View {
    let item: IOSPlayerSheetItem
    var onSave: (() -> Void)?
    var onDismiss: () -> Void

    @StateObject private var controller = IOSPlayerSheetController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            IOSModeBackdrop(tint: item.modeTint, intensity: .warm)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 12)
                waveform
                    .padding(.bottom, 14)
                header
                    .padding(.bottom, 22)
                transcript
                    .padding(.bottom, 18)
                Spacer(minLength: 0)
                scrubber
                    .padding(.bottom, 18)
                controls
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .preferredColorScheme(.dark)
        .task {
            await controller.load(item: item)
        }
        .onDisappear {
            controller.stop()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .frame(width: 36, height: 36)
                    .background {
                        Circle()
                            .fill(IOSAppTheme.glassSurfaceFillMuted.opacity(0.55))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            Spacer()

            Text("Now playing")
                .font(.caption.weight(.semibold))
                .tracking(0.7)
                .foregroundStyle(IOSAppTheme.textTertiary)

            Spacer()

            Button {
                controller.shareCurrent()
            } label: {
                // Per design: download icon (arrow.down.to.line) replaces
                // the share-up icon in the Player sheet header for
                // consistency with the inline-player.
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .frame(width: 36, height: 36)
                    .background {
                        Circle()
                            .fill(IOSAppTheme.glassSurfaceFillMuted.opacity(0.55))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download")
        }
        .padding(.top, 8)
    }

    // MARK: - Header

    /// Centered voice name + "Just now · 0:06" timestamp.
    ///
    /// R3 G.6.1 (2026-05-21): rewritten to match
    /// `design_references/Vocello iOS/player.jsx` `.vc-player-sheet-meta`:
    /// no avatar, voice name as 22pt SF Pro Display semibold on top,
    /// "{timeLabel} · {duration}" in 13pt grey below. The previous
    /// left-aligned avatar+name HStack didn't read as the marquee the
    /// design wants.
    private var header: some View {
        VStack(spacing: 4) {
            Text(item.voiceName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(IOSAppTheme.textPrimary)
                .lineLimit(1)

            HStack(spacing: 6) {
                IOSModeDot(tint: item.modeTint)
                Text(item.modeLabel)
                if let detail = item.subtitle {
                    Text("·")
                        .foregroundStyle(IOSAppTheme.textTertiary)
                    Text(detail)
                        .lineLimit(1)
                }
                Text("·")
                    .foregroundStyle(IOSAppTheme.textTertiary)
                Text(controller.formatted(time: controller.duration))
                    .monospacedDigit()
            }
            .font(.system(size: 13))
            .foregroundStyle(IOSAppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Waveform

    /// R3 G.6.2 (2026-05-21): 42 bars at 96pt height per
    /// `app.css .vc-big-wave { height: 96px }` + `player.jsx
    /// <BigWaveform bars={42} />`. Was 38 bars at 72pt — too small to
    /// read as the "art" of the player sheet.
    private var waveform: some View {
        IOSWaveformBars(
            seed: item.waveformSeed,
            barCount: 42,
            tint: item.modeTint,
            progress: controller.progress,
            isAnimating: false
        )
        .frame(height: 96)
    }

    // MARK: - Scrubber

    /// R3 G.6.3 (2026-05-21): explicit scrubber track + progress fill +
    /// draggable thumb, matching `app.css` `.vc-player-scrub*`. The
    /// previous version showed only "0:00 / 0:00" labels and made
    /// scrubbing depend on dragging the waveform — undiscoverable.
    private var scrubber: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let width = geo.size.width
                let progress = CGFloat(controller.progress)
                let thumbX = max(0, min(width, width * progress))

                ZStack(alignment: .leading) {
                    // Track
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 4)

                    // Fill
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [item.modeTint.opacity(0.85), item.modeTint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: thumbX, height: 4)

                    // Thumb
                    Circle()
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                        .overlay {
                            Circle().stroke(item.modeTint, lineWidth: 2)
                        }
                        .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 2)
                        .offset(x: thumbX - 8)
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let ratio = max(0, min(1, value.location.x / width))
                            controller.scrub(to: ratio)
                        }
                )
            }
            .frame(height: 24)

            HStack {
                Text(controller.formatted(time: controller.currentTime))
                Spacer()
                Text(controller.formatted(time: controller.duration))
            }
            .font(.system(.caption, design: .monospaced).monospacedDigit())
            .foregroundStyle(IOSAppTheme.textSecondary)
        }
    }

    // MARK: - Transcript

    /// Centered karaoke transcript per
    /// `app.css .vc-player-sheet-transcript { text-align: center }`.
    /// Wrapping card removed so the transcript reads as flowing prose
    /// like the design — the player sheet itself is the surface.
    private var transcript: some View {
        ScrollView(.vertical, showsIndicators: false) {
            IOSPlayerKaraokeText(
                spans: controller.spans,
                currentTime: controller.currentTime,
                tint: item.modeTint,
                isPlaying: controller.isPlaying,
                reduceMotion: reduceMotion,
                alignment: .center
            )
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: 220)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 14) {
            Button {
                controller.skip(by: -5)
            } label: {
                Image(systemName: "gobackward.5")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .frame(width: 52, height: 52)
                    .background {
                        Circle().fill(IOSAppTheme.glassSurfaceFillMuted.opacity(0.55))
                    }
            }
            .buttonStyle(.plain)

            IOSPrimaryCTAButton(
                title: controller.isPlaying ? "Pause" : "Play",
                symbol: controller.isPlaying ? "pause.fill" : "play.fill",
                tint: item.modeTint,
                isEnabled: controller.duration > 0,
                action: { controller.togglePlayback() }
            )

            Button {
                controller.skip(by: 5)
            } label: {
                Image(systemName: "goforward.5")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .frame(width: 52, height: 52)
                    .background {
                        Circle().fill(IOSAppTheme.glassSurfaceFillMuted.opacity(0.55))
                    }
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Player sheet item

struct IOSPlayerSheetItem: Equatable, Identifiable {
    let audioURL: URL
    let transcript: String
    let voiceName: String
    let modeLabel: String
    let modeTint: Color
    let subtitle: String?
    let avatarSeed: String
    let avatarInitials: String
    let waveformSeed: Int

    var id: URL { audioURL }

    static func == (lhs: IOSPlayerSheetItem, rhs: IOSPlayerSheetItem) -> Bool {
        lhs.audioURL == rhs.audioURL && lhs.transcript == rhs.transcript
    }

    /// Helper: build a player-sheet item from a History `Generation` row.
    /// Returns `nil` when the underlying audio file no longer exists on disk.
    static func from(history: Generation) -> IOSPlayerSheetItem? {
        guard FileManager.default.fileExists(atPath: history.audioPath) else {
            return nil
        }
        let modeTint: Color
        let modeLabel: String
        switch history.mode.lowercased() {
        case "custom":
            modeTint = IOSBrandTheme.custom
            modeLabel = "Custom"
        case "design":
            modeTint = IOSBrandTheme.design
            modeLabel = "Design"
        case "clone":
            modeTint = IOSBrandTheme.clone
            modeLabel = "Clone"
        default:
            modeTint = IOSBrandTheme.library
            modeLabel = history.mode.capitalized
        }
        let voiceName = history.voice ?? "Voice"
        return IOSPlayerSheetItem(
            audioURL: URL(fileURLWithPath: history.audioPath),
            transcript: history.text,
            voiceName: voiceName,
            modeLabel: modeLabel,
            modeTint: modeTint,
            subtitle: history.formattedDate,
            avatarSeed: voiceName,
            avatarInitials: voiceName,
            waveformSeed: history.id.map { Int(truncatingIfNeeded: $0) } ?? history.audioPath.hashValue
        )
    }
}

// MARK: - Environment plumbing

/// Environment closure for requesting the global Player sheet presentation.
/// QVoiceiOSRootView injects a closure that sets its `playerSheetItem` state;
/// any descendant view (History rows, Studio inline player) reads it via
/// `@Environment(\.presentIOSPlayerSheet)` and calls it with an item.
struct IOSPlayerSheetPresenterKey: EnvironmentKey {
    static let defaultValue: @MainActor (IOSPlayerSheetItem) -> Void = { _ in }
}

extension EnvironmentValues {
    var presentIOSPlayerSheet: @MainActor (IOSPlayerSheetItem) -> Void {
        get { self[IOSPlayerSheetPresenterKey.self] }
        set { self[IOSPlayerSheetPresenterKey.self] = newValue }
    }
}

// MARK: - Karaoke renderer

struct IOSPlayerKaraokeText: View {
    let spans: [IOSWordSpan]
    let currentTime: TimeInterval
    let tint: Color
    let isPlaying: Bool
    let reduceMotion: Bool
    var alignment: TextAlignment = .leading

    var body: some View {
        Text(attributedTranscript)
            .font(.system(.title3, design: .default, weight: .regular))
            .lineSpacing(4)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributedTranscript: AttributedString {
        var attributed = AttributedString()
        let activeIndex = reduceMotion ? nil : IOSWordTimingPlanner.activeIndex(in: spans, at: currentTime)
        for (i, span) in spans.enumerated() {
            var run = AttributedString(span.text)
            if span.isWhitespace {
                run.foregroundColor = IOSAppTheme.textPrimary
            } else if reduceMotion {
                run.foregroundColor = IOSAppTheme.textPrimary
            } else if i == activeIndex {
                run.foregroundColor = tint
                run.font = .system(.title3, design: .default, weight: .semibold)
            } else if span.end <= currentTime {
                run.foregroundColor = IOSAppTheme.textSecondary
            } else {
                run.foregroundColor = IOSAppTheme.textTertiary
            }
            attributed.append(run)
        }
        return attributed
    }
}

// MARK: - Controller

@MainActor
final class IOSPlayerSheetController: NSObject, ObservableObject {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var spans: [IOSWordSpan] = []

    private var player: AVAudioPlayer?
    private var displayLink: CADisplayLink?
    private var loadedItem: IOSPlayerSheetItem?

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1.0, max(0.0, currentTime / duration))
    }

    func load(item: IOSPlayerSheetItem) async {
        guard loadedItem != item else {
            // Re-presented for the same item — autoplay from current state.
            play()
            return
        }
        loadedItem = item
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
            let player = try AVAudioPlayer(contentsOf: item.audioURL)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            self.duration = player.duration
            self.currentTime = 0
            self.spans = IOSWordTimingPlanner.plan(
                transcript: item.transcript,
                audioDuration: player.duration
            )
            play()
        } catch {
            self.player = nil
            self.duration = 0
            self.spans = IOSWordTimingPlanner.plan(transcript: item.transcript, audioDuration: 0)
        }
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startDisplayLink()
        IOSHaptics.selection()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopDisplayLink()
    }

    func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    func stop() {
        player?.stop()
        isPlaying = false
        stopDisplayLink()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func skip(by seconds: TimeInterval) {
        guard let player else { return }
        let target = max(0, min(duration, player.currentTime + seconds))
        player.currentTime = target
        currentTime = target
    }

    func scrub(to fraction: Double) {
        guard let player else { return }
        let target = duration * max(0, min(1, fraction))
        player.currentTime = target
        currentTime = target
    }

    func shareCurrent() {
        guard let url = loadedItem?.audioURL else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?
            .rootViewController?
            .present(activity, animated: true)
    }

    func formatted(time: TimeInterval) -> String {
        guard time.isFinite else { return "0:00" }
        let total = max(0, Int(time.rounded()))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func startDisplayLink() {
        stopDisplayLink()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 60, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying && isPlaying {
            isPlaying = false
            stopDisplayLink()
        }
    }
}

extension IOSPlayerSheetController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.stopDisplayLink()
            self.currentTime = self.duration
        }
    }
}
