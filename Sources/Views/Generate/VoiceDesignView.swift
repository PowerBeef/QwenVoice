import SwiftUI

struct VoiceDesignView: View {
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject var modelManager: ModelManagerViewModel

    @Binding private var voiceDescription: String
    let isActive: Bool
    @State private var emotion = "Normal tone"
    @State private var text = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var showingBatch = false

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
        pythonBridge.isReady
            && isModelAvailable
            && !text.isEmpty
            && !voiceDescription.isEmpty
    }

    private var canRunBatch: Bool {
        pythonBridge.isReady
            && isModelAvailable
            && !voiceDescription.isEmpty
    }

    private var idlePrewarmTaskID: String {
        "\(isActive)-\(pythonBridge.isReady)-\(activeModel?.id ?? "none")-design-\(isModelAvailable)"
    }

    init(voiceDescription: Binding<String>, isActive: Bool) {
        _voiceDescription = voiceDescription
        self.isActive = isActive
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
                emotion: emotion,
                voiceDescription: voiceDescription
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
                    text: $text,
                    isGenerating: isGenerating,
                    placeholder: "What should I say?",
                    buttonColor: AppTheme.voiceDesign,
                    batchAction: { showingBatch = true },
                    batchDisabled: !canRunBatch,
                    generateDisabled: !pythonBridge.isReady || !isModelAvailable || voiceDescription.isEmpty,
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
        VoiceDesignBriefSettings(voiceDescription: $voiceDescription)
    }

    var deliverySettings: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
            Text("Delivery")
                .font(.subheadline.weight(.semibold))

            DeliveryControlsView(
                emotion: $emotion,
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
        if !pythonBridge.isReady {
            return "Engine starting"
        }
        if !isModelAvailable {
            return "Install the active model"
        }
        if voiceDescription.isEmpty {
            return "Add a voice brief"
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
        if voiceDescription.isEmpty {
            return "Describe the voice you want before writing the final line."
        }
        if text.isEmpty {
            return "Once the line is written, the generated voice will use this brief and delivery."
        }
        return "Everything is in place for a live preview and a saved generation."
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
}

// MARK: - Actions

private extension VoiceDesignView {
    func generate() {
        guard !text.isEmpty, !voiceDescription.isEmpty, pythonBridge.isReady else { return }

        if let model = activeModel, !isModelAvailable {
            errorMessage = "Model '\(model.name)' is unavailable or incomplete. Go to Settings > Models to download or re-download it."
            return
        }

        isGenerating = true
        errorMessage = nil

        Task {
            do {
                UITestAutomationSupport.recordAction("design-generate-start", appSupportDir: QwenVoiceApp.appSupportDir)

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

                let result = try await pythonBridge.generateDesignStreamingFlow(
                    modelID: model.id,
                    text: text,
                    voiceDescription: voiceDescription,
                    emotion: emotion,
                    outputPath: outputPath
                )

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
                UITestAutomationSupport.recordAction("design-generate-success", appSupportDir: QwenVoiceApp.appSupportDir)
            } catch {
                UITestAutomationSupport.recordAction("design-generate-error", appSupportDir: QwenVoiceApp.appSupportDir)
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
            voice: nil,
            instruct: emotion
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
