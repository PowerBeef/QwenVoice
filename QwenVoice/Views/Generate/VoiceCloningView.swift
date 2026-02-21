import SwiftUI
import UniformTypeIdentifiers

struct VoiceCloningView: View {
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel

    @State private var referenceAudioPath: String?
    @State private var referenceTranscript = ""
    @State private var text = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var selectedTier: ModelTier = .pro
    @State private var savedVoices: [Voice] = []
    @State private var selectedVoice: Voice?
    @State private var isDragOver = false
    @State private var showingBatch = false

    private var isModelDownloaded: Bool {
        guard let model = TTSModel.model(for: .clone, tier: selectedTier) else { return false }
        let modelDir = QwenVoiceApp.modelsDir.appendingPathComponent(model.folder)
        return FileManager.default.fileExists(atPath: modelDir.path)
    }

    private var modelDisplayName: String {
        TTSModel.model(for: .clone, tier: selectedTier)?.displayName ?? "Unknown"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Voice Cloning")
                        .font(.title2.bold())
                        .accessibilityIdentifier("voiceCloning_title")
                    Spacer()

                    Button {
                        showingBatch = true
                    } label: {
                        Label("Batch", systemImage: "list.bullet.rectangle")
                    }
                    .disabled(!pythonBridge.isReady || referenceAudioPath == nil || !isModelDownloaded)
                    .accessibilityIdentifier("voiceCloning_batchButton")

                    Picker("Model", selection: $selectedTier) {
                        ForEach(ModelTier.allCases, id: \.self) { tier in
                            Text(tier.displayName).tag(tier)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .accessibilityIdentifier("voiceCloning_tierPicker")
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
                        .accessibilityIdentifier("voiceCloning_goToModels")
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
                    .accessibilityIdentifier("voiceCloning_modelBanner")
                }

                // Saved voices picker
                if !savedVoices.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saved Voices").font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(savedVoices) { voice in
                                    Button {
                                        selectSavedVoice(voice)
                                    } label: {
                                        VStack(spacing: 4) {
                                            Image(systemName: "waveform.circle.fill")
                                                .font(.title2)
                                            Text(voice.name)
                                                .font(.caption)
                                        }
                                        .padding(10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(selectedVoice?.id == voice.id ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(selectedVoice?.id == voice.id ? Color.accentColor : Color.clear, lineWidth: 2)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                // Reference audio drop zone
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reference Audio").font(.headline)

                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                            .foregroundColor(isDragOver ? .accentColor : .gray.opacity(0.4))
                            .frame(height: 100)

                        if let path = referenceAudioPath {
                            HStack {
                                Image(systemName: "waveform")
                                    .foregroundColor(.accentColor)
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    clearReference()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 16)
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: "arrow.down.doc")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                                Text("Drop reference audio file here, or click to browse")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
                        handleDrop(providers)
                    }
                    .onTapGesture {
                        browseForAudio()
                    }
                    .accessibilityIdentifier("voiceCloning_dropZone")
                }

                // Transcript
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcript").font(.headline)
                    TextField("Type exactly what the reference audio says (improves quality)", text: $referenceTranscript)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("voiceCloning_transcriptField")
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
                        Text(pythonBridge.progressMessage.isEmpty ? "Cloning..." : pythonBridge.progressMessage)
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
        .task {
            await loadSavedVoices()
        }
        .sheet(isPresented: $showingBatch) {
            BatchGenerationSheet(
                mode: .clone,
                tier: selectedTier,
                refAudio: referenceAudioPath,
                refText: referenceTranscript.isEmpty ? nil : referenceTranscript
            )
            .environmentObject(pythonBridge)
            .environmentObject(audioPlayer)
        }
    }

    // MARK: - Actions

    private func generate() {
        guard !text.isEmpty, let refPath = referenceAudioPath, pythonBridge.isReady else { return }

        if let model = TTSModel.model(for: .clone, tier: selectedTier) {
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
                guard let model = TTSModel.model(for: .clone, tier: selectedTier) else {
                    errorMessage = "Model configuration not found"
                    isGenerating = false
                    return
                }

                try await pythonBridge.loadModel(id: model.id)

                let outputPath = makeOutputPath(subfolder: "Clones", text: text)
                let result = try await pythonBridge.generateClone(
                    text: text,
                    refAudio: refPath,
                    refText: referenceTranscript.isEmpty ? nil : referenceTranscript,
                    outputPath: outputPath
                )

                let voiceName = selectedVoice?.name ?? URL(fileURLWithPath: refPath).deletingPathExtension().lastPathComponent
                var gen = Generation(
                    text: text,
                    mode: "clone",
                    modelTier: selectedTier.rawValue,
                    voice: voiceName,
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

    private func selectSavedVoice(_ voice: Voice) {
        selectedVoice = voice
        referenceAudioPath = voice.wavPath
        referenceTranscript = voice.transcript ?? ""
    }

    private func clearReference() {
        referenceAudioPath = nil
        referenceTranscript = ""
        selectedVoice = nil
    }

    private func loadSavedVoices() async {
        do {
            savedVoices = try await pythonBridge.listVoices()
        } catch {
            // Silently fail
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in
                referenceAudioPath = url.path
                selectedVoice = nil
            }
        }
        return true
    }

    private func browseForAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .wav, .mp3, .aiff]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            referenceAudioPath = url.path
            selectedVoice = nil
        }
    }
}
