import AVFoundation
import SwiftUI

/// Full-screen reference-clip capture surface from the Claude Design
/// prototype (design_references/Vocello iOS/chrome.jsx RecordingOverlay).
/// Records a 24 kHz mono PCM WAV using AVAudioRecorder, shows a live
/// amplitude meter, and gates the "Use this clip" CTA to the 10-20s window
/// required by the Voice Cloning reference contract.
///
/// Consumers present this as a `.fullScreenCover` and receive the completed
/// WAV file URL via `onComplete`. The view does its own permission request;
/// callers don't need to pre-check microphone access.
struct IOSRecordingOverlay: View {
    var onComplete: (URL) -> Void
    var onCancel: () -> Void

    @StateObject private var recorder = IOSReferenceClipRecorder()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            IOSModeBackdrop(tint: IOSBrandTheme.clone, intensity: .warm)

            VStack(spacing: 28) {
                topBar
                Spacer()
                meter
                statusText
                guidance
                Spacer()
                controls
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
        .task {
            await recorder.requestPermissionIfNeeded()
        }
        .onDisappear {
            recorder.stopWithoutSaving()
        }
        .alert("Microphone access denied", isPresented: $recorder.showsPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {
                onCancel()
            }
        } message: {
            Text("Vocello needs the microphone to record reference clips. Enable it in Settings to continue.")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Text("Record reference")
                .font(.system(.title2, design: .default, weight: .semibold))
                .foregroundStyle(IOSAppTheme.textPrimary)

            Spacer()

            Button("Cancel") {
                recorder.stopWithoutSaving()
                onCancel()
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(IOSAppTheme.textSecondary)
            .buttonStyle(.plain)
        }
    }

    // MARK: - Meter

    private var meter: some View {
        ZStack {
            // Outer ring at the validation window upper bound (20s).
            Circle()
                .stroke(IOSAppTheme.glassSurfaceFillMuted, lineWidth: 14)

            // Validation-zone ring (10-20s zone).
            Circle()
                .trim(from: 0.5, to: 1.0)
                .stroke(IOSBrandTheme.clone.opacity(0.18), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))

            // Live elapsed-time progress.
            Circle()
                .trim(from: 0, to: clampedProgress)
                .stroke(progressColor, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .iosAppAnimation(.easeOut(duration: 0.18), value: recorder.elapsed)

            // Center: amplitude pulse + elapsed time.
            VStack(spacing: 6) {
                Image(systemName: recorder.isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(progressColor)
                    .scaleEffect(reduceMotion ? 1.0 : (1.0 + recorder.amplitude * 0.4))
                    .iosAppAnimation(.easeOut(duration: 0.12), value: recorder.amplitude)

                Text(timeString)
                    .font(.system(.title2, design: .rounded, weight: .semibold).monospacedDigit())
                    .foregroundStyle(IOSAppTheme.textPrimary)
            }
        }
        .frame(width: 200, height: 200)
    }

    private var clampedProgress: Double {
        min(1.0, recorder.elapsed / IOSReferenceClipRecorder.maxDuration)
    }

    private var progressColor: Color {
        if recorder.elapsed >= IOSReferenceClipRecorder.minDuration && recorder.elapsed <= IOSReferenceClipRecorder.maxDuration {
            return IOSBrandTheme.clone
        }
        if recorder.elapsed > IOSReferenceClipRecorder.maxDuration {
            return Color.orange
        }
        return IOSAppTheme.textTertiary
    }

    private var timeString: String {
        let s = recorder.elapsed
        let whole = Int(s)
        let tenth = Int((s - Double(whole)) * 10)
        return String(format: "%d.%01ds", whole, tenth)
    }

    // MARK: - Status text

    private var statusText: some View {
        Text(statusLabel)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(progressColor)
            .tracking(0.4)
    }

    private var statusLabel: String {
        if !recorder.isRecording && recorder.elapsed == 0 {
            return "Tap the dot to record"
        }
        if recorder.elapsed < IOSReferenceClipRecorder.minDuration {
            return "Keep recording. 10 second minimum."
        }
        if recorder.elapsed <= IOSReferenceClipRecorder.maxDuration {
            return "Sounds good. Tap stop when ready."
        }
        return "Over 20 seconds. Stop now."
    }

    // MARK: - Guidance

    private var guidance: some View {
        Text("Read at a natural pace. A varied 10-20 second sample gives the cleanest clone.")
            .font(.footnote)
            .foregroundStyle(IOSAppTheme.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 32)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            if recorder.isRecording {
                IOSPrimaryCTAButton(
                    title: "Stop",
                    symbol: "stop.fill",
                    tint: IOSBrandTheme.clone,
                    isEnabled: true,
                    action: {
                        if let url = recorder.stopAndSave() {
                            onComplete(url)
                        }
                    }
                )
            } else if recorder.elapsed > 0 {
                Button("Retake") {
                    recorder.reset()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(IOSAppTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background {
                    Capsule(style: .continuous)
                        .fill(IOSAppTheme.glassSurfaceFillMuted)
                }
                .buttonStyle(.plain)

                let canUse = recorder.elapsed >= IOSReferenceClipRecorder.minDuration
                IOSPrimaryCTAButton(
                    title: canUse ? "Use this clip" : "Need 10 s",
                    symbol: canUse ? "checkmark" : nil,
                    tint: IOSBrandTheme.clone,
                    isEnabled: canUse,
                    action: {
                        if let url = recorder.lastSavedURL {
                            onComplete(url)
                        }
                    }
                )
            } else {
                IOSPrimaryCTAButton(
                    title: "Record",
                    symbol: "mic.fill",
                    tint: IOSBrandTheme.clone,
                    isEnabled: !recorder.permissionDenied,
                    action: {
                        Task { await recorder.start() }
                    }
                )
            }
        }
    }
}

// MARK: - Recorder

@MainActor
final class IOSReferenceClipRecorder: NSObject, ObservableObject {
    static let minDuration: Double = 10.0
    static let maxDuration: Double = 20.0

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var amplitude: Double = 0
    @Published var showsPermissionAlert: Bool = false
    @Published private(set) var permissionDenied: Bool = false
    @Published private(set) var lastSavedURL: URL?

    private var recorder: AVAudioRecorder?
    private var meteringTimer: Timer?
    private var startedAt: Date?

    func requestPermissionIfNeeded() async {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            _ = await AVAudioApplication.requestRecordPermission()
        case .denied:
            permissionDenied = true
            showsPermissionAlert = true
        case .granted:
            permissionDenied = false
        @unknown default:
            break
        }
    }

    func start() async {
        guard !isRecording else { return }

        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            permissionDenied = true
            showsPermissionAlert = true
            return
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                permissionDenied = true
                showsPermissionAlert = true
                return
            }
        case .granted:
            break
        @unknown default:
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true, options: [])

            let url = makeOutputURL()
            // 24 kHz mono Int16 PCM matches the Vocello clone-reference
            // contract; AVAudioRecorder writes a WAV (since the extension
            // is .wav) and the platform handles any required downsampling
            // from the hardware rate.
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.delegate = self
            guard recorder.record(forDuration: Self.maxDuration + 0.5) else {
                return
            }

            self.recorder = recorder
            self.isRecording = true
            self.startedAt = Date()
            self.elapsed = 0
            self.amplitude = 0
            startMetering()
        } catch {
            isRecording = false
        }
    }

    @discardableResult
    func stopAndSave() -> URL? {
        guard let recorder else { return nil }
        recorder.stop()
        meteringTimer?.invalidate()
        meteringTimer = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
        lastSavedURL = recorder.url
        return recorder.url
    }

    func stopWithoutSaving() {
        recorder?.stop()
        if let url = recorder?.url {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        meteringTimer?.invalidate()
        meteringTimer = nil
        isRecording = false
        elapsed = 0
        amplitude = 0
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func reset() {
        stopWithoutSaving()
        lastSavedURL = nil
    }

    private func startMetering() {
        meteringTimer?.invalidate()
        meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.tickMeter()
            }
        }
    }

    private func tickMeter() {
        guard let recorder, let startedAt else { return }
        recorder.updateMeters()
        // averagePower is in dBFS (-160 ... 0). Map to 0...1 with light
        // gamma so the meter feels visually responsive without overshooting
        // on loud speech.
        let dB = Double(recorder.averagePower(forChannel: 0))
        let normalized = pow(max(0, (dB + 50) / 50), 1.4)
        amplitude = min(1.0, normalized)
        elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= Self.maxDuration + 0.4 {
            // Hardware cap reached; auto-stop and keep the WAV.
            _ = stopAndSave()
        }
    }

    private func makeOutputURL() -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-clone-references", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return tmp.appendingPathComponent("reference-\(stamp).wav", isDirectory: false)
    }
}

extension IOSReferenceClipRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.meteringTimer?.invalidate()
            self.meteringTimer = nil
            self.isRecording = false
            if flag {
                self.lastSavedURL = recorder.url
            }
        }
    }
}
