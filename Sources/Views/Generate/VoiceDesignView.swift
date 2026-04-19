import QwenVoiceNative
import SwiftUI

struct VoiceDesignView: View {
    @Binding private var draft: VoiceDesignDraft
    @StateObject private var coordinator = VoiceDesignCoordinator()

    private let activationID: Int
    private let ttsEngineStore: TTSEngineStore
    private let audioPlayer: AudioPlayerViewModel
    private let modelManager: ModelManagerViewModel
    private let savedVoicesViewModel: SavedVoicesViewModel
    private let appCommandRouter: AppCommandRouter

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

    private var idlePrewarmTaskID: String {
        let debounceKey = draft.idlePrewarmDebounceKey ?? "none"
        return "\(ttsEngineStore.isReady)-\(isModelAvailable)-\(debounceKey)"
    }

    private var screenActivationTaskID: String {
        "\(activationID)|\(ttsEngineStore.isReady)|\(isModelAvailable)"
    }

    private var currentSavedVoiceCandidate: VoiceDesignSavedVoiceCandidate? {
        coordinator.currentSavedVoiceCandidate(for: draft)
    }

    init(
        draft: Binding<VoiceDesignDraft>,
        activationID: Int,
        ttsEngineStore: TTSEngineStore,
        audioPlayer: AudioPlayerViewModel,
        modelManager: ModelManagerViewModel,
        savedVoicesViewModel: SavedVoicesViewModel,
        appCommandRouter: AppCommandRouter
    ) {
        _draft = draft
        self.activationID = activationID
        self.ttsEngineStore = ttsEngineStore
        self.audioPlayer = audioPlayer
        self.modelManager = modelManager
        self.savedVoicesViewModel = savedVoicesViewModel
        self.appCommandRouter = appCommandRouter
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
        .sheet(item: $coordinator.presentedSheet) { presentedSheet in
            switch presentedSheet {
            case .batch(let configuration):
                BatchGenerationSheet(
                    mode: configuration.mode,
                    voice: configuration.voice,
                    emotion: configuration.emotion,
                    voiceDescription: configuration.voiceDescription,
                    refAudio: configuration.refAudio,
                    refText: configuration.refText
                )
                .environmentObject(ttsEngineStore)
                .environmentObject(audioPlayer)
            case .saveVoice(let configuration):
                SavedVoiceSheet(configuration: configuration) { voice in
                    coordinator.handleSavedVoice(
                        voice,
                        draft: draft,
                        savedVoicesViewModel: savedVoicesViewModel,
                        ttsEngineStore: ttsEngineStore
                    )
                }
                .environmentObject(ttsEngineStore)
            }
        }
        .alert(item: $coordinator.actionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .task(id: screenActivationTaskID) {
            await coordinator.handleScreenActivation(
                activationID: activationID,
                model: activeModel,
                isModelAvailable: isModelAvailable,
                ttsEngineStore: ttsEngineStore
            )
        }
        .task(id: idlePrewarmTaskID) {
            await coordinator.scheduleIdlePrewarmIfNeeded(
                draft: draft,
                model: activeModel,
                isModelAvailable: isModelAvailable,
                ttsEngineStore: ttsEngineStore
            )
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
                    isGenerating: coordinator.isGenerating,
                    placeholder: "What should I say?",
                    buttonColor: AppTheme.voiceDesign,
                    batchAction: { coordinator.presentBatch(draft: draft) },
                    batchDisabled: !canRunBatch,
                    generateDisabled: !ttsEngineStore.isReady || !isModelAvailable || draft.voiceDescription.isEmpty,
                    isEmbedded: true,
                    usesFlexibleEmbeddedHeight: true,
                    onGenerate: {
                        coordinator.generate(
                            draft: draft,
                            activeModel: activeModel,
                            isModelAvailable: isModelAvailable,
                            ttsEngineStore: ttsEngineStore,
                            audioPlayer: audioPlayer,
                            modelManager: modelManager
                        )
                    }
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
            return "Vocello is still preparing the generation engine."
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
                        Task { await modelManager.download(model) }
                    },
                    onSecondaryAction: {
                        appCommandRouter.navigate(to: .models)
                    }
                )
            }

            generationReadiness
            saveVoiceAction

            if let errorMessage = coordinator.errorMessage {
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
                    coordinator.presentSavedVoiceSheet(for: draft)
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
