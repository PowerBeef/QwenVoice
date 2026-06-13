import SwiftUI
import QwenVoiceCore

/// Configuration for a batch run, presented via `.sheet(item:)`. Carries the
/// lines plus mode-specific builders so `IOSBatchSheet` can drive the
/// `IOSBatchGenerationCoordinator` without knowing about Custom vs Design.
struct IOSBatchConfig: Identifiable {
    let id = UUID()
    let lines: [String]
    let tint: Color
    let modeLabel: String
    let outputSubfolder: String
    let caller: String
    let makeRequest: (_ line: String, _ index: Int, _ total: Int, _ seed: UInt64, _ outputPath: String) -> GenerationRequest
    let makeGeneration: (_ line: String, _ result: GenerationResult) -> Generation
}

/// Batch progress sheet: a per-line list with live status, an overall progress
/// bar, and Cancel / Done. Generation runs headlessly (no per-item playback) via
/// `IOSBatchGenerationCoordinator`.
struct IOSBatchSheet: View {
    let config: IOSBatchConfig
    let onClose: () -> Void

    @EnvironmentObject private var ttsEngine: TTSEngineStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @StateObject private var coordinator = IOSBatchGenerationCoordinator()

    var body: some View {
        VStack(spacing: 0) {
            header
            progressBar
            list
            footer
        }
        .background(Color(red: 13 / 255, green: 14 / 255, blue: 18 / 255).ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(28)
        .interactiveDismissDisabled(coordinator.isRunning)
        .onAppear { startIfNeeded() }
        .onDisappear { coordinator.cancel() }
    }

    private func startIfNeeded() {
        coordinator.start(
            lines: config.lines,
            audioPlayer: audioPlayer,
            ttsEngine: ttsEngine,
            outputSubfolder: config.outputSubfolder,
            caller: config.caller,
            makeRequest: config.makeRequest,
            makeGeneration: config.makeGeneration
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Batch")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                Text("\(config.modeLabel) · \(config.lines.count) takes")
                    .font(.system(size: 13))
                    .foregroundStyle(IOSAppTheme.textSecondary)
            }
            Spacer()
            if coordinator.didFinish {
                Button("Done") { onClose() }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(config.tint)
                    .accessibilityIdentifier("batchSheet_done")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }

    // MARK: - Progress

    private var progressBar: some View {
        VStack(spacing: 6) {
            ProgressView(value: coordinator.progress)
                .tint(config.tint)
            HStack {
                Text("\(coordinator.completedCount) of \(coordinator.total) done")
                Spacer()
                if coordinator.didFinish {
                    Text("\(coordinator.succeededCount) succeeded")
                }
            }
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(IOSAppTheme.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Batch progress")
        .accessibilityValue("\(coordinator.completedCount) of \(coordinator.total) done")
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(coordinator.items) { item in
                    IOSBatchRow(item: item, tint: config.tint)
                    if item.id != coordinator.items.last?.id {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 0.5)
                            .padding(.leading, 20)
                    }
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if coordinator.isRunning {
            Button {
                coordinator.cancel()
            } label: {
                Text("Cancel")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background {
                        Capsule(style: .continuous).fill(IOSAppTheme.glassSurfaceFillMuted)
                    }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .accessibilityIdentifier("batchSheet_cancel")
        }
    }
}

private struct IOSBatchRow: View {
    let item: IOSBatchGenerationCoordinator.Item
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 24, height: 24)
            Text(item.text)
                .font(.system(size: 15))
                .foregroundStyle(IOSAppTheme.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Line \(item.index + 1): \(item.text)")
        .accessibilityValue(statusAccessibilityValue)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 16))
                .foregroundStyle(IOSAppTheme.textTertiary)
        case .generating:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(red: 0.19, green: 0.82, blue: 0.35))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle")
                .font(.system(size: 16))
                .foregroundStyle(IOSAppTheme.textTertiary)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.status {
        case .done(let duration):
            Text(String(format: "%.1fs", duration))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(IOSAppTheme.textSecondary)
        case .failed(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(1)
                .frame(maxWidth: 120, alignment: .trailing)
        default:
            EmptyView()
        }
    }

    private var statusAccessibilityValue: String {
        switch item.status {
        case .pending: return "Pending"
        case .generating: return "Generating"
        case .done(let duration): return String(format: "Done, %.1f seconds", duration)
        case .failed(let message): return "Failed: \(message)"
        case .cancelled: return "Cancelled"
        }
    }
}
