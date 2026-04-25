import QwenVoiceNative
import SwiftUI

struct CustomVoiceView: View {
    @Binding private var draft: CustomVoiceDraft
    @StateObject private var coordinator = CustomVoiceCoordinator()

    private let activationID: Int
    private let ttsEngineStore: TTSEngineStore
    private let audioPlayer: AudioPlayerViewModel
    private let modelManager: ModelManagerViewModel
    private let appCommandRouter: AppCommandRouter

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

    private var idlePrewarmTaskID: String {
        let debounceKey = draft.idlePrewarmDebounceKey ?? "none"
        return "\(ttsEngineStore.isReady)|\(isModelAvailable)|\(debounceKey)"
    }

    private var screenActivationTaskID: String {
        "\(activationID)|\(ttsEngineStore.isReady)|\(isModelAvailable)"
    }

    init(
        draft: Binding<CustomVoiceDraft>,
        activationID: Int,
        ttsEngineStore: TTSEngineStore,
        audioPlayer: AudioPlayerViewModel,
        modelManager: ModelManagerViewModel,
        appCommandRouter: AppCommandRouter
    ) {
        _draft = draft
        self.activationID = activationID
        self.ttsEngineStore = ttsEngineStore
        self.audioPlayer = audioPlayer
        self.modelManager = modelManager
        self.appCommandRouter = appCommandRouter
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
            GenerationStudioLayout(
                mode: activeMode,
                title: "Choose a studio voice",
                subtitle: "Select a built-in speaker, shape the delivery, then render a polished local take.",
                statusTitle: canGenerate ? "Ready" : readinessTitle,
                statusDetail: readinessDetail,
                isReady: canGenerate,
                modelName: modelDisplayName,
                characterCount: draft.text.count,
                characterLimit: 500,
                onModeSelect: navigateToMode
            ) {
                composerPanel
                    .layoutPriority(1)
            } inspector: {
                configurationPanel
            }
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
            }
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
            configurationContent
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

    var configurationContent: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
            speakerSettings
            deliverySettings
        }
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
                    isGenerating: coordinator.isGenerating,
                    placeholder: "What should I say?",
                    buttonColor: AppTheme.customVoice,
                    batchAction: { coordinator.presentBatch(draft: draft) },
                    batchDisabled: !canRunBatch,
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

    func navigateToMode(_ mode: GenerationMode) {
        appCommandRouter.navigate(to: SidebarItem.item(for: mode))
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
            return "Vocello is still preparing the generation engine."
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
}

// MARK: - Isolated Speaker Picker (prevents parent view rebuild cascade)

private struct SpeakerPickerRow: View {
    @Binding var selectedSpeaker: String

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
            Text("Speaker")
                .font(.subheadline.weight(.semibold))

            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 118), spacing: 8, alignment: .top),
                    GridItem(.flexible(minimum: 118), spacing: 8, alignment: .top)
                ],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(TTSModel.allSpeakers, id: \.self) { speaker in
                    let speakerDetails = Self.details(for: speaker)
                    let isSelected = selectedSpeaker == speaker

                    Button {
                        selectedSpeaker = speaker
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text(String(speakerDetails.name.prefix(1)))
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(isSelected ? AppTheme.warmIvory : AppTheme.customVoice)
                                    .frame(width: 26, height: 26)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(AppTheme.customVoice.opacity(isSelected ? 0.42 : 0.18))
                                    )

                                Spacer(minLength: 0)

                                Image(systemName: isSelected ? "checkmark.circle.fill" : "waveform")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(isSelected ? AppTheme.customVoice : AppTheme.textSecondary)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(speakerDetails.name)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .lineLimit(1)

                                Text(speakerDetails.description)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(
                                    isSelected
                                        ? AppTheme.customVoice.opacity(0.36)
                                        : AppTheme.inlineFill
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(
                                    isSelected
                                        ? AppTheme.customVoice.opacity(0.82)
                                        : AppTheme.inlineStroke.opacity(0.38),
                                    lineWidth: isSelected ? 1.2 : 0.8
                                )
                        )
                        .vocelloGlassSurface(
                            padding: 0,
                            radius: 14,
                            fill: isSelected ? AppTheme.customVoice.opacity(0.16) : AppTheme.inlineFill
                        )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .accessibilityLabel(speakerDetails.name)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Speaker")
            .accessibilityValue(selectedSpeaker.capitalized)
            .accessibilityIdentifier("customVoice_speakerPicker")

            Text("Choose the built-in speaker that should deliver this line.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
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

    private static func details(for speaker: String) -> (name: String, description: String) {
        switch speaker.lowercased() {
        case "ryan":
            return ("Ryan", "Clear · confident")
        case "aiden":
            return ("Aiden", "Warm · grounded")
        case "serena":
            return ("Serena", "Bright · articulate")
        case "vivian":
            return ("Vivian", "Smooth · premium")
        default:
            return (speaker.capitalized, "Built-in speaker")
        }
    }
}
