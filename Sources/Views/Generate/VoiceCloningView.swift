import SwiftUI
import UniformTypeIdentifiers

struct VoiceCloningView: View {
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject var modelManager: ModelManagerViewModel
    @EnvironmentObject var savedVoicesViewModel: SavedVoicesViewModel

    @Binding private var draft: VoiceCloningDraft
    @Binding private var pendingSavedVoiceHandoff: PendingVoiceCloningHandoff?
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var transcriptLoadError: String?
    @State private var hydratedSavedVoiceID: String?
    @State private var isDragOver = false
    @State private var showingBatch = false
    @State private var cloneDeferredPrewarmTask: Task<Void, Never>?

    static let deferredClonePrewarmDelayNanoseconds: UInt64 = 1_500_000_000

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

    private var clonePrimingRequestKey: String? {
        guard let model = cloneModel,
              pythonBridge.isReady,
              isModelAvailable,
              let referenceAudioPath = draft.referenceAudioPath else {
            return nil
        }
        if let selectedSavedVoiceID = draft.selectedSavedVoiceID,
           hydratedSavedVoiceID != selectedSavedVoiceID,
           transcriptLoadError == nil {
            return nil
        }
        return PythonBridge.cloneReferenceIdentityKey(
            modelID: model.id,
            refAudio: referenceAudioPath,
            refText: draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript
        )
    }

    private var clonePrimingTaskID: String {
        clonePrimingRequestKey ?? "clone-priming-idle"
    }

    private var modelPreparationTaskID: String {
        "\(pythonBridge.isReady)-\(cloneModel?.id ?? "none")-\(isModelAvailable)-\(isGenerating)"
    }

    private var cloneContextStatus: VoiceCloningContextStatus? {
        guard draft.referenceAudioPath != nil else { return nil }

        if let selectedSavedVoiceID = draft.selectedSavedVoiceID,
           hydratedSavedVoiceID != selectedSavedVoiceID,
           transcriptLoadError == nil {
            return .waitingForHydration
        }

        guard let clonePrimingRequestKey else { return nil }

        if pythonBridge.cloneReferencePrimingKey == clonePrimingRequestKey {
            switch pythonBridge.cloneReferencePrimingPhase {
            case .idle:
                break
            case .preparing:
                return .preparing
            case .primed:
                return .primed
            case .failed:
                return .fallback(
                    pythonBridge.cloneReferencePrimingError
                        ?? "Voice context priming didn't finish. Generation is still available, but the first preview may be slower."
                )
            }
        }

        return .preparing
    }

    private var readinessDescriptor: VoiceCloningReadinessDescriptor {
        VoiceCloningReadiness.describe(
            pythonReady: pythonBridge.isReady,
            isModelAvailable: isModelAvailable,
            modelDisplayName: modelDisplayName,
            referenceAudioPath: draft.referenceAudioPath,
            text: draft.text,
            contextStatus: cloneContextStatus
        )
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

    init(
        draft: Binding<VoiceCloningDraft>,
        pendingSavedVoiceHandoff: Binding<PendingVoiceCloningHandoff?>
    ) {
        _draft = draft
        _pendingSavedVoiceHandoff = pendingSavedVoiceHandoff
    }

    static func shouldStartDeferredClonePrewarm(
        primingPhase: CloneReferencePrimingPhase,
        primingKey: String?,
        expectedKey: String?,
        isGenerating: Bool
    ) -> Bool {
        primingPhase == .primed
            && primingKey == expectedKey
            && !isGenerating
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
        .task(id: modelPreparationTaskID) {
            await prepareSelectedModelIfNeeded()
        }
        .onChange(of: savedVoicesViewModel.voices) { _, _ in
            syncSavedVoiceSelectionState()
        }
        .task(id: clonePrimingTaskID) {
            await syncCloneReferencePriming()
        }
        .onAppear(perform: handleAppear)
        .onChange(of: draft.referenceAudioPath) { _, _ in syncUITestState() }
        .onChange(of: draft.referenceTranscript) { _, _ in syncUITestState() }
        .onChange(of: draft.text) { _, _ in syncUITestState() }
        .onChange(of: isGenerating) { _, _ in syncUITestState() }
        .onChange(of: hydratedSavedVoiceID) { _, _ in syncUITestState() }
        .onChange(of: transcriptLoadError) { _, _ in syncUITestState() }
        .onChange(of: pythonBridge.cloneReferencePrimingPhase) { _, _ in syncUITestState() }
        .onChange(of: pythonBridge.cloneReferencePrimingKey) { _, _ in syncUITestState() }
        .onChange(of: pendingSavedVoiceHandoff) { _, _ in
            consumePendingSavedVoiceHandoffIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .testSeedScreenState)) { notification in
            handleTestSeedScreenState(notification)
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
            trailingText: readinessDescriptor.trailingText,
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
                    isReadyForFastGenerate: readinessDescriptor.noteIsReady,
                    readinessTitle: readinessDescriptor.title,
                    readinessDetail: readinessDescriptor.detail,
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
    func handleAppear() {
        consumePendingSavedVoiceHandoffIfNeeded()
        syncUITestState()
    }

    var cloneContextStatusTestValue: String {
        switch cloneContextStatus {
        case .none:
            return "none"
        case .waitingForHydration:
            return "waitingForHydration"
        case .preparing:
            return "preparing"
        case .primed:
            return "primed"
        case .fallback:
            return "fallback"
        }
    }

    func consumePendingSavedVoiceHandoffIfNeeded() {
        guard let pendingSavedVoiceHandoff else { return }
        applyPendingSavedVoiceHandoff(pendingSavedVoiceHandoff)
        self.pendingSavedVoiceHandoff = nil
    }

    func applyPendingSavedVoiceHandoff(_ handoff: PendingVoiceCloningHandoff) {
        draft.applySavedVoiceSelection(
            id: handoff.savedVoiceID,
            wavPath: handoff.wavPath,
            transcript: handoff.transcript
        )
        transcriptLoadError = handoff.transcriptLoadError
        hydratedSavedVoiceID = handoff.savedVoiceID
    }

    func syncUITestState() {
        guard UITestAutomationSupport.isEnabled else { return }
        TestStateProvider.shared.referenceAudioPath = draft.referenceAudioPath ?? ""
        TestStateProvider.shared.referenceTranscript = draft.referenceTranscript
        TestStateProvider.shared.text = draft.text
        TestStateProvider.shared.isGenerating = isGenerating
        TestStateProvider.shared.clonePrimingPhase = cloneContextStatusTestValue
        TestStateProvider.shared.cloneFastReady = readinessDescriptor.noteIsReady
    }

    func handleTestSeedScreenState(_ notification: Notification) {
        guard UITestAutomationSupport.isEnabled,
              let screen = notification.userInfo?["screen"] as? String,
              screen == "voiceCloning" else { return }

        if let referenceAudioPath = notification.userInfo?["referenceAudioPath"] as? String {
            draft.selectedSavedVoiceID = nil
            draft.referenceAudioPath = referenceAudioPath.isEmpty ? nil : referenceAudioPath
            hydratedSavedVoiceID = nil
        }
        if let referenceTranscript = notification.userInfo?["referenceTranscript"] as? String {
            draft.referenceTranscript = referenceTranscript
        }
        if let text = notification.userInfo?["text"] as? String {
            draft.text = text
        }
    }

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
            hydratedSavedVoiceID = nil
        }
        if let referenceTranscript = notification.userInfo?["referenceTranscript"] as? String {
            draft.referenceTranscript = referenceTranscript
        }

        generate()
    }

    func generate() {
        guard !draft.text.isEmpty else { return }

        guard pythonBridge.isReady else { return }

        if let model = cloneModel, !isModelAvailable {
            errorMessage = "Model '\(model.name)' is unavailable or incomplete. Go to Settings > Models to download or re-download it."
            return
        }

        cloneDeferredPrewarmTask?.cancel()
        cloneDeferredPrewarmTask = nil
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

                ensureSelectedSavedVoiceHydratedIfNeeded()

                guard let refPath = draft.referenceAudioPath else {
                    errorMessage = "Select a reference audio file before generating."
                    isGenerating = false
                    return
                }

                if pythonBridge.cloneReferencePrimingPhase != .failed
                    || pythonBridge.cloneReferencePrimingKey != clonePrimingRequestKey {
                    do {
                        try await pythonBridge.ensureCloneReferencePrimed(
                            modelID: model.id,
                            refAudio: refPath,
                            refText: draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript
                        )
                    } catch {
                        #if DEBUG
                        print("[Performance][VoiceCloningView] clone priming degraded: \(error.localizedDescription)")
                        #endif
                    }
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

    func syncCloneReferencePriming() async {
        cloneDeferredPrewarmTask?.cancel()
        cloneDeferredPrewarmTask = nil
        guard !isGenerating else { return }
        guard let model = cloneModel,
              let refPath = draft.referenceAudioPath,
              let clonePrimingRequestKey else {
            await pythonBridge.cancelCloneReferencePrimingIfNeeded()
            return
        }

        if let selectedSavedVoiceID = draft.selectedSavedVoiceID,
           hydratedSavedVoiceID != selectedSavedVoiceID,
           transcriptLoadError == nil {
            await pythonBridge.cancelCloneReferencePrimingIfNeeded()
            return
        }

        let trimmedRefText = draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript
        do {
            try await pythonBridge.ensureCloneReferencePrimed(
                modelID: model.id,
                refAudio: refPath,
                refText: trimmedRefText
            )
            guard Self.shouldStartDeferredClonePrewarm(
                primingPhase: pythonBridge.cloneReferencePrimingPhase,
                primingKey: pythonBridge.cloneReferencePrimingKey,
                expectedKey: clonePrimingRequestKey,
                isGenerating: isGenerating
            ) else {
                return
            }
            cloneDeferredPrewarmTask = Task { @MainActor [modelID = model.id, refPath, trimmedRefText, clonePrimingRequestKey] in
                try? await Task.sleep(nanoseconds: Self.deferredClonePrewarmDelayNanoseconds)
                guard !Task.isCancelled else { return }
                guard Self.shouldStartDeferredClonePrewarm(
                    primingPhase: pythonBridge.cloneReferencePrimingPhase,
                    primingKey: pythonBridge.cloneReferencePrimingKey,
                    expectedKey: clonePrimingRequestKey,
                    isGenerating: isGenerating
                ) else {
                    return
                }
                await pythonBridge.prewarmModelIfNeeded(
                    modelID: modelID,
                    mode: .clone,
                    refAudio: refPath,
                    refText: trimmedRefText
                )
            }
        } catch {
            #if DEBUG
            print("[Performance][VoiceCloningView] clone priming failed key=\(clonePrimingRequestKey) error=\(error.localizedDescription)")
            #endif
        }
    }

    func prepareSelectedModelIfNeeded() async {
        guard let model = cloneModel else { return }
        guard pythonBridge.isReady, isModelAvailable, !isGenerating else { return }
        await pythonBridge.ensureModelLoadedIfNeeded(id: model.id)
    }

    func selectSavedVoice(_ voice: Voice) {
        applySavedVoice(voice)
    }

    func applySavedVoice(_ voice: Voice) {
        do {
            let transcript = try SavedVoiceCloneHydration.loadTranscript(for: voice)
            draft.applySavedVoice(voice, transcript: transcript)
            transcriptLoadError = nil
        } catch {
            draft.applySavedVoice(voice, transcript: "")
            transcriptLoadError = "Couldn't load the saved transcript for \"\(voice.name)\". You can still clone from the audio file alone."
        }
        hydratedSavedVoiceID = voice.id
    }

    func ensureSelectedSavedVoiceHydratedIfNeeded() {
        guard let selectedVoice else { return }
        guard draft.selectedSavedVoiceID == selectedVoice.id else { return }
        guard hydratedSavedVoiceID != selectedVoice.id else { return }
        guard transcriptLoadError == nil else { return }
        applySavedVoice(selectedVoice)
    }

    func clearReference() {
        cloneDeferredPrewarmTask?.cancel()
        cloneDeferredPrewarmTask = nil
        draft.clearReference()
        transcriptLoadError = nil
        hydratedSavedVoiceID = nil
    }

    func syncSavedVoiceSelectionState() {
        if draft.selectedSavedVoiceID != nil,
           selectedVoice == nil,
           (savedVoicesViewModel.isLoading || savedVoicesViewModel.loadError != nil) {
            return
        }

        switch SavedVoiceCloneHydration.action(
            draft: draft,
            voice: selectedVoice,
            hydratedVoiceID: hydratedSavedVoiceID,
            transcriptLoadError: transcriptLoadError
        ) {
        case .none:
            break
        case .acceptCurrentDraft:
            hydratedSavedVoiceID = selectedVoice?.id
        case .applyFromDisk:
            if let selectedVoice {
                applySavedVoice(selectedVoice)
            }
        case .clearStaleSelection:
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
                hydratedSavedVoiceID = nil
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
            hydratedSavedVoiceID = nil
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .wav, .mp3, .aiff]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            draft.referenceAudioPath = url.path
            draft.selectedSavedVoiceID = nil
            transcriptLoadError = nil
            hydratedSavedVoiceID = nil
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
    let isReadyForFastGenerate: Bool
    let readinessTitle: String
    let readinessDetail: String
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.compactGap) {
            WorkflowReadinessNote(
                isReady: isReadyForFastGenerate,
                title: readinessTitle,
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
