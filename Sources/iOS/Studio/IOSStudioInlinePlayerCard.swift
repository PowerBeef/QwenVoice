import AVFoundation
import SwiftUI

/// "Just generated" hero player in Studio's dock area, after a take
/// completes. Per design_references/Vocello iOS/studio.jsx (InlinePlayer):
/// waveform progress bar across the top, then a row with a mode-tinted
/// Play/Pause button, voice meta, and Save / Download / Dismiss icon
/// buttons.
///
/// Drives a local AVAudioPlayer so it's independent from the engine's
/// streaming preview state machine. Tapping the waveform surface
/// escalates to the full-screen IOSPlayerSheet via the `onExpand`
/// closure (caller plumbs through to the global Player sheet
/// presentation state on QVoiceiOSRootView).
struct IOSStudioInlinePlayerCard: View {
    let item: IOSStudioInlinePlayerItem
    let tint: Color
    var onSave: (() -> Void)?
    var onDismiss: () -> Void
    var onExpand: (() -> Void)?

    @StateObject private var controller = IOSInlinePlaybackController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        item: IOSStudioInlinePlayerItem,
        tint: Color,
        onSave: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void,
        onExpand: (() -> Void)? = nil
    ) {
        self.item = item
        self.tint = tint
        self.onSave = onSave
        self.onDismiss = onDismiss
        self.onExpand = onExpand
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            waveformRow
            controlsRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                .fill(IOSAppTheme.glassSurfaceFillMuted.opacity(0.66))
        }
        .overlay {
            RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                .stroke(tint.opacity(0.30), lineWidth: 0.9)
        }
        // Softer shadow per the design notes: dropped from `0 12 32 / 0.45`
        // to `0 2 10 / 0.22` so the player floats lightly above the canvas
        // instead of bleeding into the space below the tab dock.
        .shadow(color: Color.black.opacity(0.22), radius: 5, x: 0, y: 1)
        .task {
            await controller.load(url: item.audioURL, autoplay: true)
        }
        .onDisappear {
            controller.stop()
        }
        .accessibilityIdentifier("studio_inlinePlayer")
    }

    // MARK: - Waveform row

    private var waveformRow: some View {
        HStack(spacing: 8) {
            Text(controller.formatted(time: controller.currentTime))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(IOSAppTheme.textSecondary)
                .frame(width: 32, alignment: .leading)

            IOSWaveformBars(
                seed: item.waveformSeed,
                barCount: 38,
                tint: tint,
                progress: controller.progress,
                isAnimating: false
            )
            .frame(height: 32)
            .contentShape(Rectangle())
            .gesture(scrubGesture)
            .onTapGesture { onExpand?() }

            Text(controller.formatted(time: controller.duration))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(IOSAppTheme.textSecondary)
                .frame(width: 32, alignment: .trailing)
        }
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let width = max(1, UIScreen.main.bounds.width - 96)
                let ratio = max(0, min(1, value.location.x / width))
                controller.scrub(to: ratio)
            }
    }

    // MARK: - Controls row

    private var controlsRow: some View {
        HStack(spacing: 12) {
            Button {
                controller.togglePlayback()
                IOSHaptics.selection()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.accentForeground)
                    .frame(width: 40, height: 40)
                    .background {
                        Circle().fill(LinearGradient(colors: [tint, tint.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    .overlay {
                        Circle().stroke(Color.white.opacity(0.16), lineWidth: 0.8)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

            VStack(alignment: .leading, spacing: 1) {
                Text(item.voiceName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .lineLimit(1)
                Text("Just now · \(item.modeLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(IOSAppTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // Per design (Vocello iOS chat panel notes): the inline player
            // exposes Download + Dismiss only; the take is auto-persisted
            // to History so a separate Save button is redundant. Download
            // icon is SF Symbol `arrow.down.to.line` (clean down-arrow
            // pointing to a tray line) with no circle wrapper.
            iconButton(symbol: "arrow.down.to.line", label: "Download") {
                shareWAV()
            }
            iconButton(symbol: "xmark", label: "Dismiss") {
                onDismiss()
            }
        }
    }

    private func iconButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(IOSAppTheme.textSecondary)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func shareWAV() {
        let activity = UIActivityViewController(activityItems: [item.audioURL], applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?
            .rootViewController?
            .present(activity, animated: true)
    }
}

// MARK: - Playback controller

@MainActor
final class IOSInlinePlaybackController: NSObject, ObservableObject {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var displayLink: CADisplayLink?
    private var loadedURL: URL?

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1.0, max(0.0, currentTime / duration))
    }

    func load(url: URL, autoplay: Bool) async {
        guard loadedURL != url else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            self.loadedURL = url
            self.duration = player.duration
            self.currentTime = 0
            if autoplay { play() }
        } catch {
            self.player = nil
            self.duration = 0
        }
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startDisplayLink()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopDisplayLink()
    }

    func togglePlayback() {
        if isPlaying { pause() } else {
            if let player, !player.isPlaying, currentTime >= duration {
                player.currentTime = 0
                currentTime = 0
            }
            play()
        }
    }

    func stop() {
        player?.stop()
        isPlaying = false
        stopDisplayLink()
    }

    func scrub(to fraction: Double) {
        guard let player else { return }
        let target = duration * max(0, min(1, fraction))
        player.currentTime = target
        currentTime = target
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

extension IOSInlinePlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.currentTime = self.duration
            self.stopDisplayLink()
        }
    }
}
