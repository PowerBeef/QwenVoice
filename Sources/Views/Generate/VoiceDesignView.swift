import QwenVoiceNative
import SwiftUI

private struct VoiceDesignActionAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct VoiceDesignSavedVoiceCandidate: Equatable {
    let audioPath: String
    let transcript: String
    let suggestedName: String
    let voiceDescription: String
    let emotion: String
    let text: String
    private(set) var savedVoiceName: String?

    var isSaved: Bool {
        savedVoiceName != nil
    }

    func matches(draft: VoiceDesignDraft) -> Bool {
        voiceDescription == draft.voiceDescription
            && emotion == draft.emotion
            && text == draft.text
    }

    mutating func markSaved(as voiceName: String) {
        savedVoiceName = voiceName
    }
}

struct VoiceDesignView: View {
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var ttsEngineStore: TTSEngineStore
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject var modelManager: ModelManagerViewModel
    @EnvironmentObject var savedVoicesViewModel: SavedVoicesViewModel
    @EnvironmentObject var appCommandRouter: AppCommandRouter

    @Binding private var draft: VoiceDesignDraft
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var showingBatch = false
    @State private var actionAlert: VoiceDesignActionAlert?
    @State private var savedVoiceSheetConfiguration: SavedVoiceSheetConfiguration?
    @State private var latestSavedVoiceCandidate: VoiceDesignSavedVoiceCandidate?

    private var activeMode: GenerationMode {
        .design
    }

    private var activeModel: TTSModel? {
        TTSModel.model(for: activeMode)
    }

    private var isModelAvailable: Bool {
        guard let activeModel else { return false }
        return modelManager.isAvailable(activeModel)
    }

    private var modelDisplayName: String {
        activeModel?.name ?? "Unknown"
    }

    private var canGenerate: Bool {
        ttsEngineStore.isReady
            && isModelAvailable
            && !draft.text.isEmpty
            && !draft.voiceDescription.isEmpty
    }

    private var canRunBatch: Bool {
        ttsEngineStore.isReady
            && isModelAvailable
            && !draft.voiceDescription.isEmpty
    }

    private var idlePrewarmRequest: GenerationRequest? {
        guard let model = activeModel else { return nil }
        return GenerationRequest(
            modelID: model.id,
            text: draft.text,
            outputPath: "",
            payload: .design(
                voiceDescription: draft.voiceDescription,
                deliveryStyle: draft.emotion
            )
        )
    }

    private var idlePrewarmTaskID: String {
        let identity = idlePrewarmRequest.map(GenerationSemantics.prewarmIdentityKey(for:)) ?? "none"
        return "\(ttsEngineStore.isReady)-\(isModelAvailable)-\(identity)"
    }

    private var currentSavedVoiceCandidate: VoiceDesignSavedVoiceCandidate? {
        guard let latestSavedVoiceCandidate,
              latestSavedVoiceCandidate.matches(draft: draft) else {
            return nil
        }
        return latestSavedVoiceCandidate
    }

    init(draft: Binding<VoiceDesignDraft>) {
        _draft = draft
    }

    var body: some View {
        PageScaffold(
            accessibilityIdentifier: "screen_voiceDesign",
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
        .sheet(isPresented: $showingBatch) {
            BatchGenerationSheet(
                mode: .design,
                emotion: draft.emotion,
                voiceDescription: draft.voiceDescription
            )
            .environmentObject(ttsEngineStore)
            .environmentObject(audioPlayer)
        }
        .sheet(item: $savedVoiceSheetConfiguration) { configuration in
            SavedVoiceSheet(configuration: configuration) { voice in
                handleSavedVoice(voice)
            }
            .environmentObject(ttsEngineStore)
        }
        .alert(item: $actionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .task(id: idlePrewarmTaskID) {
            await prewarmSelectedModelIfNeeded()
        }
        .onAppear(perform: syncUITestState)
        .onChange(of: draft.voiceDescription) { _, _ in syncUITestState() }
        .onChange(of: draft.emotion) { _, _ in syncUITestState() }
        .onChange(of: draft.text) { _, _ in syncUITestState() }
        .onChange(of: isGenerating) { _, _ in syncUITestState() }
        .onReceive(NotificationCenter.default.publisher(for: .testSeedScreenState)) { notification in
            handleTestSeedScreenState(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .testStartGeneration)) { notification in
            handleTestStartGeneration(notification)
        }
    }
}

// MARK: - Subviews

private extension VoiceDesignView {
    var configurationPanel: some View {
        CompactConfigurationSection(
            title: "Configuration",
            detail: "Describe the voice, set the delivery, then keep the script front and center.",
            iconName: "slider.horizontal.3",
            accentColor: AppTheme.voiceDesign,
            trailingText: nil,
            rowSpacing: LayoutConstants.generationConfigurationRowSpacing,
            panelPadding: LayoutConstants.generationConfigurationPanelPadding,
            contentSlotHeight: LayoutConstants.generationConfigurationSlotHeight,
            accessibilityIdentifier: "voiceDesign_configuration"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                briefSettings
                deliverySettings
            }
        }
        .overlay(alignment: .topLeading) {
            HiddenAccessibilityMarker(
                value: "Configuration",
                identifier: "voiceDesign_configuration"
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    var composerPanel: some View {
        StudioSectionCard(
            title: "Script",
            iconName: "text.alignleft",
            accentColor: AppTheme.voiceDesign,
            trailingText: canGenerate ? "Ready" : nil,
            fillsAvailableHeight: true,
            accessibilityIdentifier: "voiceDesign_script"
        ) {
            VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
                TextInputView(
                    text: $draft.text,
                    isGenerating: isGenerating,
                    placeholder: "What should I say?",
                    buttonColor: AppTheme.voiceDesign,
                    batchAction: { showingBatch = true },
                    batchDisabled: !canRunBatch,
                    generateDisabled: !ttsEngineStore.isReady || !isModelAvailable || draft.voiceDescription.isEmpty,
                    isEmbedded: true,
                    usesFlexibleEmbeddedHeight: true,
                    onGenerate: generate
                )

                composerFooter
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    var briefSettings: some View {
        VoiceDesignBriefSettings(voiceDescription: $draft.voiceDescription)
    }

    var deliverySettings: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
            Text("Delivery")
                .font(.subheadline.weight(.semibold))

            DeliveryControlsView(
                emotion: $draft.emotion,
                accentColor: AppTheme.voiceDesign,
                isCompact: true,
                showsLabel: false
            )
        }
        .padding(.vertical, LayoutConstants.generationConfigurationRowVerticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceDesign_toneSpeed")
    }

    var generationReadiness: some View {
        WorkflowReadinessNote(
            isReady: canGenerate,
            title: canGenerate ? "Ready to generate" : readinessTitle,
            detail: readinessDetail,
            accentColor: AppTheme.voiceDesign,
            accessibilityIdentifier: "voiceDesign_readiness"
        )
    }

    var readinessTitle: String {
        if !ttsEngineStore.isReady {
            return "Engine starting"
        }
        if !isModelAvailable {
            return "Install the active model"
        }
        if draft.voiceDescription.isEmpty {
            return "Add a voice brief"
        }
        if draft.text.isEmpty {
            return "Add a script"
        }
        return "Review the take"
    }

    var readinessDetail: String {
        if !ttsEngineStore.isReady {
            return "QwenVoice is still preparing the generation engine."
        }
        if !isModelAvailable {
            return "Install \(modelDisplayName) in Models to enable generation."
        }
        if draft.voiceDescription.isEmpty {
            return "Describe the voice you want before writing the final line."
        }
        if draft.text.isEmpty {
            return "Once the line is written, the generated voice will use this brief and delivery."
        }
        return "Everything is in place for a live preview and a saved generation."
    }

    var composerFooter: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.compactGap) {
            if let model = activeModel,
               let primaryActionTitle = modelManager.primaryActionTitle(for: model) {
                ModelRecoveryCard(
                    title: primaryActionTitle,
                    detail: modelManager.recoveryDetail(for: model),
                    primaryActionTitle: primaryActionTitle,
                    accentColor: AppTheme.voiceDesign,
                    accessibilityIdentifier: "voiceDesign_modelRecovery",
                    onPrimaryAction: {
                        Task { await modelManager.download(model, using: pythonBridge) }
                    },
                    onSecondaryAction: {
                        appCommandRouter.navigate(to: .models)
                    }
                )
            }

            generationReadiness
            saveVoiceAction

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
    var saveVoiceAction: some View {
        if let candidate = currentSavedVoiceCandidate {
            if candidate.isSaved {
                Label("Saved to Saved Voices", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("voiceDesign_saveVoiceCompleted")
                    .accessibilityValue(candidate.savedVoiceName ?? "")
            } else {
                Button {
                    presentSavedVoiceSheet()
                } label: {
                    Label("Save to Saved Voices", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("voiceDesign_saveVoiceButton")
            }
        }
    }
}

// MARK: - Actions

private extension VoiceDesignView {
    func syncUITestState() {
        guard UITestAutomationSupport.isEnabled else { return }
        TestStateProvider.shared.voiceDescription = draft.voiceDescription
        TestStateProvider.shared.emotion = draft.emotion
        TestStateProvider.shared.text = draft.text
        TestStateProvider.shared.isGenerating = isGenerating
    }

    func handleTestSeedScreenState(_ notification: Notification) {
        guard UITestAutomationSupport.isEnabled,
              let screen = notification.userInfo?["screen"] as? String,
              screen == "voiceDesign" else { return }

        if let voiceDescription = notification.userInfo?["voiceDescription"] as? String {
            draft.voiceDescription = voiceDescription
        }
        if let emotion = notification.userInfo?["emotion"] as? String {
            draft.emotion = emotion
        }
        if let text = notification.userInfo?["text"] as? String {
            draft.text = text
        }
    }

    func handleTestStartGeneration(_ notification: Notification) {
        guard UITestAutomationSupport.isEnabled,
              let screen = notification.userInfo?["screen"] as? String,
              screen == "voiceDesign" else { return }

        if let text = notification.userInfo?["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.text = text
        }
        if let voiceDescription = notification.userInfo?["voiceDescription"] as? String,
           !voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.voiceDescription = voiceDescription
        }
        if let emotion = notification.userInfo?["emotion"] as? String,
           !emotion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.emotion = emotion
        }

        generate()
    }

    func generate() {
        guard !draft.text.isEmpty, !draft.voiceDescription.isEmpty, ttsEngineStore.isReady else { return }

        if let model = activeModel, !isModelAvailable {
            errorMessage = modelManager.recoveryDetail(for: model)
            return
        }

        isGenerating = true
        errorMessage = nil
        latestSavedVoiceCandidate = nil
        let text = draft.text
        let voiceDescription = draft.voiceDescription
        let emotion = draft.emotion

        Task {
            do {
                UITestAutomationSupport.recordAction("design-generate-start", appSupportDir: QwenVoiceApp.appSupportDir)

                guard let model = activeModel else {
                    errorMessage = "Model configuration not found"
                    isGenerating = false
                    return
                }

                let outputPath = makeOutputPath(subfolder: model.outputSubfolder, text: text)
                let generationRequest = Self.makeGenerationRequest(
                    draft: VoiceDesignDraft(
                        voiceDescription: voiceDescription,
                        emotion: emotion,
                        text: text
                    ),
                    model: model,
                    outputPath: outputPath
                )
                audioPlayer.prepareStreamingPreview(
                    title: String(text.prefix(40)),
                    shouldAutoPlay: AudioService.shouldAutoPlay
                )

                let result = try await ttsEngineStore.generate(generationRequest)

                var generation = Generation(
                    text: text,
                    mode: model.mode.rawValue,
                    modelTier: model.tier,
                    voice: voiceDescription,
                    emotion: emotion,
                    speed: nil,
                    audioPath: result.audioPath,
                    duration: result.durationSeconds,
                    createdAt: Date()
                )

                try GenerationPersistence.persistAndAutoplay(
                    &generation, result: result, text: text,
                    audioPlayer: audioPlayer, caller: "VoiceDesignView"
                )
                latestSavedVoiceCandidate = VoiceDesignSavedVoiceCandidate(
                    audioPath: generation.audioPath,
                    transcript: text,
                    suggestedName: SavedVoiceNameSuggestion.designResultName(from: voiceDescription),
                    voiceDescription: voiceDescription,
                    emotion: emotion,
                    text: text
                )
                UITestAutomationSupport.recordAction("design-generate-success", appSupportDir: QwenVoiceApp.appSupportDir)
            } catch {
                UITestAutomationSupport.recordAction("design-generate-error", appSupportDir: QwenVoiceApp.appSupportDir)
                if (error as? GenerationPersistence.PersistenceError) == nil {
                    audioPlayer.abortLivePreviewIfNeeded()
                }
                errorMessage = error.localizedDescription
            }

            isGenerating = false
        }
    }

    func prewarmSelectedModelIfNeeded() async {
        guard let idlePrewarmRequest else { return }
        guard ttsEngineStore.isReady, isModelAvailable, !isGenerating else { return }
        await ttsEngineStore.prewarmModelIfNeeded(for: idlePrewarmRequest)
    }

    func presentSavedVoiceSheet() {
        guard let candidate = currentSavedVoiceCandidate else { return }
        savedVoiceSheetConfiguration = .designResult(
            voiceDescription: candidate.voiceDescription,
            audioPath: candidate.audioPath,
            transcript: candidate.transcript
        )
    }

    func handleSavedVoice(_ voice: Voice) {
        if var candidate = latestSavedVoiceCandidate, candidate.matches(draft: draft) {
            candidate.markSaved(as: voice.name)
            latestSavedVoiceCandidate = candidate
        }
        savedVoicesViewModel.insertOrReplace(voice)
        Task { await savedVoicesViewModel.refresh(using: ttsEngineStore) }
        actionAlert = VoiceDesignActionAlert(
            title: "Saved Voice Added",
            message: "\"\(voice.name)\" is ready in Saved Voices."
        )
    }
}

extension VoiceDesignView {
    static func makeGenerationRequest(
        draft: VoiceDesignDraft,
        model: TTSModel,
        outputPath: String
    ) -> GenerationRequest {
        GenerationRequest(
            modelID: model.id,
            text: draft.text,
            outputPath: outputPath,
            shouldStream: true,
            streamingTitle: String(draft.text.prefix(40)),
            payload: .design(
                voiceDescription: draft.voiceDescription,
                deliveryStyle: draft.emotion
            )
        )
    }
}

// MARK: - Voice Design Brief Settings

private struct VoiceDesignBriefSettings: View {
    @Binding var voiceDescription: String

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
            Text("Voice brief")
                .font(.subheadline.weight(.semibold))

            ContinuousVoiceDescriptionField(
                text: $voiceDescription,
                placeholder: "A warm, deep narrator with a subtle British accent.",
                accessibilityIdentifier: "voiceDesign_voiceDescriptionField"
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassTextField(radius: 8)

            Text("Describe timbre, accent, or delivery style in one tight sentence.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, LayoutConstants.generationConfigurationRowVerticalPadding)
        .overlay(alignment: .topLeading) {
            voiceDescriptionValueAnchor
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceDesign_voiceSetup")
        .accessibilityValue(voiceDescription)
    }

    private var voiceDescriptionValueAnchor: some View {
        Text(voiceDescription.isEmpty ? " " : voiceDescription)
            .font(.caption2)
            .foregroundStyle(.clear)
            .opacity(0.01)
            .frame(width: 1, height: 1, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityLabel(voiceDescription)
            .accessibilityValue(voiceDescription)
            .accessibilityIdentifier("voiceDesign_voiceDescriptionValue")
    }
}
