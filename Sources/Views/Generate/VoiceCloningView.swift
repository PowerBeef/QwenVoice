import SwiftUI
import UniformTypeIdentifiers

struct VoiceCloningView: View {
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject var modelManager: ModelManagerViewModel
    @EnvironmentObject var savedVoicesViewModel: SavedVoicesViewModel

    @Binding private var draft: VoiceCloningDraft
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var transcriptLoadError: String?
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
        pythonBridge.isReady && isModelAvailable && draft.referenceAudioPath != nil && !draft.text.isEmpty
    }

    private var canRunBatch: Bool {
        pythonBridge.isReady && draft.referenceAudioPath != nil && isModelAvailable
    }

    private var idlePrewarmTaskID: String {
        "\(pythonBridge.isReady)-\(cloneModel?.id ?? "none")-\(draft.referenceAudioPath ?? "none")-\(draft.referenceTranscript)-\(isModelAvailable)"
    }

    private var savedVoicesLoadTaskID: String {
        "\(pythonBridge.isReady)-\(draft.selectedSavedVoiceID ?? "none")"
    }

    private var savedVoices: [Voice] {
        savedVoicesViewModel.voices
    }

    private var selectedVoice: Voice? {
        guard let selectedSavedVoiceID = draft.selectedSavedVoiceID else { return nil }
        return savedVoices.first(where: { $0.id == selectedSavedVoiceID })
    }

    private var savedVoicesLoadError: String? {
        guard let loadError = savedVoicesViewModel.loadError else { return nil }
        return "Couldn't load saved voices right now. You can still clone from a file. \(loadError)"
    }

    private var selectedSavedVoiceID: Binding<String?> {
        Binding(
            get: { draft.selectedSavedVoiceID },
            set: { newID in
                guard let newID else {
                    if draft.referenceAudioPath != nil || draft.selectedSavedVoiceID != nil {
                        clearReference()
                    }
                    return
                }

                guard let voice = savedVoices.first(where: { $0.id == newID }) else { return }
                selectSavedVoice(voice)
            }
        )
    }

    private var readinessTitle: String {
        if !pythonBridge.isReady {
            return "Engine starting"
        }
        if !isModelAvailable {
            return "Install the active model"
        }
        if draft.referenceAudioPath == nil {
            return "Add a reference"
        }
        if draft.text.isEmpty {
            return "Add a script"
        }
        return "Review the take"
    }

    private var readinessDetail: String {
        if !pythonBridge.isReady {
            return "QwenVoice is still preparing the generation engine."
        }
        if !isModelAvailable {
            return "Install \(modelDisplayName) in Models to enable generation."
        }
        if draft.referenceAudioPath == nil {
            return "Saved voices or imported clips both work here. Choose one before writing the final line."
        }
        if draft.text.isEmpty {
            return "Your reference is ready. Add the line you want the cloned voice to perform."
        }
        return "Everything is in place for a live preview and a saved clone."
    }

    init(draft: Binding<VoiceCloningDraft>) {
        _draft = draft
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
                .layoutPriority(1)
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
        .task(id: savedVoicesLoadTaskID) {
            guard pythonBridge.isReady else { return }

            if draft.selectedSavedVoiceID != nil {
                await savedVoicesViewModel.refresh(using: pythonBridge)
            } else {
                await savedVoicesViewModel.ensureLoaded(using: pythonBridge)
            }

            syncSavedVoiceSelectionState()
        }
        .onChange(of: savedVoicesViewModel.voices) { _, _ in
            syncSavedVoiceSelectionState()
        }
        .task(id: idlePrewarmTaskID) {
            await prewarmCloneModelIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .testStartGeneration)) { notification in
            handleTestStartGeneration(notification)
        }
        .sheet(isPresented: $showingBatch) {
            BatchGenerationSheet(
                mode: .clone,
                refAudio: draft.referenceAudioPath,
                refText: draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript
            )
            .environmentObject(pythonBridge)
            .environmentObject(audioPlayer)
        }
    }
}

// MARK: - Panel Layout

private extension VoiceCloningView {
    var configurationPanel: some View {
        CompactConfigurationSection(
            title: "Configuration",
            detail: "Choose a saved voice or import a reference clip, then add an optional transcript.",
            iconName: "slider.horizontal.3",
            accentColor: AppTheme.voiceCloning,
            trailingText: nil,
            rowSpacing: LayoutConstants.generationConfigurationRowSpacing,
            panelPadding: LayoutConstants.generationConfigurationPanelPadding,
            contentSlotHeight: LayoutConstants.generationConfigurationSlotHeight,
            accessibilityIdentifier: "voiceCloning_configuration"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                VoiceCloningReferenceSettings(
                    savedVoices: savedVoices,
                    selectedSavedVoiceID: selectedSavedVoiceID,
                    referenceAudioPath: draft.referenceAudioPath,
                    selectedVoice: selectedVoice,
                    savedVoicesLoadError: savedVoicesLoadError,
                    transcriptLoadError: transcriptLoadError,
                    browseForAudio: browseForAudio,
                    clearReference: clearReference,
                    retrySavedVoices: { Task { await savedVoicesViewModel.refresh(using: pythonBridge) } }
                )
                VoiceCloningTranscriptSettings(referenceTranscript: $draft.referenceTranscript)
            }
        }
        .overlay(alignment: .topLeading) {
            HiddenAccessibilityMarker(
                value: "Reference",
                identifier: "voiceCloning_configuration"
            )
        }
        .fixedSize(horizontal: false, vertical: true)
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
                    text: $draft.text,
                    isGenerating: isGenerating,
                    placeholder: "What should the cloned voice say?",
                    buttonColor: AppTheme.voiceCloning,
                    batchAction: { showingBatch = true },
                    batchDisabled: !canRunBatch,
                    isEmbedded: true,
                    usesFlexibleEmbeddedHeight: true,
                    onGenerate: generate
                )
                .disabled(!pythonBridge.isReady || !isModelAvailable || draft.referenceAudioPath == nil)

                VoiceCloningComposerFooter(
                    canGenerate: canGenerate,
                    readinessTitle: readinessTitle,
                    readinessDetail: readinessDetail,
                    errorMessage: errorMessage
                )
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Actions

private extension VoiceCloningView {
    func handleTestStartGeneration(_ notification: Notification) {
        guard UITestAutomationSupport.isEnabled,
              let screen = notification.userInfo?["screen"] as? String,
              screen == "voiceCloning" else { return }

        if let text = notification.userInfo?["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.text = text
        }
        if let referenceAudioPath = notification.userInfo?["referenceAudioPath"] as? String,
           !referenceAudioPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.selectedSavedVoiceID = nil
            draft.referenceAudioPath = referenceAudioPath
        }
        if let referenceTranscript = notification.userInfo?["referenceTranscript"] as? String {
            draft.referenceTranscript = referenceTranscript
        }

        generate()
    }

    func generate() {
        guard !draft.text.isEmpty else { return }

        guard let refPath = draft.referenceAudioPath else {
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

                let outputPath = makeOutputPath(subfolder: model.outputSubfolder, text: draft.text)
                let title = String(draft.text.prefix(40))
                audioPlayer.prepareStreamingPreview(
                    title: title,
                    shouldAutoPlay: AudioService.shouldAutoPlay
                )

                let result = try await pythonBridge.generateCloneStreamingFlow(
                    modelID: model.id,
                    text: draft.text,
                    refAudio: refPath,
                    refText: draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript,
                    outputPath: outputPath
                )

                let voiceName = selectedVoice?.name ?? URL(fileURLWithPath: refPath).deletingPathExtension().lastPathComponent
                var generation = Generation(
                    text: draft.text,
                    mode: model.mode.rawValue,
                    modelTier: model.tier,
                    voice: voiceName,
                    emotion: nil,
                    speed: nil,
                    audioPath: result.audioPath,
                    duration: result.durationSeconds,
                    createdAt: Date()
                )
                try GenerationPersistence.persistAndAutoplay(
                    &generation, result: result, text: draft.text,
                    audioPlayer: audioPlayer, caller: "VoiceCloningView"
                )
                UITestAutomationSupport.recordAction("clone-generate-success", appSupportDir: QwenVoiceApp.appSupportDir)
            } catch {
                UITestAutomationSupport.recordAction("clone-generate-error", appSupportDir: QwenVoiceApp.appSupportDir)
                if (error as? GenerationPersistence.PersistenceError) == nil {
                    audioPlayer.abortLivePreviewIfNeeded()
                }
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }

    func prewarmCloneModelIfNeeded() async {
        guard let model = cloneModel else { return }
        guard pythonBridge.isReady, isModelAvailable, !isGenerating else { return }
        guard let refPath = draft.referenceAudioPath else { return }

        await pythonBridge.prewarmModelIfNeeded(
            modelID: model.id,
            mode: .clone,
            refAudio: refPath,
            refText: draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript
        )
    }

    func selectSavedVoice(_ voice: Voice) {
        draft.selectedSavedVoiceID = voice.id
        draft.referenceAudioPath = voice.wavPath
        do {
            draft.referenceTranscript = try voice.loadTranscript() ?? ""
            transcriptLoadError = nil
        } catch {
            draft.referenceTranscript = ""
            transcriptLoadError = "Couldn't load the saved transcript for \"\(voice.name)\". You can still clone from the audio file alone."
        }
    }

    func clearReference() {
        draft.clearReference()
        transcriptLoadError = nil
    }

    func syncSavedVoiceSelectionState() {
        if let selectedSavedVoiceID = draft.selectedSavedVoiceID,
           let voice = savedVoices.first(where: { $0.id == selectedSavedVoiceID }) {
            selectSavedVoice(voice)
            return
        }

        if draft.selectedSavedVoiceID != nil {
            clearReference()
        }
    }

    static let allowedAudioExtensions: Set<String> = [
        "wav", "mp3", "aiff", "aif", "m4a", "flac", "ogg"
    ]

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let allowedExtensions = Self.allowedAudioExtensions
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            let ext = url.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else {
                Task { @MainActor in
                    errorMessage = "Unsupported file type '.\(ext)'. Drop an audio file (WAV, MP3, AIFF, M4A, FLAC, or OGG)."
                }
                return
            }
            Task { @MainActor in
                draft.referenceAudioPath = url.path
                draft.selectedSavedVoiceID = nil
                transcriptLoadError = nil
            }
        }
        return true
    }

    func browseForAudio() {
        if UITestAutomationSupport.isStubBackendMode,
           let url = UITestAutomationSupport.importAudioURL {
            draft.referenceAudioPath = url.path
            draft.selectedSavedVoiceID = nil
            transcriptLoadError = nil
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .wav, .mp3, .aiff]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            draft.referenceAudioPath = url.path
            draft.selectedSavedVoiceID = nil
            transcriptLoadError = nil
        }
    }
}

// MARK: - Reference Settings

private struct VoiceCloningReferenceSettings: View {
    let savedVoices: [Voice]
    @Binding var selectedSavedVoiceID: String?
    let referenceAudioPath: String?
    let selectedVoice: Voice?
    let savedVoicesLoadError: String?
    let transcriptLoadError: String?
    let browseForAudio: () -> Void
    let clearReference: () -> Void
    let retrySavedVoices: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
            Text("Source")
                .font(.subheadline.weight(.semibold))

            CloneSourceRow(
                savedVoices: savedVoices,
                selectedSavedVoiceID: $selectedSavedVoiceID,
                browseForAudio: browseForAudio,
                referenceAudioPath: referenceAudioPath
            )

            CloneReferenceStatus(
                referenceAudioPath: referenceAudioPath,
                selectedVoice: selectedVoice,
                clearReference: clearReference,
                accentColor: AppTheme.voiceCloning
            )

            if let savedVoicesLoadError {
                CloneWarningCard(
                    message: savedVoicesLoadError,
                    actionLabel: "Retry",
                    action: retrySavedVoices,
                    accentColor: AppTheme.voiceCloning,
                    accessibilityIdentifier: "voiceCloning_savedVoicesWarning",
                    actionAccessibilityIdentifier: "voiceCloning_savedVoicesRetry"
                )
            }

            if let transcriptLoadError {
                CloneWarningCard(
                    message: transcriptLoadError,
                    actionLabel: nil,
                    action: nil,
                    accentColor: AppTheme.voiceCloning,
                    accessibilityIdentifier: "voiceCloning_transcriptWarning",
                    actionAccessibilityIdentifier: nil
                )
            }
        }
        .padding(.vertical, LayoutConstants.generationConfigurationRowVerticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceCloning_voiceSetup")
    }
}

// MARK: - Transcript Settings

private struct VoiceCloningTranscriptSettings: View {
    @Binding var referenceTranscript: String

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
            Text("Transcript")
                .font(.subheadline.weight(.semibold))

            TextField(
                "What does the reference audio say? (optional)",
                text: $referenceTranscript
            )
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassTextField(radius: 8)
            .accessibilityLabel("Transcript")
            .accessibilityIdentifier("voiceCloning_transcriptInput")
        }
        .padding(.vertical, LayoutConstants.generationConfigurationRowVerticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceCloning_transcriptField")
    }
}

// MARK: - Composer Footer

private struct VoiceCloningComposerFooter: View {
    let canGenerate: Bool
    let readinessTitle: String
    let readinessDetail: String
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.compactGap) {
            WorkflowReadinessNote(
                isReady: canGenerate,
                title: canGenerate ? "Ready to generate" : readinessTitle,
                detail: readinessDetail,
                accentColor: AppTheme.voiceCloning,
                accessibilityIdentifier: "voiceCloning_readiness"
            )

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
}

// MARK: - Reference Status

private struct CloneReferenceStatus: View {
    let referenceAudioPath: String?
    let selectedVoice: Voice?
    let clearReference: () -> Void
    let accentColor: Color

    var body: some View {
        if let path = referenceAudioPath {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accentColor)

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
}

// MARK: - Source Row

private struct CloneSourceRow: View {
    let savedVoices: [Voice]
    @Binding var selectedSavedVoiceID: String?
    let browseForAudio: () -> Void
    let referenceAudioPath: String?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if !savedVoices.isEmpty {
                savedVoicePicker
            }

            importButton

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var savedVoicePicker: some View {
        if !savedVoices.isEmpty {
            Picker("Saved voice", selection: $selectedSavedVoiceID) {
                Text("Choose a saved voice")
                    .tag(Optional<String>.none)

                ForEach(savedVoices) { voice in
                    Text(voice.name)
                        .tag(Optional(voice.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .focusEffectDisabled()
            .frame(minWidth: LayoutConstants.configurationControlMinWidth, maxWidth: 180, alignment: .leading)
            .accessibilityValue(savedVoices.first(where: { $0.id == selectedSavedVoiceID })?.name ?? "")
            .accessibilityIdentifier("voiceCloning_savedVoicePicker")
        }
    }

    private var importButton: some View {
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
}

// MARK: - Warning Card

private struct CloneWarningCard: View {
    let message: String
    let actionLabel: String?
    let action: (() -> Void)?
    let accentColor: Color
    let accessibilityIdentifier: String
    let actionAccessibilityIdentifier: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionLabel, let action {
                    Button(actionLabel) {
                        action()
                    }
                    .buttonStyle(.bordered)
                    .tint(accentColor)
                    .controlSize(.small)
                    .accessibilityIdentifier(actionAccessibilityIdentifier ?? "")
                }
            }

            Spacer(minLength: 0)
        }
        .inlinePanel(padding: 12, radius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
