import SwiftUI

struct CustomVoiceView: View {
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel

    @State private var selectedSpeaker = "vivian"
    @State private var emotion = "Normal tone"
    @State private var speed: Double = 1.0
    @State private var text = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var showingBatch = false

    private var isModelDownloaded: Bool {
        guard let model = TTSModel.model(for: .custom) else { return false }
        let modelDir = QwenVoiceApp.modelsDir.appendingPathComponent(model.folder)
        return FileManager.default.fileExists(atPath: modelDir.path)
    }

    private var modelDisplayName: String {
        TTSModel.model(for: .custom)?.name ?? "Unknown"
    }

    private let speeds: [(String, Double)] = [
        ("Slow (0.8x)", 0.8),
        ("Normal (1.0x)", 1.0),
        ("Fast (1.3x)", 1.3),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header with model picker and batch button
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Text to Speech")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        
                        Text("Custom Voice")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(colors: [AppTheme.customVoice, AppTheme.customVoice.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .accessibilityIdentifier("customVoice_title")
                    }
                    
                    Spacer()

                    Button {
                        showingBatch = true
                    } label: {
                        Label("Batch", systemImage: "square.grid.2x2.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.customVoice)
                    .disabled(!pythonBridge.isReady || !isModelDownloaded)
                    .accessibilityIdentifier("customVoice_batchButton")
                }
                .padding(.bottom, 8)

                if !isModelDownloaded {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Model \"\(modelDisplayName)\" is not downloaded.")
                            .font(.callout)
                        Spacer()
                        Button("Go to Models") {
                            NotificationCenter.default.post(name: .navigateToModels, object: nil)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("customVoice_goToModels")
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.orange.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
                    .accessibilityIdentifier("customVoice_modelBanner")
                }

                // Controls card
                VStack(alignment: .leading, spacing: 24) {
                    // Speaker picker
                    VStack(alignment: .leading, spacing: 16) {
                        Text("SPEAKER").sectionHeader(color: AppTheme.customVoice)

                        FlowLayout(spacing: 8) {
                            ForEach(TTSModel.speakers, id: \.self) { speaker in
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        selectedSpeaker = speaker
                                    }
                                } label: {
                                    Text(speaker)
                                        .chipStyle(isSelected: selectedSpeaker == speaker, color: AppTheme.customVoice)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("customVoice_speaker_\(speaker)")
                            }
                        }
                        .padding(.vertical, 8)
                    }

                    Divider().opacity(0.5)

                    // Emotion
                    EmotionPickerView(emotion: $emotion)
                    
                    Divider().opacity(0.5)

                    // Speed
                    VStack(alignment: .leading, spacing: 12) {
                        Text("SPEED").sectionHeader(color: AppTheme.customVoice)
                        Picker("Speed", selection: $speed) {
                            ForEach(speeds, id: \.1) { label, value in
                                Text(label).tag(value)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 380)
                        .accessibilityIdentifier("customVoice_speedPicker")
                    }
                }
                .glassCard()

                // Text input + Generate
                TextInputView(
                    text: $text,
                    isGenerating: isGenerating,
                    buttonColor: AppTheme.customVoice,
                    onGenerate: generate
                )
                .disabled(!pythonBridge.isReady || !isModelDownloaded)

                // Error display
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                        .font(.callout)
                }

                // Progress
                if isGenerating {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(pythonBridge.progressMessage.isEmpty ? "Generating..." : pythonBridge.progressMessage)
                            .foregroundColor(.secondary)
                    }
                }

                if !pythonBridge.isReady {
                    Label("Waiting for backend to start...", systemImage: "hourglass")
                        .foregroundColor(.orange)
                        .font(.callout)
                }
            }
            .padding(24)
            .contentColumn()
        }
        .sheet(isPresented: $showingBatch) {
            BatchGenerationSheet(
                mode: .custom,
                voice: selectedSpeaker,
                emotion: emotion,
                speed: speed
            )
            .environmentObject(pythonBridge)
            .environmentObject(audioPlayer)
        }
    }

    private func generate() {
        guard !text.isEmpty, pythonBridge.isReady else { return }

        // Check if model folder exists
        if let model = TTSModel.model(for: .custom) {
            let modelDir = QwenVoiceApp.modelsDir.appendingPathComponent(model.folder)
            if !FileManager.default.fileExists(atPath: modelDir.path) {
                errorMessage = "Model '\(model.name)' is not downloaded. Go to Settings > Models to download it."
                return
            }
        }

        isGenerating = true
        errorMessage = nil

        Task {
            do {
                guard let model = TTSModel.model(for: .custom) else {
                    errorMessage = "Model configuration not found"
                    isGenerating = false
                    return
                }

                try await pythonBridge.loadModel(id: model.id)

                let outputPath = makeOutputPath(subfolder: "CustomVoice", text: text)
                let result = try await pythonBridge.generateCustom(
                    text: text,
                    voice: selectedSpeaker,
                    emotion: emotion,
                    speed: speed,
                    outputPath: outputPath
                )

                // Save to history
                var gen = Generation(
                    text: text,
                    mode: "custom",
                    modelTier: "pro",
                    voice: selectedSpeaker,
                    emotion: emotion,
                    speed: speed,
                    audioPath: result.audioPath,
                    duration: result.durationSeconds,
                    createdAt: Date()
                )
                try? DatabaseService.shared.saveGeneration(&gen)

                audioPlayer.playFile(result.audioPath, title: String(text.prefix(40)))
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }
}
