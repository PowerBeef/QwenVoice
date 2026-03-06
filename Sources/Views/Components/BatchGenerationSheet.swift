import SwiftUI

/// Sheet for batch TTS generation — one line per generation.
struct BatchGenerationSheet: View {
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject var envManager: PythonEnvironmentManager
    @Environment(\.dismiss) private var dismiss

    let mode: GenerationMode
    var voice: String?
    var emotion: String?
    var speed: Double?
    var voiceDescription: String?
    var refAudio: String?
    var refText: String?

    @State private var batchText = ""
    @StateObject private var coordinator = BatchGenerationCoordinator()

    private var themeColor: Color {
        AppTheme.modeColor(for: mode)
    }

    private var activePythonPath: String? {
        if case .ready(let pythonPath) = envManager.state {
            return pythonPath
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Batch Generation")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            Text("Enter one text per line, or drag a .txt file")
                .font(.caption)
                .foregroundColor(.secondary)

            TextEditor(text: $batchText)
                .font(.body)
                .frame(minHeight: 200)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Color.primary.opacity(0.02))
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .disabled(coordinator.isProcessing)

            if coordinator.isProcessing {
                VStack(spacing: 8) {
                    ProgressView(value: Double(coordinator.currentIndex), total: Double(coordinator.totalItems))
                        .tint(themeColor)
                    Text(progressLabel)
                        .font(.caption)
                }
            }

            if let errorMessage = coordinator.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            HStack {
                Button("Cancel") {
                    coordinator.cancelBatch(
                        pythonPath: activePythonPath,
                        dismiss: { dismiss() }
                    )
                }
                .disabled(coordinator.isCancelling)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(coordinator.isCancelling ? "Cancelling..." : (coordinator.isProcessing ? "Processing..." : "Generate All")) {
                    startBatch()
                }
                .buttonStyle(GlowingGradientButtonStyle(baseColor: themeColor))
                .disabled(batchText.isEmpty || coordinator.isProcessing)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 500, minHeight: 400)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
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

    private var progressLabel: String {
        let total = max(coordinator.totalItems, 1)
        let current = min(coordinator.currentIndex + 1, total)
        return coordinator.isCancelling
            ? "Cancelling after interrupting \(current)/\(total)..."
            : "Generating \(current)/\(total)..."
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
                    speed: speed,
                    voiceDescription: voiceDescription,
                    refAudio: refAudio,
                    refText: refText
                )
            },
            bridge: pythonBridge,
            dismiss: { dismiss() }
        )
    }
}
