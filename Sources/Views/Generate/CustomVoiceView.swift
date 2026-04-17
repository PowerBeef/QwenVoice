import QwenVoiceNative
import SwiftUI

struct CustomVoiceView: View {
    @EnvironmentObject var ttsEngineStore: TTSEngineStore
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject var modelManager: ModelManagerViewModel
    @EnvironmentObject var appCommandRouter: AppCommandRouter

    @Binding private var draft: CustomVoiceDraft
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var showingBatch = false

    private var activeMode: GenerationMode {
        .custom
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
    }

    private var canRunBatch: Bool {
        ttsEngineStore.isReady
            && isModelAvailable
    }

    private var idlePrewarmRequest: GenerationRequest? {
        guard let model = activeModel else { return nil }
        return GenerationRequest(
            modelID: model.id,
            text: draft.text,
            outputPath: "",
            payload: .custom(
                speakerID: draft.selectedSpeaker,
                deliveryStyle: draft.emotion
            )
        )
    }

    private var idlePrewarmTaskID: String {
        let identity = idlePrewarmRequest.map(GenerationSemantics.prewarmIdentityKey(for:)) ?? "none"
        return "\(ttsEngineStore.isReady)|\(isModelAvailable)|\(identity)"
    }

    init(draft: Binding<CustomVoiceDraft>) {
        _draft = draft
    }

    var body: some View {
        PageScaffold(
            accessibilityIdentifier: "screen_customVoice",
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
                mode: .custom,
                voice: draft.selectedSpeaker,
                emotion: draft.emotion
            )
            .environmentObject(ttsEngineStore)
            .environmentObject(audioPlayer)
        }
        .task(id: idlePrewarmTaskID) {
            await prewarmSelectedModelIfNeeded()
        }
        .onAppear(perform: syncUITestState)
        .onChange(of: draft.selectedSpeaker) { _, _ in syncUITestState() }
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

private extension CustomVoiceView {
    var configurationPanel: some View {
        CompactConfigurationSection(
            title: "Configuration",
            detail: "Pick a built-in speaker, then shape the delivery before you generate.",
            iconName: "slider.horizontal.3",
            accentColor: AppTheme.customVoice,
            rowSpacing: LayoutConstants.generationConfigurationRowSpacing,
            panelPadding: LayoutConstants.generationConfigurationPanelPadding,
            contentSlotHeight: LayoutConstants.generationConfigurationSlotHeight,
            accessibilityIdentifier: "customVoice_configuration"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                speakerSettings
                deliverySettings
            }
        }
        .overlay(alignment: .topLeading) {
            HiddenAccessibilityMarker(
                value: "Configuration",
                identifier: "customVoice_configuration"
            )
        }
        .animation(.none, value: draft.selectedSpeaker)
        .fixedSize(horizontal: false, vertical: true)
    }

    var composerPanel: some View {
        StudioSectionCard(
            title: "Script",
            iconName: "text.alignleft",
            accentColor: AppTheme.customVoice,
            trailingText: canGenerate ? "Ready" : nil,
            fillsAvailableHeight: true,
            accessibilityIdentifier: "customVoice_script"
        ) {
            VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
                TextInputView(
                    text: $draft.text,
                    isGenerating: isGenerating,
                    placeholder: "What should I say?",
                    buttonColor: AppTheme.customVoice,
                    batchAction: { showingBatch = true },
                    batchDisabled: !canRunBatch,
                    isEmbedded: true,
                    usesFlexibleEmbeddedHeight: true,
                    onGenerate: generate
                )
                .disabled(!ttsEngineStore.isReady || !isModelAvailable)

                composerFooter
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    var speakerSettings: some View {
        SpeakerPickerRow(selectedSpeaker: $draft.selectedSpeaker)
    }

    var deliverySettings: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
            Text("Delivery")
                .font(.subheadline.weight(.semibold))

            DeliveryControlsView(
                emotion: $draft.emotion,
                accentColor: AppTheme.customVoice,
                isCompact: true,
                showsLabel: false
            )
        }
        .padding(.vertical, LayoutConstants.generationConfigurationRowVerticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("customVoice_toneSpeed")
    }

    // speakerPicker moved to SpeakerPickerRow struct for rebuild isolation

    var generationReadiness: some View {
        WorkflowReadinessNote(
            isReady: canGenerate,
            title: canGenerate ? "Ready to generate" : readinessTitle,
            detail: readinessDetail,
            accentColor: AppTheme.customVoice,
            accessibilityIdentifier: "customVoice_readiness"
        )
    }

    var readinessTitle: String {
        if !ttsEngineStore.isReady {
            return "Engine starting"
        }
        if !isModelAvailable {
            return "Install the active model"
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
        if draft.text.isEmpty {
            return "The selected speaker and delivery settings are ready as soon as the line is written."
        }
        return "Everything is in place for a live preview and a saved generation."
    }

    // selectedSpeakerValueAnchor moved to SpeakerPickerRow struct

    var composerFooter: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.compactGap) {
            if let model = activeModel,
               let primaryActionTitle = modelManager.primaryActionTitle(for: model) {
                ModelRecoveryCard(
                    title: primaryActionTitle,
                    detail: modelManager.recoveryDetail(for: model),
                    primaryActionTitle: primaryActionTitle,
                    accentColor: AppTheme.customVoice,
                    accessibilityIdentifier: "customVoice_modelRecovery",
                    onPrimaryAction: {
                        Task { await modelManager.download(model) }
                    },
                    onSecondaryAction: {
                        appCommandRouter.navigate(to: .models)
                    }
                )
            }

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
}

// MARK: - Actions

private extension CustomVoiceView {
    func syncUITestState() {
        guard UITestAutomationSupport.isEnabled else { return }
        TestStateProvider.shared.selectedSpeaker = draft.selectedSpeaker
        TestStateProvider.shared.emotion = draft.emotion
        TestStateProvider.shared.text = draft.text
        TestStateProvider.shared.isGenerating = isGenerating
    }

    func handleTestStartGeneration(_ notification: Notification) {
        guard UITestAutomationSupport.isEnabled,
              let screen = notification.userInfo?["screen"] as? String,
              screen == "customVoice" else { return }

        if let text = notification.userInfo?["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.text = text
        }

        generate()
    }

    func handleTestSeedScreenState(_ notification: Notification) {
        guard UITestAutomationSupport.isEnabled,
              let screen = notification.userInfo?["screen"] as? String,
              screen == "customVoice" else { return }

        if let speaker = notification.userInfo?["speaker"] as? String,
           !speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.selectedSpeaker = speaker
        }
        if let emotion = notification.userInfo?["emotion"] as? String {
            draft.emotion = emotion
        }
        if let text = notification.userInfo?["text"] as? String {
            draft.text = text
        }
    }

    func generate() {
        guard !draft.text.isEmpty, ttsEngineStore.isReady else { return }

        if let model = activeModel, !isModelAvailable {
            errorMessage = modelManager.recoveryDetail(for: model)
            return
        }

        isGenerating = true
        errorMessage = nil

        Task {
            do {
                UITestAutomationSupport.recordAction("custom-generate-start", appSupportDir: QwenVoiceApp.appSupportDir)

                guard let model = activeModel else {
                    errorMessage = "Model configuration not found"
                    isGenerating = false
                    return
                }

                let outputPath = makeOutputPath(subfolder: model.outputSubfolder, text: draft.text)
                let generationRequest = Self.makeGenerationRequest(
                    draft: draft,
                    model: model,
                    outputPath: outputPath
                )
                audioPlayer.prepareStreamingPreview(
                    title: String(draft.text.prefix(40)),
                    shouldAutoPlay: AudioService.shouldAutoPlay
                )

                let result = try await ttsEngineStore.generate(generationRequest)

                var generation = Generation(
                    text: draft.text,
                    mode: model.mode.rawValue,
                    modelTier: model.tier,
                    voice: draft.selectedSpeaker,
                    emotion: draft.emotion,
                    speed: nil,
                    audioPath: result.audioPath,
                    duration: result.durationSeconds,
                    createdAt: Date()
                )

                try GenerationPersistence.persistAndAutoplay(
                    &generation, result: result, text: draft.text,
                    audioPlayer: audioPlayer, caller: "CustomVoiceView"
                )
                UITestAutomationSupport.recordAction("custom-generate-success", appSupportDir: QwenVoiceApp.appSupportDir)
            } catch {
                UITestAutomationSupport.recordAction("custom-generate-error", appSupportDir: QwenVoiceApp.appSupportDir)
                if (error as? GenerationPersistence.PersistenceError) == nil {
                    audioPlayer.abortLivePreviewIfNeeded()
                }
                errorMessage = error.localizedDescription
            }

            isGenerating = false
            syncUITestState()
        }
    }

    func prewarmSelectedModelIfNeeded() async {
        guard let idlePrewarmRequest else { return }
        guard ttsEngineStore.isReady, isModelAvailable, !isGenerating else { return }
        await ttsEngineStore.prewarmModelIfNeeded(for: idlePrewarmRequest)
    }

}

extension CustomVoiceView {
    static func makeGenerationRequest(
        draft: CustomVoiceDraft,
        model: TTSModel,
        outputPath: String
    ) -> GenerationRequest {
        GenerationRequest(
            modelID: model.id,
            text: draft.text,
            outputPath: outputPath,
            shouldStream: true,
            streamingTitle: String(draft.text.prefix(40)),
            payload: .custom(
                speakerID: draft.selectedSpeaker,
                deliveryStyle: draft.emotion
            )
        )
    }
}

// MARK: - Isolated Speaker Picker (prevents parent view rebuild cascade)

private struct SpeakerPickerRow: View {
    @Binding var selectedSpeaker: String

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
            Text("Speaker")
                .font(.subheadline.weight(.semibold))

            Picker("Speaker", selection: $selectedSpeaker) {
                ForEach(TTSModel.allSpeakers, id: \.self) { speaker in
                    Text(speaker.capitalized).tag(speaker)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .focusEffectDisabled()
            .frame(minWidth: LayoutConstants.configurationControlMinWidth, maxWidth: 220, alignment: .leading)
            .accessibilityValue(selectedSpeaker.capitalized)
            .accessibilityIdentifier("customVoice_speakerPicker")

            Text("Choose the built-in speaker that should deliver this line.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, LayoutConstants.generationConfigurationRowVerticalPadding)
        .overlay(alignment: .topLeading) {
            Text(selectedSpeaker.capitalized)
                .font(.caption2)
                .foregroundStyle(.clear)
                .opacity(0.01)
                .frame(width: 1, height: 1, alignment: .leading)
                .allowsHitTesting(false)
                .accessibilityLabel(selectedSpeaker.capitalized)
                .accessibilityValue(selectedSpeaker.capitalized)
                .accessibilityIdentifier("customVoice_selectedSpeaker")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("customVoice_voiceSetup")
    }
}
