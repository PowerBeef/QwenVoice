import SwiftUI
import UniformTypeIdentifiers

struct VoiceCloningView: View {
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel

    @State private var referenceAudioPath: String?
    @State private var referenceTranscript = ""
    @State private var emotion = "Normal tone"
    @State private var speed: Double = 1.0
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

    private var canRunBatch: Bool {
        pythonBridge.isReady && referenceAudioPath != nil && isModelAvailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutConstants.sectionSpacing) {
                    GenerationHeaderView(
                        title: "Voice Cloning",
                        subtitle: "Choose a reference voice, then shape the delivery.",
                        titleAccessibilityIdentifier: "voiceCloning_title",
                        subtitleAccessibilityIdentifier: "voiceCloning_subtitle"
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("voiceCloning_header")

                    if !isModelAvailable {
                        modelUnavailableBanner
                    }

                    StudioSectionCard(
                        title: "Voice",
                        accentColor: AppTheme.voiceCloning,
                        accessibilityIdentifier: "voiceCloning_voiceSetup"
                    ) {
                        VStack(alignment: .leading, spacing: 14) {
                            sourceRow

                            if let savedVoicesLoadError {
                                warningCard(
                                    message: savedVoicesLoadError,
                                    accessibilityIdentifier: "voiceCloning_savedVoicesWarning"
                                ) {
                                    Button("Retry") {
                                        Task { await loadSavedVoices() }
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(AppTheme.voiceCloning)
                                    .controlSize(.small)
                                    .accessibilityIdentifier("voiceCloning_savedVoicesRetry")
                                }
                            }

                            if let transcriptLoadError {
                                warningCard(
                                    message: transcriptLoadError,
                                    accessibilityIdentifier: "voiceCloning_transcriptWarning"
                                )
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("TRANSCRIPT")
                                    .font(.system(size: 10, weight: .semibold))
                                    .tracking(0.6)
                                    .foregroundStyle(.secondary)

                                TextField("What does the reference audio say? (optional)", text: $referenceTranscript)
                                    .textFieldStyle(.plain)
                                    .font(.caption)
                                    .padding(10)
                                    .background(Color.primary.opacity(0.04))
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                    )
                                    .accessibilityIdentifier("voiceCloning_transcriptField")
                            }
                        }
                    }

                    DeliveryControlsView(
                        emotion: $emotion,
                        speed: $speed,
                        accentColor: AppTheme.voiceCloning
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("voiceCloning_toneSpeed")

                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 12) {
                            TextInputView(
                                text: $text,
                                isGenerating: isGenerating,
                                placeholder: "What should the cloned voice say?",
                                buttonColor: AppTheme.voiceCloning,
                                batchAction: { showingBatch = true },
                                batchDisabled: !canRunBatch,
                                onGenerate: generate
                            )
                            .disabled(!pythonBridge.isReady || !isModelAvailable || referenceAudioPath == nil)

                            if let errorMessage {
                                Label(errorMessage, systemImage: "exclamationmark.triangle")
                                    .foregroundColor(.red)
                                    .font(.callout)
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("voiceCloning_script")
                }
                .padding(LayoutConstants.canvasPadding)
                .contentColumn()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers)
        }
        .overlay(
            isDragOver
                ? RoundedRectangle(cornerRadius: 10)
                    .stroke(AppTheme.voiceCloning.opacity(0.6), lineWidth: 2)
                    .padding(4)
                : nil
        )
        .accessibilityIdentifier("screen_voiceCloning")
        .task {
            if pythonBridge.isReady {
                await loadSavedVoices()
            }
        }
        .onChange(of: pythonBridge.isReady) { _, isReady in
            guard isReady else { return }
            Task { await loadSavedVoices() }
        }
        .sheet(isPresented: $showingBatch) {
            BatchGenerationSheet(
                mode: .clone,
                emotion: emotion,
                speed: speed,
                refAudio: referenceAudioPath,
                refText: referenceTranscript.isEmpty ? nil : referenceTranscript
            )
            .environmentObject(pythonBridge)
            .environmentObject(audioPlayer)
        }
    }

    // MARK: - Source Row

    private var sourceRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("SOURCE")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)

                if !savedVoices.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(savedVoices) { voice in
                                Button {
                                    AppLaunchConfiguration.performAnimated(.spring()) {
                                        selectSavedVoice(voice)
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "waveform")
                                            .font(.system(size: 9, weight: .semibold))
                                        Text(voice.name)
                                            .font(.system(size: 14, weight: .semibold))
                                    }
                                    .voiceChoiceChip(isSelected: selectedVoice?.id == voice.id, color: AppTheme.voiceCloning)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("voiceCloning_savedVoice_\(voice.id)")
                            }
                        }
                    }
                }

                if !savedVoices.isEmpty {
                    Divider()
                        .frame(height: 16)
                }

                Button {
                    browseForAudio()
                } label: {
                    Label("Import audio...", systemImage: "waveform.badge.plus")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(AppTheme.voiceCloning)
                .accessibilityIdentifier("voiceCloning_importButton")
            }

            // Active reference indicator
            if let path = referenceAudioPath {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 52, height: 1)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.voiceCloning)

                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)

                    Text("Ready")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button {
                        AppLaunchConfiguration.performAnimated(.default) {
                            clearReference()
                        }
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .accessibilityIdentifier("voiceCloning_activeReference")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceCloning_sourceRow")
    }

    // MARK: - Model Unavailable Banner

    private var modelUnavailableBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("Model \"\(modelDisplayName)\" is unavailable or incomplete.")
                .font(.caption)
            Spacer()
            Button {
                NotificationCenter.default.post(name: .navigateToModels, object: cloneModel?.id)
            } label: {
                HStack(spacing: 3) {
                    Text("Go to Models")
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.orange)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("voiceCloning_goToModels")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceCloning_modelBanner")
    }

    // MARK: - Generate

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
                guard let model = cloneModel else {
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
                    emotion: emotion,
                    speed: speed,
                    outputPath: outputPath
                )

                let voiceName = selectedVoice?.name ?? URL(fileURLWithPath: refPath).deletingPathExtension().lastPathComponent
                var generation = Generation(
                    text: text,
                    mode: model.mode.rawValue,
                    modelTier: model.tier,
                    voice: voiceName,
                    emotion: emotion,
                    speed: speed,
                    audioPath: result.audioPath,
                    duration: result.durationSeconds,
                    createdAt: Date()
                )
                try persistGenerationAndMaybeAutoplay(&generation, result: result)
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

    // MARK: - Voice Selection

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

    // MARK: - File Handling

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

    // MARK: - Warning Card

    @ViewBuilder
    private func warningCard(
        message: String,
        accessibilityIdentifier: String,
        @ViewBuilder action: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)

            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action()
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.20), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
