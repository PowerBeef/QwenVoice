import SwiftUI

struct CustomVoiceView: View {
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel

    @State private var workflowMode: CustomVoiceWorkflowMode = .presetSpeaker
    @State private var selectedSpeaker = TTSModel.defaultSpeaker
    @State private var voiceDescription = ""
    @State private var emotion = "Normal tone"
    @State private var text = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var showingBatch = false

    private var activeMode: GenerationMode {
        workflowMode.generationMode
    }

    private var activeModel: TTSModel? {
        TTSModel.model(for: activeMode)
    }

    private var isModelAvailable: Bool {
        activeModel?.isAvailable(in: QwenVoiceApp.modelsDir) ?? false
    }

    private var modelDisplayName: String {
        activeModel?.name ?? "Unknown"
    }

    private var canRunBatch: Bool {
        pythonBridge.isReady && isModelAvailable && (workflowMode == .presetSpeaker || !voiceDescription.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutConstants.sectionSpacing) {
                    GenerationHeaderView(
                        title: workflowMode == .presetSpeaker ? "Custom Voice" : "Voice Design",
                        subtitle: workflowMode == .presetSpeaker
                            ? "Choose a built-in speaker, then shape the delivery."
                            : "Describe the voice, then shape the delivery.",
                        titleAccessibilityIdentifier: "customVoice_title",
                        subtitleAccessibilityIdentifier: "customVoice_subtitle"
                    ) {
                        GenerationModeSwitch(selection: $workflowMode)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("customVoice_header")

                    if !isModelAvailable {
                        modelUnavailableBanner
                    }

                    StudioSectionCard(
                        title: "Voice",
                        accentColor: AppTheme.customVoice,
                        accessibilityIdentifier: "customVoice_voiceSetup"
                    ) {
                        if workflowMode == .presetSpeaker {
                            FlowLayout(spacing: 10) {
                                speakerButtons
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField(
                                    "A warm, deep narrator with a subtle British accent.",
                                    text: $voiceDescription,
                                    axis: .vertical
                                )
                                .textFieldStyle(.plain)
                                .font(.body)
                                .padding(12)
                                .background(Color.primary.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                )
                                .lineLimit(1...3)
                                .accessibilityIdentifier("customVoice_voiceDescriptionField")
                            }
                        }
                    }

                    DeliveryControlsView(
                        emotion: $emotion,
                        accentColor: AppTheme.customVoice
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("customVoice_toneSpeed")

                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 12) {
                            TextInputView(
                                text: $text,
                                isGenerating: isGenerating,
                                placeholder: "What should I say?",
                                buttonColor: AppTheme.customVoice,
                                batchAction: { showingBatch = true },
                                batchDisabled: !canRunBatch,
                                onGenerate: generate
                            )
                            .disabled(!pythonBridge.isReady || !isModelAvailable || (workflowMode == .voiceDesign && voiceDescription.isEmpty))

                            if let errorMessage {
                                Label(errorMessage, systemImage: "exclamationmark.triangle")
                                    .foregroundColor(.red)
                                    .font(.callout)
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("customVoice_script")
                }
                .padding(LayoutConstants.canvasPadding)
                .contentColumn()
            }
        }
        .accessibilityIdentifier("screen_customVoice")
        .sheet(isPresented: $showingBatch) {
            if workflowMode == .voiceDesign {
                BatchGenerationSheet(
                    mode: .design,
                    emotion: emotion,
                    voiceDescription: voiceDescription
                )
                .environmentObject(pythonBridge)
                .environmentObject(audioPlayer)
            } else {
                BatchGenerationSheet(
                    mode: .custom,
                    voice: selectedSpeaker,
                    emotion: emotion
                )
                .environmentObject(pythonBridge)
                .environmentObject(audioPlayer)
            }
        }
        .task(id: idlePrewarmTaskID) {
            await prewarmSelectedModelIfNeeded()
        }
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
                NotificationCenter.default.post(name: .navigateToModels, object: activeModel?.id)
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
            .accessibilityIdentifier("customVoice_goToModels")
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
        .accessibilityIdentifier("customVoice_modelBanner")
    }

    // MARK: - Generate

    private func generate() {
        guard !text.isEmpty, pythonBridge.isReady else { return }
        if workflowMode == .voiceDesign { guard !voiceDescription.isEmpty else { return } }

        if let model = activeModel, !model.isAvailable(in: QwenVoiceApp.modelsDir) {
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
                let result: GenerationResult
                var generation: Generation

                if workflowMode == .voiceDesign {
                    result = try await pythonBridge.generateDesignStreamingFlow(
                        modelID: model.id,
                        text: text,
                        voiceDescription: voiceDescription,
                        emotion: emotion,
                        outputPath: outputPath
                    )

                    generation = Generation(
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
                } else {
                    result = try await pythonBridge.generateCustomStreamingFlow(
                        modelID: model.id,
                        text: text,
                        voice: selectedSpeaker,
                        emotion: emotion,
                        outputPath: outputPath
                    )

                    generation = Generation(
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
                }

                try persistGenerationAndMaybeAutoplay(&generation, result: result)
                UITestAutomationSupport.recordAction("custom-generate-success", appSupportDir: QwenVoiceApp.appSupportDir)
            } catch {
                UITestAutomationSupport.recordAction("custom-generate-error", appSupportDir: QwenVoiceApp.appSupportDir)
                audioPlayer.abortLivePreviewIfNeeded()
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }

    private func persistGenerationAndMaybeAutoplay(_ generation: inout Generation, result: GenerationResult) throws {
        AppPerformanceSignposts.emit("Final File Ready")

        var persistenceError: Error?
        do {
            let saveStart = DispatchTime.now().uptimeNanoseconds
            try DatabaseService.shared.saveGeneration(&generation)
            #if DEBUG
            print("[Performance][CustomVoiceView] db_save_wall_ms=\(elapsedMs(since: saveStart))")
            #endif

            let notificationStart = DispatchTime.now().uptimeNanoseconds
            NotificationCenter.default.post(name: .generationSaved, object: nil)
            #if DEBUG
            print("[Performance][CustomVoiceView] history_notification_wall_ms=\(elapsedMs(since: notificationStart))")
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
            print("[Performance][CustomVoiceView] autoplay_start_wall_ms=\(elapsedMs(since: autoplayStart))")
            #endif
        }

        if let persistenceError {
            throw persistenceError
        }
    }

    private func elapsedMs(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    private var idlePrewarmTaskID: String {
        "\(pythonBridge.isReady)-\(activeModel?.id ?? "none")-\(workflowMode.rawValue)-\(isModelAvailable)"
    }

    private func prewarmSelectedModelIfNeeded() async {
        guard let model = activeModel else { return }
        guard pythonBridge.isReady, isModelAvailable, !isGenerating else { return }

        await pythonBridge.prewarmModelIfNeeded(
            modelID: model.id,
            mode: activeMode,
            voice: workflowMode == .presetSpeaker ? selectedSpeaker : nil,
            instruct: workflowMode == .presetSpeaker ? emotion : nil
        )
    }

    @ViewBuilder
    private var speakerButtons: some View {
        ForEach(TTSModel.allSpeakers, id: \.self) { speaker in
            Button {
                AppLaunchConfiguration.performAnimated(.spring(response: 0.3, dampingFraction: 0.7)) {
                    selectedSpeaker = speaker
                }
            } label: {
                Text(speaker.capitalized)
                    .voiceChoiceChip(isSelected: selectedSpeaker == speaker, color: AppTheme.customVoice)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("customVoice_speaker_\(speaker)")
            .accessibilityValue(selectedSpeaker == speaker ? "selected" : "not selected")
        }
    }
}
