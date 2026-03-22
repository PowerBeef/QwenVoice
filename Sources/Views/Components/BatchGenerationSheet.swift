import SwiftUI

struct BatchGenerationSheet: View {
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject var envManager: PythonEnvironmentManager
    @Environment(\.dismiss) private var dismiss

    let mode: GenerationMode
    var voice: String?
    var emotion: String?
    var deliveryProfile: DeliveryProfile? = nil
    var voiceDescription: String?
    var refAudio: String?
    var refText: String?

    @State private var batchText = ""
    @StateObject private var coordinator = BatchGenerationCoordinator()

    private var themeColor: Color {
        AppTheme.modeColor(for: mode)
    }

    private var deliverySummary: [String] {
        var summary: [String] = []
        if let emotion, !emotion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            summary.append("Tone: \(emotion)")
        }
        return summary
    }

    private var activePythonPath: String? {
        if case .ready(let pythonPath) = envManager.state {
            return pythonPath
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let outcome = coordinator.outcome {
                completionView(outcome: outcome)
            } else {
                editorView
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 440)
        .profileBackground(AppTheme.canvasBackground)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard coordinator.outcome == nil else { return false }
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.pathExtension == "txt",
                      let text = try? String(contentsOf: url, encoding: .utf8)
                else { return }
                Task { @MainActor in
                    batchText = text
                }
            }
            return true
        }
    }

    // MARK: - Editor View

    @ViewBuilder
    private var editorView: some View {
        Text("Batch Generation")
            .font(.title.weight(.bold))

        Text("Enter one line per generation, or drag a `.txt` file onto this sheet.")
            .font(.callout)
            .foregroundStyle(.secondary)

        if !deliverySummary.isEmpty {
            GroupBox("Current delivery") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(deliverySummary, id: \.self) { line in
                        Text(line)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("batch_deliverySummary")
        }

        TextEditor(text: $batchText)
            .font(.body)
            .scrollContentBackground(.hidden)
            .focusEffectDisabled()
            .padding(8)
            .frame(minHeight: 220)
            #if QW_UI_LIQUID
            .background {
                if #available(macOS 26, *) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.clear)
                        .glassEffect(in: .rect(cornerRadius: 10))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(AppTheme.cardStroke.opacity(0.45), lineWidth: 1)
                    }
                }
            }
            #else
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.cardStroke.opacity(0.45), lineWidth: 1)
            )
            #endif
            .disabled(coordinator.isProcessing)

        if coordinator.isProcessing {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: Double(coordinator.currentIndex), total: Double(coordinator.totalItems))
                    .tint(themeColor)
                Text(progressLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }

        if let errorMessage = coordinator.errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .font(.callout)
        }

        HStack {
            Button("Cancel") {
                coordinator.cancelBatch(
                    pythonPath: activePythonPath,
                    dismiss: { dismiss() }
                )
            }
            .buttonStyle(.bordered)
            .disabled(coordinator.isCancelling)
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(coordinator.isCancelling ? "Cancelling..." : (coordinator.isProcessing ? "Processing..." : "Generate All")) {
                startBatch()
            }
            .buttonStyle(.borderedProminent)
            .tint(themeColor)
            .disabled(batchText.isEmpty || coordinator.isProcessing)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Completion View

    @ViewBuilder
    private func completionView(outcome: BatchGenerationOutcome) -> some View {
        Spacer()

        VStack(spacing: 16) {
            let isCompleted = {
                if case .completed = outcome { return true }
                return false
            }()

            Image(systemName: isCompleted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(isCompleted ? .green : .orange)

            Text(isCompleted ? "Batch Complete" : "Batch Cancelled")
                .font(.title2.weight(.bold))

            Text(completionMessage(for: outcome))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)

        Spacer()

        HStack {
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("View in History") {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(
                        name: .navigateToSidebarItem,
                        object: SidebarItem.history
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(themeColor)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Helpers

    private var progressLabel: String {
        let total = max(coordinator.totalItems, 1)
        let current = min(coordinator.currentIndex + 1, total)
        return coordinator.isCancelling
            ? "Cancelling after interrupting \(current)/\(total)..."
            : "Generating \(current)/\(total)..."
    }

    private func completionMessage(for outcome: BatchGenerationOutcome) -> String {
        switch outcome {
        case .completed(let count):
            return count == 1
                ? "1 clip generated successfully."
                : "\(count) clips generated successfully."
        case .cancelled(let count):
            let total = coordinator.totalItems
            if count == 0 {
                return "Generation was cancelled before any clips were created."
            }
            return "\(count) of \(total) clips generated before cancellation."
        }
    }

    private func startBatch() {
        coordinator.startBatch(
            batchText: batchText,
            requestBuilder: { lines in
                guard let model = TTSModel.model(for: mode) else { return nil }
                return BatchGenerationRequest(
                    mode: mode,
                    model: model,
                    lines: lines,
                    voice: voice,
                    emotion: emotion,
                    deliveryProfile: deliveryProfile,
                    voiceDescription: voiceDescription,
                    refAudio: refAudio,
                    refText: refText
                )
            },
            bridge: pythonBridge
        )
    }
}
