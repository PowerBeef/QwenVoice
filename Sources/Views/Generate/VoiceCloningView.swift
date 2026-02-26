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
    @State private var savedVoices: [Voice] = []
    @State private var selectedVoice: Voice?
    @State private var isDragOver = false
    @State private var showingBatch = false

    private var isModelDownloaded: Bool {
        guard let model = TTSModel.model(for: .clone) else { return false }
        let modelDir = QwenVoiceApp.modelsDir.appendingPathComponent(model.folder)
        return FileManager.default.fileExists(atPath: modelDir.path)
    }

    private var modelDisplayName: String {
        TTSModel.model(for: .clone)?.name ?? "Unknown"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Text to Speech")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(1.5)

                        Text("Voice Cloning")
                            .font(.system(size: 38, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: Color.black.opacity(0.3), radius: 10, y: 5)
                            .accessibilityIdentifier("voiceCloning_title")
                    }
                    
                    Spacer()

                    Button {
                        showingBatch = true
                    } label: {
                        Label("Batch", systemImage: "square.grid.2x2.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.voiceCloning)
                    .disabled(!pythonBridge.isReady || referenceAudioPath == nil || !isModelDownloaded)
                    .accessibilityIdentifier("voiceCloning_batchButton")
                }
                .padding(.bottom, 8)

                if !isModelDownloaded {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Model \"\(modelDisplayName)\" is not downloaded.")
                            .font(.callout)
                        Spacer()
                        Button {
                            NotificationCenter.default.post(name: .navigateToModels, object: nil)
                        } label: {
                            HStack(spacing: 3) {
                                Text("Go to Models")
                                Image(systemName: "chevron.right")
                                    .imageScale(.small)
                            }
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Color.orange)
                        }
                        .buttonStyle(.plain)
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

                // Controls card
                VStack(alignment: .leading, spacing: 24) {
                    // Saved voices picker
                    if !savedVoices.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("SAVED VOICES").sectionHeader(color: AppTheme.voiceCloning)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(savedVoices) { voice in
                                        Button {
                                            withAnimation(.spring()) {
                                                selectSavedVoice(voice)
                                            }
                                        } label: {
                                            VStack(spacing: 8) {
                                                Image(systemName: "waveform")
                                                    .font(.title2)
                                                    .foregroundStyle(AppTheme.voiceCloning)
                                                Text(voice.name)
                                                    .font(.caption.weight(.medium))
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 12)
                                            .frame(minWidth: 100)
                                            .background(
                                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                    .fill(selectedVoice?.id == voice.id ? AppTheme.voiceCloning.opacity(0.15) : Color.primary.opacity(0.04))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                    .stroke(selectedVoice?.id == voice.id ? AppTheme.voiceCloning : Color.primary.opacity(0.08), lineWidth: 1)
                                            )
                                            .shadow(color: selectedVoice?.id == voice.id ? AppTheme.voiceCloning.opacity(0.1) : .clear, radius: 4, y: 2)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 4)
                            }
                        }
                        
                        Divider().opacity(0.5)
                    }

                    // Reference audio drop zone
                    VStack(alignment: .leading, spacing: 12) {
                        Text("REFERENCE AUDIO").sectionHeader(color: AppTheme.voiceCloning)

                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(isDragOver ? AppTheme.voiceCloning.opacity(0.15) : Color.white.opacity(0.02))
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(.ultraThinMaterial)
                                )
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(
                                    AppTheme.voiceCloning.opacity(isDragOver ? 0.8 : 0.4),
                                    style: StrokeStyle(lineWidth: isDragOver ? 2 : 1.5, dash: [8, 8])
                                )
                                .shadow(color: isDragOver ? AppTheme.voiceCloning.opacity(0.15) : .clear, radius: 8, y: 3)
                                .frame(height: 120)

                            if let path = referenceAudioPath {
                                HStack(spacing: 16) {
                                    Image(systemName: "waveform.circle.fill")
                                        .font(.system(size: 40))
                                        .foregroundColor(AppTheme.voiceCloning)
                                        .symbolEffect(.bounce, value: referenceAudioPath)
                                        
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(URL(fileURLWithPath: path).lastPathComponent)
                                            .font(.headline)
                                            .lineLimit(1)
                                        Text("Ready for cloning")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Button {
                                        withAnimation {
                                            clearReference()
                                        }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.title2)
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 24)
                            } else {
                                VStack(spacing: 12) {
                                    Image(systemName: "waveform.badge.plus")
                                        .font(.system(size: 32))
                                        .foregroundColor(AppTheme.voiceCloning.opacity(0.6))
                                    Text("Drop reference audio file here, or click to browse")
                                        .font(.callout.weight(.medium))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .frame(height: 120)
                        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
                            handleDrop(providers)
                        }
                        .onTapGesture {
                            browseForAudio()
                        }
                        .accessibilityIdentifier("voiceCloning_dropZone")
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragOver)
                        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: referenceAudioPath)
                    }

                    // Transcript
                    VStack(alignment: .leading, spacing: 12) {
                        Text("TRANSCRIPT").sectionHeader(color: AppTheme.voiceCloning)
                        TextField("Type exactly what the reference audio says (improves quality)", text: $referenceTranscript)
                            .textFieldStyle(.plain)
                            .font(.title3)
                            .padding(16)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                            .accessibilityIdentifier("voiceCloning_transcriptField")
                    }

                    Divider().opacity(0.5)

                    TextInputView(
                        text: $text,
                        isGenerating: isGenerating,
                        buttonColor: AppTheme.voiceCloning,
                        onGenerate: generate
                    )
                    .disabled(!pythonBridge.isReady || !isModelDownloaded)
                }
                .glassCard()

                AudioPlayerBar()

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
            .contentColumn()
        }
        .task {
            await loadSavedVoices()
        }
        .sheet(isPresented: $showingBatch) {
            BatchGenerationSheet(
                mode: .clone,
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

        if let model = TTSModel.model(for: .clone) {
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
                guard let model = TTSModel.model(for: .clone) else {
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
                    modelTier: "pro",
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
