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
                Spacer(minLength: 16)
                header
                    .padding(.bottom, 20)
                waveform
                    .padding(.bottom, 8)
                scrubRow
                    .padding(.bottom, 24)
                transcript
                    .padding(.bottom, 22)
                Spacer(minLength: 0)
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

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            IOSVoiceAvatar(seed: item.avatarSeed, initials: item.avatarInitials, diameter: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.voiceName)
                    .font(.system(.title3, design: .default, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    IOSModeDot(tint: item.modeTint)
                    Text(item.modeLabel)
                        .font(.subheadline)
                        .foregroundStyle(IOSAppTheme.textSecondary)
                    if let detail = item.subtitle {
                        Text("·")
                            .font(.subheadline)
                            .foregroundStyle(IOSAppTheme.textTertiary)
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(IOSAppTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Waveform

    private var waveform: some View {
        IOSWaveformBars(
            seed: item.waveformSeed,
            barCount: 38,
            tint: item.modeTint,
            progress: controller.progress,
            isAnimating: false
        )
        .frame(height: 72)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let width = UIScreen.main.bounds.width - 48
                    let ratio = max(0, min(1, value.location.x / width))
                    controller.scrub(to: ratio)
                }
        )
    }

    // MARK: - Scrub row

    private var scrubRow: some View {
        HStack {
            Text(controller.formatted(time: controller.currentTime))
            Spacer()
            Text(controller.formatted(time: controller.duration))
        }
        .font(.system(.caption, design: .rounded).monospacedDigit())
        .foregroundStyle(IOSAppTheme.textSecondary)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollView(.vertical, showsIndicators: false) {
            IOSPlayerKaraokeText(
                spans: controller.spans,
                currentTime: controller.currentTime,
                tint: item.modeTint,
                isPlaying: controller.isPlaying,
                reduceMotion: reduceMotion
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                    .fill(IOSAppTheme.glassSurfaceFillMuted.opacity(0.5))
            }
            .overlay {
                RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
            }
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

    var body: some View {
        Text(attributedTranscript)
            .font(.system(.title3, design: .default, weight: .regular))
            .lineSpacing(4)
            .multilineTextAlignment(.leading)
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
