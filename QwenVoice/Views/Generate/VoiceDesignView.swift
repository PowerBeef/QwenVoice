import SwiftUI

struct VoiceDesignView: View {
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel

    @State private var voiceDescription = ""
    @State private var text = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var selectedTier: ModelTier = .pro
    @State private var showingBatch = false

    private var isModelDownloaded: Bool {
        guard let model = TTSModel.model(for: .design, tier: selectedTier) else { return false }
        let modelDir = QwenVoiceApp.modelsDir.appendingPathComponent(model.folder)
        return FileManager.default.fileExists(atPath: modelDir.path)
    }

    private var modelDisplayName: String {
        TTSModel.model(for: .design, tier: selectedTier)?.displayName ?? "Unknown"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Voice Design")
                        .font(.title2.bold())
                        .accessibilityIdentifier("voiceDesign_title")
                    Spacer()

                    Button {
                        showingBatch = true
                    } label: {
                        Label("Batch", systemImage: "list.bullet.rectangle")
                    }
                    .disabled(!pythonBridge.isReady || voiceDescription.isEmpty || !isModelDownloaded)
                    .accessibilityIdentifier("voiceDesign_batchButton")

                    Picker("Model", selection: $selectedTier) {
                        ForEach(ModelTier.allCases, id: \.self) { tier in
                            Text(tier.displayName).tag(tier)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .accessibilityIdentifier("voiceDesign_tierPicker")
                }

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
                        .accessibilityIdentifier("voiceDesign_goToModels")
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
                    .accessibilityIdentifier("voiceDesign_modelBanner")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Voice Description").font(.headline)
                    TextField("Describe the voice you want, e.g. 'A warm, deep male voice with a British accent'", text: $voiceDescription, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("voiceDesign_descriptionField")
                }

                TextInputView(
                    text: $text,
                    isGenerating: isGenerating,
                    onGenerate: generate
                )
                .disabled(!pythonBridge.isReady || !isModelDownloaded)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                        .font(.callout)
                }

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
        }
        .sheet(isPresented: $showingBatch) {
            BatchGenerationSheet(
                mode: .design,
                tier: selectedTier,
                voiceDescription: voiceDescription
            )
            .environmentObject(pythonBridge)
            .environmentObject(audioPlayer)
        }
    }

    private func generate() {
        guard !text.isEmpty, !voiceDescription.isEmpty, pythonBridge.isReady else { return }

        if let model = TTSModel.model(for: .design, tier: selectedTier) {
            let modelDir = QwenVoiceApp.modelsDir.appendingPathComponent(model.folder)
            if !FileManager.default.fileExists(atPath: modelDir.path) {
                errorMessage = "Model '\(model.displayName)' is not downloaded. Go to Settings > Models to download it."
                return
            }
        }

        isGenerating = true
        errorMessage = nil

        Task {
            do {
                guard let model = TTSModel.model(for: .design, tier: selectedTier) else {
                    errorMessage = "Model configuration not found"
                    isGenerating = false
                    return
                }

                try await pythonBridge.loadModel(id: model.id)

                let outputPath = makeOutputPath(subfolder: "VoiceDesign", text: text)
                let result = try await pythonBridge.generateDesign(
                    text: text,
                    voiceDescription: voiceDescription,
                    outputPath: outputPath
                )

                var gen = Generation(
                    text: text,
                    mode: "design",
                    modelTier: selectedTier.rawValue,
                    voice: voiceDescription,
                    emotion: nil,
                    speed: nil,
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
