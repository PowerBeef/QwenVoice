import SwiftUI

struct CustomVoiceView: View {
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject var modelManager: ModelManagerViewModel

    let isActive: Bool

    @State private var selectedSpeaker = TTSModel.defaultSpeaker
    @State private var emotion = "Normal tone"
    @State private var text = ""
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
        pythonBridge.isReady
            && isModelAvailable
            && !text.isEmpty
    }

    private var canRunBatch: Bool {
        pythonBridge.isReady
            && isModelAvailable
    }

    private var idlePrewarmTaskID: String {
        "\(isActive)-\(pythonBridge.isReady)-\(activeModel?.id ?? "none")-\(isModelAvailable)"
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
        }
        .sheet(isPresented: $showingBatch) {
            BatchGenerationSheet(
                mode: .custom,
                voice: selectedSpeaker,
                emotion: emotion
            )
            .environmentObject(pythonBridge)
            .environmentObject(audioPlayer)
        }
        .task(id: idlePrewarmTaskID) {
            await prewarmSelectedModelIfNeeded()
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
        .animation(.none, value: selectedSpeaker)
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
                    text: $text,
                    isGenerating: isGenerating,
                    placeholder: "What should I say?",
                    buttonColor: AppTheme.customVoice,
                    batchAction: { showingBatch = true },
                    batchDisabled: !canRunBatch,
                    isEmbedded: true,
                    usesFlexibleEmbeddedHeight: true,
                    onGenerate: generate
                )
                .disabled(!pythonBridge.isReady || !isModelAvailable)

                composerFooter
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    var speakerSettings: some View {
        SpeakerPickerRow(selectedSpeaker: $selectedSpeaker)
    }

    var deliverySettings: some View {
        ConfigurationFieldRow(
            label: "Delivery",
            rowVerticalPadding: LayoutConstants.generationConfigurationRowVerticalPadding,
            horizontalSpacing: 12,
            stackedSpacing: LayoutConstants.generationConfigurationRowSpacing,
            supportingSpacing: 4
        ) {
            DeliveryControlsView(
                emotion: $emotion,
                accentColor: AppTheme.customVoice,
                isCompact: true,
                showsLabel: false
            )
        }
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
        if !pythonBridge.isReady {
            return "Engine starting"
        }
        if !isModelAvailable {
            return "Install the active model"
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
        if text.isEmpty {
            return "The selected speaker and delivery settings are ready as soon as the line is written."
        }
        return "Everything is in place for a live preview and a saved generation."
    }

    // selectedSpeakerValueAnchor moved to SpeakerPickerRow struct

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
}

// MARK: - Actions

private extension CustomVoiceView {
    func generate() {
        guard !text.isEmpty, pythonBridge.isReady else { return }

        if let model = activeModel, !isModelAvailable {
            errorMessage = "Model '\(model.name)' is unavailable or incomplete. Go to Settings > Models to download or re-download it."
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

                let outputPath = makeOutputPath(subfolder: model.outputSubfolder, text: text)
                audioPlayer.prepareStreamingPreview(
                    title: String(text.prefix(40)),
                    shouldAutoPlay: AudioService.shouldAutoPlay
                )

                let result = try await pythonBridge.generateCustomStreamingFlow(
                    modelID: model.id,
                    text: text,
                    voice: selectedSpeaker,
                    emotion: emotion,
                    outputPath: outputPath
                )

                var generation = Generation(
                    text: text,
                    mode: model.mode.rawValue,
                    modelTier: model.tier,
                    voice: selectedSpeaker,
                    emotion: emotion,
                    speed: nil,
                    audioPath: result.audioPath,
                    duration: result.durationSeconds,
                    createdAt: Date()
                )

                try GenerationPersistence.persistAndAutoplay(
                    &generation, result: result, text: text,
                    audioPlayer: audioPlayer, caller: "CustomVoiceView"
                )
                UITestAutomationSupport.recordAction("custom-generate-success", appSupportDir: QwenVoiceApp.appSupportDir)
            } catch {
                UITestAutomationSupport.recordAction("custom-generate-error", appSupportDir: QwenVoiceApp.appSupportDir)
                audioPlayer.abortLivePreviewIfNeeded()
                errorMessage = error.localizedDescription
            }

            isGenerating = false
        }
    }

    func prewarmSelectedModelIfNeeded() async {
        guard let model = activeModel else { return }
        guard isActive else { return }
        guard pythonBridge.isReady, isModelAvailable, !isGenerating else { return }

        await pythonBridge.prewarmModelIfNeeded(
            modelID: model.id,
            mode: activeMode,
            voice: selectedSpeaker,
            instruct: emotion
        )
    }
}

// MARK: - Isolated Speaker Picker (prevents parent view rebuild cascade)

private struct SpeakerPickerRow: View {
    @Binding var selectedSpeaker: String

    var body: some View {
        ConfigurationFieldRow(
            label: "Speaker",
            rowVerticalPadding: LayoutConstants.generationConfigurationRowVerticalPadding,
            horizontalSpacing: 12,
            stackedSpacing: LayoutConstants.generationConfigurationRowSpacing,
            supportingSpacing: 4
        ) {
            HStack(spacing: 10) {
                Picker("Speaker", selection: $selectedSpeaker) {
                    ForEach(TTSModel.allSpeakers, id: \.self) { speaker in
                        Text(speaker.capitalized).tag(speaker)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .transaction { $0.animation = nil }
                .frame(minWidth: LayoutConstants.configurationControlMinWidth, maxWidth: 220, alignment: .leading)
                .accessibilityValue(selectedSpeaker.capitalized)
                .accessibilityIdentifier("customVoice_speakerPicker")

                Spacer(minLength: 0)
            }
        } supporting: {
            Text("Choose the built-in speaker that should deliver this line.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
