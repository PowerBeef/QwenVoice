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
    @State private var savedVoicesLoadError: String?
    @State private var transcriptLoadError: String?
    @State private var savedVoices: [Voice] = []
    @State private var selectedVoice: Voice?
    @State private var isDragOver = false
    @State private var showingBatch = false

    private var cloneModel: TTSModel? {
        TTSModel.model(for: .clone)
    }

    private var isModelAvailable: Bool {
        cloneModel?.isAvailable(in: QwenVoiceApp.modelsDir) ?? false
    }

    private var modelDisplayName: String {
        cloneModel?.name ?? "Unknown"
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
                    .disabled(!pythonBridge.isReady || referenceAudioPath == nil || !isModelAvailable)
                    .accessibilityIdentifier("voiceCloning_batchButton")
                }
                .padding(.bottom, 8)

                if !isModelAvailable {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Model \"\(modelDisplayName)\" is unavailable or incomplete.")
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
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("voiceCloning_modelBanner")
                }

                // Controls card
                VStack(alignment: .leading, spacing: 24) {
                    // Saved voices picker
                    if !savedVoices.isEmpty || savedVoicesLoadError != nil || transcriptLoadError != nil {
                        VStack(alignment: .leading, spacing: 12) {
                            if !savedVoices.isEmpty {
                                Text("SAVED VOICES").sectionHeader()
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(savedVoices) { voice in
                                            Button {
                                                AppLaunchConfiguration.performAnimated(.spring()) {
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
                                            .accessibilityIdentifier("voiceCloning_savedVoice_\(voice.id)")
                                        }
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 4)
                                }
                            }

                            if let savedVoicesLoadError {
                                warningCard(
                                    message: savedVoicesLoadError,
                                    accessibilityIdentifier: "voiceCloning_savedVoicesWarning"
                                ) {
                                    Button("Retry") {
                                        Task {
                                            await loadSavedVoices()
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(AppTheme.voiceCloning)
                                    .accessibilityIdentifier("voiceCloning_savedVoicesRetry")
                                }
                            }

                            if let transcriptLoadError {
                                warningCard(
                                    message: transcriptLoadError,
                                    accessibilityIdentifier: "voiceCloning_transcriptWarning"
                                )
                            }
                        }

                        Divider().opacity(0.5)
                    }

                    // Reference audio drop zone
                    VStack(alignment: .leading, spacing: 12) {
                        Text("REFERENCE AUDIO").sectionHeader()

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
                                        AppLaunchConfiguration.performAnimated(.default) {
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
                        .appAnimation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragOver)
                        .appAnimation(.spring(response: 0.4, dampingFraction: 0.7), value: referenceAudioPath)

                        Text("Best results usually come from a clean 10-20 second reference clip.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Transcript
                    VStack(alignment: .leading, spacing: 12) {
                        Text("TRANSCRIPT").sectionHeader()
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
                    .disabled(!pythonBridge.isReady || !isModelAvailable || referenceAudioPath == nil)
                }
                .glassCard()

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                        .font(.callout)
                }

            }
            .padding(24)
            .contentColumn()
        }
        .accessibilityIdentifier("screen_voiceCloning")
        .task {
            if pythonBridge.isReady {
                await loadSavedVoices()
            }
        }
        .onChange(of: pythonBridge.isReady) { _, isReady in
            guard isReady else { return }
            Task {
                await loadSavedVoices()
            }
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
        guard !text.isEmpty else { return }
        guard let refPath = referenceAudioPath else {
            errorMessage = "Select a reference audio file before generating."
            return
        }
        guard pythonBridge.isReady else { return }

        if let model = cloneModel, !model.isAvailable(in: QwenVoiceApp.modelsDir) {
            errorMessage = "Model '\(model.name)' is unavailable or incomplete. Go to Settings > Models to download or re-download it."
            return
        }

        isGenerating = true
        errorMessage = nil

        Task {
            do {
                UITestAutomationSupport.recordAction("clone-generate-start", appSupportDir: QwenVoiceApp.appSupportDir)
                guard let model = TTSModel.model(for: .clone) else {
                    errorMessage = "Model configuration not found"
                    isGenerating = false
                    return
                }

                let outputPath = makeOutputPath(subfolder: model.outputSubfolder, text: text)
                audioPlayer.prepareStreamingPreview(
                    title: String(text.prefix(40)),
                    shouldAutoPlay: AudioService.shouldAutoPlay
                )
                let result = try await pythonBridge.generateCloneStreamingFlow(
                    modelID: model.id,
                    text: text,
                    refAudio: refPath,
                    refText: referenceTranscript.isEmpty ? nil : referenceTranscript,
                    outputPath: outputPath
                )

                let voiceName = selectedVoice?.name ?? URL(fileURLWithPath: refPath).deletingPathExtension().lastPathComponent
                var gen = Generation(
                    text: text,
                    mode: model.mode.rawValue,
                    modelTier: model.tier,
                    voice: voiceName,
                    emotion: nil,
                    speed: nil,
                    audioPath: result.audioPath,
                    duration: result.durationSeconds,
                    createdAt: Date()
                )
                try persistGenerationAndMaybeAutoplay(&gen, result: result)
                UITestAutomationSupport.recordAction("clone-generate-success", appSupportDir: QwenVoiceApp.appSupportDir)
            } catch {
                UITestAutomationSupport.recordAction("clone-generate-error", appSupportDir: QwenVoiceApp.appSupportDir)
                audioPlayer.abortLivePreviewIfNeeded()
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }

    private func persistGenerationAndMaybeAutoplay(_ generation: inout Generation, result: GenerationResult) throws {
        var persistenceError: Error?
        do {
            let saveStart = DispatchTime.now().uptimeNanoseconds
            try DatabaseService.shared.saveGeneration(&generation)
            #if DEBUG
            print("[Performance][VoiceCloningView] db_save_wall_ms=\(elapsedMs(since: saveStart))")
            #endif

            let notificationStart = DispatchTime.now().uptimeNanoseconds
            NotificationCenter.default.post(name: .generationSaved, object: nil)
            #if DEBUG
            print("[Performance][VoiceCloningView] history_notification_wall_ms=\(elapsedMs(since: notificationStart))")
            #endif
        } catch {
            persistenceError = error
        }

        if result.usedStreaming {
            audioPlayer.completeStreamingPreview(
                result: result,
                title: String(text.prefix(40)),
                shouldAutoPlay: AudioService.shouldAutoPlay
            )
        } else if AudioService.shouldAutoPlay {
            let autoplayStart = DispatchTime.now().uptimeNanoseconds
            audioPlayer.playFile(result.audioPath, title: String(text.prefix(40)))
            #if DEBUG
            print("[Performance][VoiceCloningView] autoplay_start_wall_ms=\(elapsedMs(since: autoplayStart))")
            #endif
        }

        if let persistenceError {
            throw persistenceError
        }
    }

    private func elapsedMs(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    private func selectSavedVoice(_ voice: Voice) {
        selectedVoice = voice
        referenceAudioPath = voice.wavPath
        savedVoicesLoadError = nil
        do {
            referenceTranscript = try voice.loadTranscript() ?? ""
            transcriptLoadError = nil
        } catch {
            referenceTranscript = ""
            transcriptLoadError = "Couldn't load the saved transcript for \"\(voice.name)\". You can still clone from the audio file alone."
        }
    }

    private func clearReference() {
        referenceAudioPath = nil
        referenceTranscript = ""
        selectedVoice = nil
        transcriptLoadError = nil
    }

    private func loadSavedVoices() async {
        do {
            let loadedVoices = try await pythonBridge.listVoices()
            savedVoices = loadedVoices
            savedVoicesLoadError = nil
        } catch {
            savedVoicesLoadError = "Couldn't load saved voices right now. You can still clone from a file. \(error.localizedDescription)"
        }
    }

    private static let allowedAudioExtensions: Set<String> = [
        "wav", "mp3", "aiff", "aif", "m4a", "flac", "ogg"
    ]

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            let ext = url.pathExtension.lowercased()
            guard Self.allowedAudioExtensions.contains(ext) else {
                Task { @MainActor in
                    errorMessage = "Unsupported file type '.\(ext)'. Drop an audio file (WAV, MP3, AIFF, M4A, FLAC, or OGG)."
                }
                return
            }
            Task { @MainActor in
                referenceAudioPath = url.path
                selectedVoice = nil
                transcriptLoadError = nil
            }
        }
        return true
    }

    private func browseForAudio() {
        if UITestAutomationSupport.isStubBackendMode,
           let url = UITestAutomationSupport.importAudioURL {
            referenceAudioPath = url.path
            selectedVoice = nil
            transcriptLoadError = nil
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .wav, .mp3, .aiff]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            referenceAudioPath = url.path
            selectedVoice = nil
            transcriptLoadError = nil
        }
    }

    @ViewBuilder
    private func warningCard(
        message: String,
        accessibilityIdentifier: String,
        @ViewBuilder action: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                action()
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
