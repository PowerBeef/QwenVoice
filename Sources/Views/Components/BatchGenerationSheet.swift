import SwiftUI

/// Sheet for batch TTS generation — one line per generation.
struct BatchGenerationSheet: View {
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @Environment(\.dismiss) private var dismiss

    let mode: GenerationMode
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

    private var themeColor: Color {
        AppTheme.modeColor(for: mode)
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
                .disabled(isProcessing)

            if isProcessing {
                VStack(spacing: 8) {
                    ProgressView(value: Double(currentIndex), total: Double(totalItems))
                        .tint(themeColor)
                    Text("Generating \(min(currentIndex + 1, max(totalItems, 1)))/\(totalItems)...")
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
                .buttonStyle(GlowingGradientButtonStyle(baseColor: themeColor))
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
            guard let model = TTSModel.model(for: mode) else {
                errorMessage = "Model not found"
                isProcessing = false
                return
            }

            guard model.isAvailable(in: QwenVoiceApp.modelsDir) else {
                errorMessage = "Model '\(model.name)' is unavailable or incomplete. Go to Settings > Models to download or re-download it."
                isProcessing = false
                return
            }

            if mode == .design && (voiceDescription ?? "").isEmpty {
                errorMessage = "Enter a voice description before starting batch generation."
                isProcessing = false
                return
            }

            if mode == .clone && refAudio == nil {
                errorMessage = "Select a reference audio file before starting batch generation."
                isProcessing = false
                return
            }

            do {
                for (i, line) in lines.enumerated() {
                    if cancelled { break }

                    let outputPath = makeOutputPath(
                        subfolder: model.mode == .clone ? "Clones" : (model.mode == .design ? "VoiceDesign" : "CustomVoice"),
                        text: line
                    )

                    var result: GenerationResult?
                    switch mode {
                    case .custom:
                        result = try await pythonBridge.generateCustomFlow(
                            modelID: model.id,
                            text: line,
                            voice: voice ?? "vivian",
                            emotion: emotion ?? "Normal tone",
                            speed: speed ?? 1.0,
                            outputPath: outputPath,
                            batchIndex: i + 1,
                            batchTotal: totalItems
                        )
                    case .design:
                        result = try await pythonBridge.generateDesignFlow(
                            modelID: model.id,
                            text: line,
                            voiceDescription: voiceDescription ?? "",
                            outputPath: outputPath,
                            batchIndex: i + 1,
                            batchTotal: totalItems
                        )
                    case .clone:
                        if let refAudio {
                            result = try await pythonBridge.generateCloneFlow(
                                modelID: model.id,
                                text: line,
                                refAudio: refAudio,
                                refText: refText,
                                outputPath: outputPath,
                                batchIndex: i + 1,
                                batchTotal: totalItems
                            )
                        }
                    }

                    guard let result else { continue }

                    // Save to history
                    let voiceName: String? = voice ?? voiceDescription ?? {
                        guard let ref = refAudio else { return nil }
                        return URL(fileURLWithPath: ref).deletingPathExtension().lastPathComponent
                    }()
                    var gen = Generation(
                        text: line,
                        mode: mode.rawValue,
                        modelTier: "pro",
                        voice: voiceName,
                        emotion: emotion,
                        speed: speed,
                        audioPath: result.audioPath,
                        duration: result.durationSeconds,
                        createdAt: Date()
                    )
                    try DatabaseService.shared.saveGeneration(&gen)
                    NotificationCenter.default.post(name: .generationSaved, object: nil)
                    currentIndex = i + 1
                }
            } catch {
                errorMessage = error.localizedDescription
            }

            if cancelled {
                pythonBridge.clearGenerationActivity()
            }
            isProcessing = false
            dismiss()
        }
    }
}
