import SwiftUI

/// Sheet for batch TTS generation — one line per generation.
struct BatchGenerationSheet: View {
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @Environment(\.dismiss) private var dismiss

    let mode: GenerationMode
    let tier: ModelTier
    var voice: String?
    var emotion: String?
    var speed: Double?
    var voiceDescription: String?
    var refAudio: String?
    var refText: String?

    @State private var batchText = ""
    @State private var isProcessing = false
    @State private var currentIndex = 0
    @State private var totalItems = 0
    @State private var errorMessage: String?
    @State private var cancelled = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Batch Generation")
                .font(.title2.bold())

            Text("Enter one text per line, or drag a .txt file")
                .font(.caption)
                .foregroundColor(.secondary)

            TextEditor(text: $batchText)
                .font(.body)
                .frame(minHeight: 200)
                .border(Color.gray.opacity(0.3))
                .disabled(isProcessing)

            if isProcessing {
                VStack(spacing: 8) {
                    ProgressView(value: Double(currentIndex), total: Double(totalItems))
                    Text("Generating \(currentIndex)/\(totalItems)...")
                        .font(.caption)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            HStack {
                Button("Cancel") {
                    if isProcessing {
                        cancelled = true
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isProcessing ? "Processing..." : "Generate All") {
                    startBatch()
                }
                .buttonStyle(.borderedProminent)
                .disabled(batchText.isEmpty || isProcessing)
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

    private func startBatch() {
        let lines = batchText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return }

        isProcessing = true
        totalItems = lines.count
        currentIndex = 0
        cancelled = false
        errorMessage = nil

        Task {
            guard let model = TTSModel.model(for: mode, tier: tier) else {
                errorMessage = "Model not found"
                isProcessing = false
                return
            }

            do {
                try await pythonBridge.loadModel(id: model.id)

                for (i, line) in lines.enumerated() {
                    if cancelled { break }
                    currentIndex = i + 1

                    let outputPath = makeOutputPath(
                        subfolder: model.mode == .clone ? "Clones" : (model.mode == .design ? "VoiceDesign" : "CustomVoice"),
                        text: line
                    )

                    switch mode {
                    case .custom:
                        _ = try await pythonBridge.generateCustom(
                            text: line,
                            voice: voice ?? "vivian",
                            emotion: emotion ?? "Normal tone",
                            speed: speed ?? 1.0,
                            outputPath: outputPath
                        )
                    case .design:
                        _ = try await pythonBridge.generateDesign(
                            text: line,
                            voiceDescription: voiceDescription ?? "",
                            outputPath: outputPath
                        )
                    case .clone:
                        if let refAudio {
                            _ = try await pythonBridge.generateClone(
                                text: line,
                                refAudio: refAudio,
                                refText: refText,
                                outputPath: outputPath
                            )
                        }
                    }

                    // Save to history
                    var gen = Generation(
                        text: line,
                        mode: mode.rawValue,
                        modelTier: tier.rawValue,
                        voice: voice ?? voiceDescription,
                        emotion: emotion,
                        speed: speed,
                        audioPath: outputPath,
                        duration: nil,
                        createdAt: Date()
                    )
                    try? DatabaseService.shared.saveGeneration(&gen)
                }
            } catch {
                errorMessage = error.localizedDescription
            }

            isProcessing = false
            if !cancelled {
                dismiss()
            }
        }
    }
}
