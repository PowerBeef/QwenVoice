import SwiftUI
import UniformTypeIdentifiers

struct VoiceCloningView: View {
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject var modelManager: ModelManagerViewModel

    @State private var referenceAudioPath: String?
    @State private var referenceTranscript = ""
    @State private var emotion = "Normal tone"
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
        guard let cloneModel else { return false }
        return modelManager.isAvailable(cloneModel)
    }

    private var modelDisplayName: String {
        cloneModel?.name ?? "Unknown"
    }

    private var canGenerate: Bool {
        pythonBridge.isReady && isModelAvailable && referenceAudioPath != nil && !text.isEmpty
    }

    private var canRunBatch: Bool {
        pythonBridge.isReady && referenceAudioPath != nil && isModelAvailable
    }

    private var idlePrewarmTaskID: String {
        "\(pythonBridge.isReady)-\(cloneModel?.id ?? "none")-\(referenceAudioPath ?? "none")-\(isModelAvailable)"
    }

    private var selectedSavedVoiceID: Binding<String?> {
        Binding(
            get: { selectedVoice?.id },
            set: { newID in
                guard let newID else {
                    if selectedVoice != nil {
                        clearReference()
                    }
                    return
                }

                guard let voice = savedVoices.first(where: { $0.id == newID }) else { return }
                selectSavedVoice(voice)
            }
        )
    }

    var body: some View {
        PageScaffold(
            accessibilityIdentifier: "screen_voiceCloning",
            fillsViewportHeight: true,
            contentSpacing: LayoutConstants.generationSectionSpacing,
            contentMaxWidth: LayoutConstants.generationContentMaxWidth,
            topPadding: LayoutConstants.generationPageTopPadding,
            bottomPadding: LayoutConstants.generationPageBottomPadding
        ) {
            configurationPanel
            composerPanel
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers)
        }
        .overlay(
            isDragOver
                ? RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.voiceCloning.opacity(0.5), lineWidth: 2)
                    .padding(8)
                : nil
        )
        .task {
            if pythonBridge.isReady {
                await loadSavedVoices()
            }
        }
        .onChange(of: pythonBridge.isReady) { _, isReady in
            guard isReady else { return }
            Task { await loadSavedVoices() }
        }
        .task(id: idlePrewarmTaskID) {
            await prewarmCloneModelIfNeeded()
        }
        .sheet(isPresented: $showingBatch) {
            BatchGenerationSheet(
                mode: .clone,
                emotion: emotion,
                refAudio: referenceAudioPath,
                refText: referenceTranscript.isEmpty ? nil : referenceTranscript
            )
            .environmentObject(pythonBridge)
            .environmentObject(audioPlayer)
        }
    }
}

// MARK: - Subviews

private extension VoiceCloningView {
    var configurationPanel: some View {
        CompactConfigurationSection(
            title: "Reference",
            detail: "Choose a saved voice or clip, then set the delivery and optional transcript.",
            iconName: "waveform",
            accentColor: AppTheme.voiceCloning,
            trailingText: activeReferenceLabel,
            rowSpacing: LayoutConstants.generationConfigurationRowSpacing,
            panelPadding: LayoutConstants.generationConfigurationPanelPadding,
            contentSlotHeight: LayoutConstants.generationConfigurationSlotHeight,
            accessibilityIdentifier: "voiceCloning_configuration"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                referenceSettings
                transcriptSettings
                deliverySettings
            }
        }
        .overlay(alignment: .topLeading) {
            HiddenAccessibilityMarker(
                value: "Reference",
                identifier: "voiceCloning_configuration"
            )
        }
    }

    var composerPanel: some View {
        StudioSectionCard(
            title: "Script",
            iconName: "text.alignleft",
            accentColor: AppTheme.voiceCloning,
            trailingText: canGenerate ? "Ready" : nil,
            fillsAvailableHeight: true,
            accessibilityIdentifier: "voiceCloning_script"
        ) {
            VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
                TextInputView(
                    text: $text,
                    isGenerating: isGenerating,
                    placeholder: "What should the cloned voice say?",
                    buttonColor: AppTheme.voiceCloning,
                    batchAction: { showingBatch = true },
                    batchDisabled: !canRunBatch,
                    isEmbedded: true,
                    usesFlexibleEmbeddedHeight: true,
                    onGenerate: generate
                )
                .disabled(!pythonBridge.isReady || !isModelAvailable || referenceAudioPath == nil)

                composerFooter
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    var referenceSettings: some View {
        ConfigurationFieldRow(
            label: "Source",
            rowVerticalPadding: max(LayoutConstants.generationConfigurationRowVerticalPadding - 2, 2),
            horizontalSpacing: 12,
            stackedSpacing: max(LayoutConstants.generationConfigurationRowSpacing - 2, 2),
            supportingSpacing: 3
        ) {
            sourceRow
        } supporting: {
            referenceStatus

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
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceCloning_voiceSetup")
    }

    var transcriptSettings: some View {
        ConfigurationFieldRow(
            label: "Transcript",
            rowVerticalPadding: max(LayoutConstants.generationConfigurationRowVerticalPadding - 2, 2),
            horizontalSpacing: 12,
            stackedSpacing: max(LayoutConstants.generationConfigurationRowSpacing - 2, 2),
            supportingSpacing: 3,
            accessibilityIdentifier: "voiceCloning_transcriptField"
        ) {
            TextField(
                "What does the reference audio say? (optional)",
                text: $referenceTranscript
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Transcript")
            .accessibilityIdentifier("voiceCloning_transcriptInput")
        }
        .accessibilityElement(children: .contain)
    }

    var deliverySettings: some View {
        ConfigurationFieldRow(
            label: "Delivery",
            rowVerticalPadding: max(LayoutConstants.generationConfigurationRowVerticalPadding - 2, 2),
            horizontalSpacing: 12,
            stackedSpacing: max(LayoutConstants.generationConfigurationRowSpacing - 2, 2),
            supportingSpacing: 3
        ) {
            DeliveryControlsView(
                emotion: $emotion,
                accentColor: AppTheme.voiceCloning,
                isCompact: true,
                showsLabel: false
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceCloning_toneSpeed")
    }

    @ViewBuilder
    var sourceRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                if !savedVoices.isEmpty {
                    savedVoicePicker
                }

                importButton

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                if !savedVoices.isEmpty {
                    savedVoicePicker
                }

                importButton
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    var savedVoicePicker: some View {
        if !savedVoices.isEmpty {
            Picker("Saved voice", selection: selectedSavedVoiceID) {
                Text("Choose a saved voice")
                    .tag(Optional<String>.none)

                ForEach(savedVoices) { voice in
                    Text(voice.name)
                        .tag(Optional(voice.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: LayoutConstants.configurationControlMinWidth, maxWidth: 240, alignment: .leading)
            .accessibilityValue(selectedVoice?.name ?? "")
            .accessibilityIdentifier("voiceCloning_savedVoicePicker")
        }
    }

    var importButton: some View {
        Button {
            browseForAudio()
        } label: {
            Label(referenceAudioPath == nil ? "Import reference audio..." : "Replace reference audio...", systemImage: "waveform.badge.plus")
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .tint(AppTheme.voiceCloning)
        .controlSize(.small)
        .accessibilityIdentifier("voiceCloning_importButton")
    }

    @ViewBuilder
    var referenceStatus: some View {
        if let path = referenceAudioPath {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.voiceCloning)

                VStack(alignment: .leading, spacing: 3) {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)

                    Text(selectedVoice == nil ? "Imported file ready" : "Saved voice ready")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button("Clear") {
                    AppLaunchConfiguration.performAnimated(.default) {
                        clearReference()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .inlinePanel(padding: 8, radius: 10)
            .accessibilityIdentifier("voiceCloning_activeReference")
        } else {
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Add a reference clip to unlock the script composer and generation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 1)
        }
    }

    var activeReferenceLabel: String {
        if let selectedVoice {
            return selectedVoice.name
        }
        if let referenceAudioPath {
            return URL(fileURLWithPath: referenceAudioPath).lastPathComponent
        }
        return "Required"
    }

    var generationReadiness: some View {
        WorkflowReadinessNote(
            isReady: canGenerate,
            title: canGenerate ? "Ready to generate" : readinessTitle,
            detail: readinessDetail,
            accentColor: AppTheme.voiceCloning,
            accessibilityIdentifier: "voiceCloning_readiness"
        )
    }

    var readinessTitle: String {
        if !pythonBridge.isReady {
            return "Engine starting"
        }
        if !isModelAvailable {
            return "Install the active model"
        }
        if referenceAudioPath == nil {
            return "Add a reference"
        }
        if text.isEmpty {
            return "Add a script"
        }
        return "Review the take"
    }

    var readinessDetail: String {
        if !pythonBridge.isReady {
            return "QwenVoice is still preparing the generation engine."
        }
        if !isModelAvailable {
            return "Install \(modelDisplayName) in Models to enable generation."
        }
        if referenceAudioPath == nil {
            return "Saved voices or imported clips both work here. Choose one before writing the final line."
        }
        if text.isEmpty {
            return "Your reference is ready. Add the line you want the cloned voice to perform."
        }
        return "Everything is in place for a live preview and a saved clone."
    }

    var composerFooter: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.compactGap) {
            generationReadiness

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.red)
                    .font(.callout)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: LayoutConstants.generationComposerFooterMinHeight,
            alignment: .topLeading
        )
    }

    @ViewBuilder
    func warningCard(
        message: String,
        accessibilityIdentifier: String,
        @ViewBuilder action: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action()
            }

            Spacer(minLength: 0)
        }
        .inlinePanel(padding: 12, radius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

// MARK: - Actions

private extension VoiceCloningView {
    func generate() {
        guard !text.isEmpty else { return }

        guard let refPath = referenceAudioPath else {
            errorMessage = "Select a reference audio file before generating."
            return
        }

        guard pythonBridge.isReady else { return }

        if let model = cloneModel, !isModelAvailable {
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
                let title = String(text.prefix(40))
                audioPlayer.prepareStreamingPreview(
                    title: title,
                    shouldAutoPlay: AudioService.shouldAutoPlay
                )

                let result = try await pythonBridge.generateCloneStreamingFlow(
                    modelID: model.id,
                    text: text,
                    refAudio: refPath,
                    refText: referenceTranscript.isEmpty ? nil : referenceTranscript,
                    emotion: emotion,
                    outputPath: outputPath
                )

                let voiceName = selectedVoice?.name ?? URL(fileURLWithPath: refPath).deletingPathExtension().lastPathComponent
                var generation = Generation(
                    text: text,
                    mode: model.mode.rawValue,
                    modelTier: model.tier,
                    voice: voiceName,
                    emotion: emotion,
                    speed: nil,
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

    func persistGenerationAndMaybeAutoplay(_ generation: inout Generation, result: GenerationResult) throws {
        AppPerformanceSignposts.emit("Final File Ready")

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
            audioPlayer.playFile(
                result.audioPath,
                title: String(text.prefix(40)),
                isAutoplay: true
            )
            #if DEBUG
            print("[Performance][VoiceCloningView] autoplay_start_wall_ms=\(elapsedMs(since: autoplayStart))")
            #endif
        }

        if let persistenceError {
            throw persistenceError
        }
    }

    func elapsedMs(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    func prewarmCloneModelIfNeeded() async {
        guard let model = cloneModel else { return }
        guard pythonBridge.isReady, isModelAvailable, !isGenerating else { return }
        guard let refPath = referenceAudioPath else { return }

        await pythonBridge.prewarmModelIfNeeded(
            modelID: model.id,
            mode: .clone,
            instruct: PythonBridge.hasMeaningfulDeliveryInstruction(emotion) ? emotion : nil,
            refAudio: refPath,
            refText: referenceTranscript.isEmpty ? nil : referenceTranscript
        )
    }

    func selectSavedVoice(_ voice: Voice) {
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

    func clearReference() {
        referenceAudioPath = nil
        referenceTranscript = ""
        selectedVoice = nil
        transcriptLoadError = nil
    }

    func loadSavedVoices() async {
        do {
            let loadedVoices = try await pythonBridge.listVoices()
            savedVoices = loadedVoices
            savedVoicesLoadError = nil
        } catch {
            savedVoicesLoadError = "Couldn't load saved voices right now. You can still clone from a file. \(error.localizedDescription)"
        }
    }

    static let allowedAudioExtensions: Set<String> = [
        "wav", "mp3", "aiff", "aif", "m4a", "flac", "ogg"
    ]

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
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

    func browseForAudio() {
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
}
