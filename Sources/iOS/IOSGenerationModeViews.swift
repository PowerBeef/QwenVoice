import SwiftUI
import UniformTypeIdentifiers
import QwenVoiceCore

struct IOSCustomVoiceView: View {
    @EnvironmentObject private var ttsEngine: TTSEngineStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var modelManager: ModelManagerViewModel
    @Environment(AppModel.self) private var appModel
    @Environment(\.presentIOSPlayerSheet) private var presentPlayerSheet

    let isActive: Bool
    @Binding var selectedTab: IOSAppTab
    @Binding var draft: CustomVoiceDraft
    @Binding var primaryAction: IOSGeneratePrimaryActionDescriptor
    @State private var isScriptFocused = false

    // Generation lifecycle state lives on AppModel.customCoordinator
    // (Phase 3b extraction). Keep these computed-property aliases so the
    // rest of the view body stays readable without churn.
    private var coordinator: StudioGenerationCoordinator { appModel.customCoordinator }
    private var isGenerating: Bool {
        get { coordinator.isGenerating }
    }
    private var errorMessage: String? {
        get { coordinator.errorMessage }
    }
    private var lastCompletedOutput: IOSStudioInlinePlayerItem? {
        get { coordinator.lastCompletedOutput }
    }

    private var studioGenState: IOSStudioGenState {
        if coordinator.isGenerating { return .generating }
        if let output = coordinator.lastCompletedOutput { return .complete(output) }
        return .idle
    }

    private func expandInlinePlayer() {
        guard let output = coordinator.lastCompletedOutput else { return }
        presentPlayerSheet(output.playerSheetItem)
    }

    private var speakerDisplay: SpeakerDescriptor? {
        TTSContract.speakerDescriptor(id: draft.selectedSpeaker)
    }

    private var speakerDisplayName: String {
        speakerDisplay?.displayName ?? draft.selectedSpeaker.capitalized
    }

    private var deliveryChipLabel: String {
        let preset = draft.delivery.selectedPresetLabel
        if draft.delivery.mode == .custom {
            let trimmed = draft.delivery.customText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Custom delivery" : trimmed
        }
        if draft.delivery.supportsIntensity {
            return "\(preset) · \(draft.delivery.selectedIntensity.label)"
        }
        return preset
    }

    private var activeModel: TTSModel? {
        TTSModel.model(for: .custom)
    }

    private var supportsDeliveryControl: Bool {
        activeModel?.supportsInstructionControl ?? false
    }

    private var allowsExecution: Bool {
        ttsEngine.supportsMode(.custom)
    }

    private var isModelAvailable: Bool {
        guard let activeModel else { return false }
        return modelManager.isAvailable(activeModel)
    }

    private var promptText: String {
        IOSGenerationTextLimitPolicy.clamped(draft.text, mode: .custom)
    }

    private var promptTextBinding: Binding<String> {
        Binding(
            get: { promptText },
            set: { draft.text = IOSGenerationTextLimitPolicy.clamped($0, mode: .custom) }
        )
    }

    private var scriptLimitState: IOSGenerationTextLimitPolicy.State {
        IOSGenerationTextLimitPolicy.state(for: promptText, mode: .custom)
    }

    private var canGenerate: Bool {
        allowsExecution
            && ttsEngine.isReady
            && isModelAvailable
            && !scriptLimitState.trimmedIsEmpty
            && !scriptLimitState.isOverLimit
            && !ttsEngine.hasActiveGeneration
    }

    private var canGenerateInCurrentRuntime: Bool {
        canGenerate
    }

    private var chromeOpacity: Double {
        isGenerationActive ? 0.76 : 1
    }

    private var setupMessage: String? {
        if !isModelAvailable, let activeModel {
            return "Install \(activeModel.name) in Settings."
        }
        return nil
    }

    private var promptHelper: String? {
        if !isScriptFocused && promptText.isEmpty {
            return nil
        }
        return scriptLimitState.helperMessage
    }

    private var primaryActionToken: String {
        "\(isGenerationActive)-\(canGenerateInCurrentRuntime)"
    }

    private var isGenerationActive: Bool {
        isGenerating || ttsEngine.hasActiveGeneration
    }

    var body: some View {
        pageContent
            .accessibilityIdentifier("screen_customVoice")
            .task(id: primaryActionToken) {
                guard isActive else { return }
                publishPrimaryAction()
            }
            .onChange(of: isActive) { _, active in
                guard active else { return }
                publishPrimaryAction()
            }
    }

    @ViewBuilder
    private var pageContent: some View {
        IOSStudioCanvas(
            mode: .custom,
            script: promptTextBinding,
            placeholder: "Type or paste your script.",
            modeMetaLabel: "Built-in voice",
            charLimit: scriptLimitState.limit,
            tint: IOSBrandTheme.custom,
            genState: studioGenState,
            errorMessage: coordinator.errorMessage,
            canGenerate: canGenerateInCurrentRuntime,
            modelInstalled: isModelAvailable,
            modelDisplayName: activeModel?.name ?? "Voice model",
            setupChips: { customModeChips },
            onGenerate: generate,
            onCancel: cancelGeneration,
            onInstallModel: { selectedTab = .settings },
            onPlayerDismiss: { coordinator.dismissInlinePlayer() },
            onPlayerExpand: expandInlinePlayer
        )
        .opacity(chromeOpacity)
        .iosAppAnimation(IOSSelectionMotion.modeCrossfade, value: isGenerationActive)
    }

    @ViewBuilder
    private var customModeChips: some View {
        IOSStudioSetupChip(
            eyebrow: "Voice",
            value: speakerDisplayName,
            leadingAvatar: AnyView(
                IOSVoiceAvatar(seed: draft.selectedSpeaker, initials: speakerDisplayName, diameter: 32)
            ),
            tint: IOSBrandTheme.custom,
            action: presentVoicePicker
        )
        IOSStudioSetupChip(
            eyebrow: "Delivery",
            value: deliveryChipLabel,
            leadingSymbol: "waveform",
            tint: IOSEmotionPresetPalette.dotColor(forID: draft.delivery.selectedPresetID),
            action: presentDeliveryPicker
        )
        .disabled(!supportsDeliveryControl)
        .opacity(supportsDeliveryControl ? 1 : 0.45)
        IOSStudioSetupChip(
            eyebrow: "Language",
            value: draft.selectedLanguage.displayName,
            leadingSymbol: "globe",
            tint: IOSBrandTheme.custom,
            action: presentLanguagePicker
        )
    }

    private func presentVoicePicker() {
        appModel.presentBottomPanel { bottomSafeAreaInset, dismiss in
            AnyView(
                IOSVoicePickerSheet(
                    speakers: voicePickerOptions,
                    recents: Array(voicePickerOptions.prefix(3)),
                    selectedID: Binding(
                        get: { draft.selectedSpeaker },
                        set: { newSpeaker in
                            draft.selectedSpeaker = newSpeaker
                            draft.selectedLanguage = TTSModel.qwenLanguage(forSpeaker: newSpeaker)
                        }
                    ),
                    tint: IOSBrandTheme.custom,
                    onDismiss: dismiss,
                    presentation: .edgeToEdge(
                        bottomSafeAreaInset: bottomSafeAreaInset,
                        height: IOSBottomSheetChrome.voicePickerHeight
                    )
                )
            )
        }
    }

    private func presentLanguagePicker() {
        appModel.presentBottomPanel { bottomSafeAreaInset, dismiss in
            AnyView(
                IOSQwenLanguagePickerSheet(
                    selectedLanguage: $draft.selectedLanguage,
                    tint: IOSBrandTheme.custom,
                    onDismiss: dismiss,
                    presentation: .edgeToEdge(
                        bottomSafeAreaInset: bottomSafeAreaInset,
                        height: IOSBottomSheetChrome.voicePickerHeight
                    )
                )
            )
        }
    }

    private func presentDeliveryPicker() {
        guard supportsDeliveryControl else { return }
        appModel.presentBottomPanel { bottomSafeAreaInset, dismiss in
            AnyView(
                IOSDeliveryPickerSheet(
                    selectedPresetID: Binding(
                        get: { draft.delivery.selectedPresetID },
                        set: { newID in
                            draft.delivery.mode = .preset
                            draft.delivery.selectedPresetID = newID
                        }
                    ),
                    intensity: $draft.delivery.selectedIntensity,
                    tint: IOSBrandTheme.custom,
                    onUseCustomTone: { draft.delivery.mode = .custom },
                    onDismiss: dismiss,
                    presentation: .edgeToEdge(
                        bottomSafeAreaInset: bottomSafeAreaInset,
                        height: IOSBottomSheetChrome.deliveryPickerHeight
                    )
                )
            )
        }
    }

    private var voicePickerOptions: [IOSVoicePickerOption] {
        TTSContract.allSpeakerDescriptors.map { spec in
            IOSVoicePickerOption(
                id: spec.id,
                name: spec.displayName,
                subtitle: spec.shortDescription ?? spec.nativeLanguage,
                languageTag: IOSVoicePickerLanguage.tag(for: spec.nativeLanguage)
            )
        }
    }

    private func publishPrimaryAction() {
        if isGenerationActive {
            primaryAction = IOSGeneratePrimaryActionDescriptor(
                title: "Cancel",
                systemImage: "stop.fill",
                tint: .red,
                isRunning: false,
                isEnabled: true,
                accessibilityIdentifier: "textInput_cancelButton",
                action: cancelGeneration
            )
            return
        }
        primaryAction = IOSGeneratePrimaryActionDescriptor(
            title: "Create",
            systemImage: IOSGenerationSection.custom.primaryActionSystemImage,
            tint: IOSGenerationSection.custom.primaryActionTint,
            isRunning: isGenerationActive,
            isEnabled: canGenerateInCurrentRuntime,
            accessibilityIdentifier: "textInput_generateButton",
            action: generate
        )
    }

    private func generate() {
        guard !scriptLimitState.trimmedIsEmpty, ttsEngine.isReady, !ttsEngine.hasActiveGeneration else { return }
        guard !scriptLimitState.isOverLimit else {
            coordinator.fail(scriptLimitState.warningMessage)
            return
        }
        guard let model = activeModel else { return }
        guard isModelAvailable else {
            coordinator.fail("Install \(model.name) in Settings to generate audio.")
            return
        }

        coordinator.start()

        coordinator.generationTask = Task {
            defer {
                Task { @MainActor in
                    if coordinator.isGenerating {
                        coordinator.finish()
                    }
                }
            }
            let outputPath = makeOutputPath(subfolder: model.outputSubfolder, text: promptText)
            do {
                let result = try await ttsEngine.generate(
                    GenerationRequest(
                        mode: .custom,
                        modelID: model.id,
                        text: promptText,
                        outputPath: outputPath,
                        shouldStream: true,
                        streamingInterval: GenerationSemantics.appStreamingInterval,
                        languageHint: draft.selectedLanguage.rawValue,
                        payload: .custom(
                            speakerID: draft.selectedSpeaker,
                            deliveryStyle: model.supportsInstructionControl
                                ? draft.resolvedDeliveryInstruction
                                : nil
                        )
                    )
                )
                let generation = Generation(
                    text: promptText,
                    mode: model.mode.rawValue,
                    modelTier: model.tier,
                    voice: draft.selectedSpeaker,
                    emotion: model.supportsInstructionControl ? draft.resolvedDeliveryInstruction : nil,
                    speed: nil,
                    audioPath: result.audioPath,
                    duration: result.durationSeconds,
                    createdAt: Date()
                )
                GenerationPersistence.persist(
                    generation,
                    caller: "IOSCustomVoiceView"
                )
                await MainActor.run {
                    coordinator.complete(
                        IOSStudioInlinePlayerItem(
                            audioURL: URL(fileURLWithPath: result.audioPath),
                            voiceName: speakerDisplayName,
                            modeLabel: "Custom",
                            mode: .custom,
                            transcript: promptText,
                            waveformSeed: IOSStableVisualHash.int(result.audioPath),
                            autoplay: AudioService.shouldAutoPlay
                        )
                    )
                }
                IOSHaptics.success()
            } catch is CancellationError {
                audioPlayer.abortLivePreviewIfNeeded()
            coordinator.errorMessage = nil
            try? FileManager.default.removeItem(at: url)
        } catch {
                audioPlayer.abortLivePreviewIfNeeded()
                await MainActor.run { coordinator.fail(error.localizedDescription) }
                IOSHaptics.warning()
            }
        }
    }

    private func cancelGeneration() {
        coordinator.generationTask?.cancel()
        Task {
            try? await ttsEngine.cancelActiveGeneration()
            await MainActor.run {
                audioPlayer.abortLivePreviewIfNeeded()
                coordinator.finish()
            }
        }
    }
}

struct IOSVoiceDesignView: View {
    @EnvironmentObject private var ttsEngine: TTSEngineStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var modelManager: ModelManagerViewModel
    @EnvironmentObject private var savedVoicesViewModel: SavedVoicesViewModel
    @Environment(AppModel.self) private var appModel
    @Environment(\.presentIOSPlayerSheet) private var presentPlayerSheet

    let isActive: Bool
    @Binding var selectedTab: IOSAppTab
    @Binding var draft: VoiceDesignDraft
    @Binding var primaryAction: IOSGeneratePrimaryActionDescriptor
    @State private var isScriptFocused = false
    @State private var saveSheetAudioPath: String?
    @State private var isSaveSheetPresented = false
    @State private var saveSheetSuggestedName = ""
    @State private var saveSheetTranscript = ""
    @State private var saveError: String?
    /// Voice that was just enrolled but has quality warnings; user is
    /// being asked whether to keep or discard. Mirrors the macOS
    /// SavedVoiceSheet flow.
    @State private var pendingVoiceForReview: PreparedVoice?

    // Generation lifecycle moved to AppModel.designCoordinator (Phase 3b).
    private var coordinator: StudioGenerationCoordinator { appModel.designCoordinator }
    private var isGenerating: Bool { coordinator.isGenerating }
    private var errorMessage: String? { coordinator.errorMessage }
    private var lastCompletedOutput: IOSStudioInlinePlayerItem? { coordinator.lastCompletedOutput }

    private var studioGenState: IOSStudioGenState {
        if coordinator.isGenerating { return .generating }
        if let output = coordinator.lastCompletedOutput { return .complete(output) }
        return .idle
    }

    private func expandInlinePlayer() {
        guard let output = coordinator.lastCompletedOutput else { return }
        presentPlayerSheet(output.playerSheetItem)
    }

    private var deliveryChipLabel: String {
        let preset = draft.delivery.selectedPresetLabel
        if draft.delivery.mode == .custom {
            let trimmed = draft.delivery.customText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Custom delivery" : trimmed
        }
        if draft.delivery.supportsIntensity {
            return "\(preset) · \(draft.delivery.selectedIntensity.label)"
        }
        return preset
    }

    private var briefChipLabel: String {
        let trimmed = draft.voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Describe the voice" : trimmed
    }

    private var activeModel: TTSModel? {
        TTSModel.model(for: .design)
    }

    private var allowsExecution: Bool {
        ttsEngine.supportsMode(.design)
    }

    private var isModelAvailable: Bool {
        guard let activeModel else { return false }
        return modelManager.isAvailable(activeModel)
    }

    private var promptText: String {
        IOSGenerationTextLimitPolicy.clamped(draft.text, mode: .design)
    }

    private var promptTextBinding: Binding<String> {
        Binding(
            get: { promptText },
            set: { draft.text = IOSGenerationTextLimitPolicy.clamped($0, mode: .design) }
        )
    }

    private var scriptLimitState: IOSGenerationTextLimitPolicy.State {
        IOSGenerationTextLimitPolicy.state(for: promptText, mode: .design)
    }

    private var canGenerate: Bool {
        allowsExecution
            && ttsEngine.isReady
            && isModelAvailable
            && !draft.voiceDescription.isEmpty
            && !scriptLimitState.trimmedIsEmpty
            && !scriptLimitState.isOverLimit
            && !ttsEngine.hasActiveGeneration
    }

    private var canGenerateInCurrentRuntime: Bool {
        canGenerate
    }

    private var chromeOpacity: Double {
        isGenerationActive ? 0.76 : 1
    }

    private var setupMessage: String? {
        if !isModelAvailable, let activeModel {
            return "Install \(activeModel.name) in Settings."
        }
        return nil
    }

    private var promptHelper: String? {
        if !isScriptFocused && promptText.isEmpty {
            return nil
        }
        return scriptLimitState.helperMessage
    }

    private var canSaveVoice: Bool {
        ttsEngine.supportsSavedVoiceMutation && saveSheetAudioPath != nil
    }

    private var primaryActionToken: String {
        "\(isGenerationActive)-\(canGenerateInCurrentRuntime)"
    }

    private var isGenerationActive: Bool {
        isGenerating || ttsEngine.hasActiveGeneration
    }

    var body: some View {
        pageContent
            .accessibilityIdentifier("screen_voiceDesign")
            .task(id: primaryActionToken) {
                guard isActive else { return }
                publishPrimaryAction()
            }
            .onChange(of: isActive) { _, active in
                guard active else { return }
                publishPrimaryAction()
            }
            .sheet(isPresented: Binding(
                get: { isSaveSheetPresented },
                set: { isPresented in
                    isSaveSheetPresented = isPresented
                    if !isPresented {
                        saveSheetSuggestedName = ""
                        saveSheetTranscript = ""
                        saveError = nil
                    }
                }
            )) {
                if let saveSheetAudioPath {
                    IOSSaveVoiceSheet(
                        title: "Save Generated Voice",
                        suggestedName: $saveSheetSuggestedName,
                        transcript: $saveSheetTranscript,
                        errorMessage: saveError,
                        onCancel: {
                            isSaveSheetPresented = false
                            saveSheetSuggestedName = ""
                            saveSheetTranscript = ""
                            saveError = nil
                        },
                        onSave: {
                            Task {
                                do {
                                    let voice = try await ttsEngine.enrollPreparedVoice(
                                        name: saveSheetSuggestedName,
                                        audioPath: saveSheetAudioPath,
                                        transcript: saveSheetTranscript.isEmpty ? nil : saveSheetTranscript
                                    )
                                    await MainActor.run {
                                        if voice.qualityWarnings.isEmpty {
                                            savedVoicesViewModel.insertOrReplace(voice)
                                            isSaveSheetPresented = false
                                            saveSheetSuggestedName = ""
                                            saveSheetTranscript = ""
                                            saveError = nil
                                        } else {
                                            // Soft warning: voice is on disk
                                            // but pending user confirmation.
                                            pendingVoiceForReview = voice
                                        }
                                    }
                                    if voice.qualityWarnings.isEmpty {
                                        await savedVoicesViewModel.refresh(using: ttsEngine)
                                    }
                                } catch {
                                    await MainActor.run {
                                        saveError = error.localizedDescription
                                    }
                                }
                            }
                        }
                    )
                }
            }
            .alert(
                "Reference outside recommended range",
                isPresented: Binding(
                    get: { pendingVoiceForReview != nil },
                    set: { if !$0 { pendingVoiceForReview = nil } }
                ),
                presenting: pendingVoiceForReview
            ) { voice in
                // Hard-block tier (>60 s) hides the "Keep voice" button
                // so the user has to discard or cancel; soft-warn tier
                // keeps all three buttons.
                if !PreparedVoiceQualityWarning.isHardBlocking(voice.qualityWarnings) {
                    Button("Keep voice") {
                        pendingVoiceForReview = nil
                        savedVoicesViewModel.insertOrReplace(voice)
                        isSaveSheetPresented = false
                        saveSheetSuggestedName = ""
                        saveSheetTranscript = ""
                        saveError = nil
                        Task { await savedVoicesViewModel.refresh(using: ttsEngine) }
                    }
                    .accessibilityIdentifier("voicesEnroll_keepDespiteWarning")
                }
                Button("Discard and re-record", role: .destructive) {
                    let voiceID = voice.id
                    pendingVoiceForReview = nil
                    Task {
                        try? await ttsEngine.deletePreparedVoice(id: voiceID)
                    }
                }
                .accessibilityIdentifier("voicesEnroll_discardOnWarning")
                Button("Cancel", role: .cancel) {
                    pendingVoiceForReview = nil
                }
                .accessibilityIdentifier("voicesEnroll_cancelOnWarning")
            } message: { voice in
                Text(PreparedVoiceQualityWarning.summary(for: voice.qualityWarnings))
            }
    }

    @ViewBuilder
    private var pageContent: some View {
        IOSStudioCanvas(
            mode: .design,
            script: promptTextBinding,
            placeholder: "Type the lines you want this designed voice to say.",
            modeMetaLabel: "Designed voice",
            charLimit: scriptLimitState.limit,
            tint: IOSBrandTheme.design,
            genState: studioGenState,
            errorMessage: coordinator.errorMessage,
            canGenerate: canGenerateInCurrentRuntime,
            modelInstalled: isModelAvailable,
            modelDisplayName: activeModel?.name ?? "Voice Design model",
            setupChips: { designModeChips },
            onGenerate: generate,
            onCancel: cancelGeneration,
            onInstallModel: { selectedTab = .settings },
            onPlayerDismiss: { coordinator.dismissInlinePlayer() },
            onPlayerExpand: expandInlinePlayer
        )
        .opacity(chromeOpacity)
        .iosAppAnimation(IOSSelectionMotion.modeCrossfade, value: isGenerationActive)
    }

    @ViewBuilder
    private var designModeChips: some View {
        IOSStudioSetupChip(
            eyebrow: "Voice brief",
            value: briefChipLabel,
            leadingSymbol: "wand.and.stars",
            tint: IOSBrandTheme.design,
            isPlaceholder: draft.voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            action: presentBriefEditor
        )
        IOSStudioSetupChip(
            eyebrow: "Delivery",
            value: deliveryChipLabel,
            leadingSymbol: "waveform",
            tint: IOSEmotionPresetPalette.dotColor(forID: draft.delivery.selectedPresetID),
            action: presentDesignDeliveryPicker
        )
        IOSStudioSetupChip(
            eyebrow: "Language",
            value: draft.selectedLanguage.displayName,
            leadingSymbol: "globe",
            tint: IOSBrandTheme.design,
            action: presentDesignLanguagePicker
        )
    }

    private func presentBriefEditor() {
        appModel.presentBottomPanel { bottomSafeAreaInset, dismiss in
            AnyView(
                IOSVoiceDesignBriefSheet(
                    voiceDescription: $draft.voiceDescription,
                    tint: IOSBrandTheme.design,
                    presentation: .edgeToEdge(
                        bottomSafeAreaInset: bottomSafeAreaInset,
                        height: IOSBottomSheetChrome.voiceBriefHeight
                    ),
                    onDismiss: dismiss
                )
            )
        }
    }

    private func presentDesignLanguagePicker() {
        appModel.presentBottomPanel { bottomSafeAreaInset, dismiss in
            AnyView(
                IOSQwenLanguagePickerSheet(
                    selectedLanguage: $draft.selectedLanguage,
                    tint: IOSBrandTheme.design,
                    onDismiss: dismiss,
                    presentation: .edgeToEdge(
                        bottomSafeAreaInset: bottomSafeAreaInset,
                        height: IOSBottomSheetChrome.voicePickerHeight
                    )
                )
            )
        }
    }

    private func presentDesignDeliveryPicker() {
        appModel.presentBottomPanel { bottomSafeAreaInset, dismiss in
            AnyView(
                IOSDeliveryPickerSheet(
                    selectedPresetID: Binding(
                        get: { draft.delivery.selectedPresetID },
                        set: { newID in
                            draft.delivery.mode = .preset
                            draft.delivery.selectedPresetID = newID
                        }
                    ),
                    intensity: $draft.delivery.selectedIntensity,
                    tint: IOSBrandTheme.design,
                    onUseCustomTone: { draft.delivery.mode = .custom },
                    onDismiss: dismiss,
                    presentation: .edgeToEdge(
                        bottomSafeAreaInset: bottomSafeAreaInset,
                        height: IOSBottomSheetChrome.deliveryPickerHeight
                    )
                )
            )
        }
    }

    private func publishPrimaryAction() {
        if isGenerationActive {
            primaryAction = IOSGeneratePrimaryActionDescriptor(
                title: "Cancel",
                systemImage: "stop.fill",
                tint: .red,
                isRunning: false,
                isEnabled: true,
                accessibilityIdentifier: "textInput_cancelButton",
                action: cancelGeneration
            )
            return
        }
        primaryAction = IOSGeneratePrimaryActionDescriptor(
            title: "Create",
            systemImage: IOSGenerationSection.design.primaryActionSystemImage,
            tint: IOSGenerationSection.design.primaryActionTint,
            isRunning: isGenerationActive,
            isEnabled: canGenerateInCurrentRuntime,
            accessibilityIdentifier: "textInput_generateButton",
            action: generate
        )
    }

    private var suggestedSavedVoiceName: String {
        let clipped = draft.voiceDescription
            .split(separator: " ")
            .prefix(3)
            .joined(separator: " ")
        return clipped.isEmpty ? "Designed Voice" : clipped
    }

    private func generate() {
        guard let model = activeModel else { return }
        guard canGenerate else {
            if !isModelAvailable {
                coordinator.fail("Install \(model.name) in Settings to generate audio.")
            } else if scriptLimitState.isOverLimit {
                coordinator.fail(scriptLimitState.warningMessage)
            }
            return
        }

        coordinator.start()

        coordinator.generationTask = Task {
            defer {
                Task { @MainActor in
                    if coordinator.isGenerating {
                        coordinator.finish()
                    }
                }
            }
            let outputPath = makeOutputPath(subfolder: model.outputSubfolder, text: promptText)
            do {
                let result = try await ttsEngine.generate(
                    GenerationRequest(
                        mode: .design,
                        modelID: model.id,
                        text: promptText,
                        outputPath: outputPath,
                        shouldStream: true,
                        streamingInterval: GenerationSemantics.appStreamingInterval,
                        languageHint: draft.selectedLanguage.rawValue,
                        payload: .design(
                            voiceDescription: draft.voiceDescription,
                            deliveryStyle: draft.resolvedDeliveryInstruction
                        )
                    )
                )
                let generation = Generation(
                    text: promptText,
                    mode: model.mode.rawValue,
                    modelTier: model.tier,
                    voice: draft.voiceDescription,
                    emotion: draft.resolvedDeliveryInstruction,
                    speed: nil,
                    audioPath: result.audioPath,
                    duration: result.durationSeconds,
                    createdAt: Date()
                )
                GenerationPersistence.persist(
                    generation,
                    caller: "IOSVoiceDesignView"
                )
                saveSheetAudioPath = result.audioPath
                await MainActor.run {
                    coordinator.complete(
                        IOSStudioInlinePlayerItem(
                            audioURL: URL(fileURLWithPath: result.audioPath),
                            voiceName: briefChipLabel,
                            modeLabel: "Design",
                            mode: .design,
                            transcript: promptText,
                            waveformSeed: IOSStableVisualHash.int(result.audioPath),
                            autoplay: AudioService.shouldAutoPlay
                        )
                    )
                }
                IOSHaptics.success()
            } catch is CancellationError {
                audioPlayer.abortLivePreviewIfNeeded()
                await MainActor.run { coordinator.errorMessage = nil }
            } catch {
                audioPlayer.abortLivePreviewIfNeeded()
                await MainActor.run { coordinator.fail(error.localizedDescription) }
                IOSHaptics.warning()
            }
        }
    }

    private func cancelGeneration() {
        coordinator.generationTask?.cancel()
        Task {
            try? await ttsEngine.cancelActiveGeneration()
            await MainActor.run {
                audioPlayer.abortLivePreviewIfNeeded()
                coordinator.finish()
            }
        }
    }
}

struct IOSVoiceCloningView: View {
    @EnvironmentObject private var ttsEngine: TTSEngineStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var modelManager: ModelManagerViewModel
    @EnvironmentObject private var savedVoicesViewModel: SavedVoicesViewModel
    @Environment(AppModel.self) private var appModel
    @Environment(\.presentIOSPlayerSheet) private var presentPlayerSheet

    let isActive: Bool
    @Binding var selectedTab: IOSAppTab
    @Binding var draft: VoiceCloningDraft
    @Binding var primaryAction: IOSGeneratePrimaryActionDescriptor
    @Binding var pendingSavedVoiceHandoff: PendingVoiceCloningHandoff?

    @State private var transcriptLoadError: String?
    @State private var hydratedSavedVoiceID: String?
    @State private var isImporterPresented = false
    @State private var isTranscriptExpanded = false
    @State private var isScriptFocused = false
    @State private var isBatchSheetPresented = false
    @State private var isRecorderPresented = false

    // Generation lifecycle moved to AppModel.cloneCoordinator (Phase 3b).
    private var coordinator: StudioGenerationCoordinator { appModel.cloneCoordinator }
    private var isGenerating: Bool { coordinator.isGenerating }
    private var errorMessage: String? { coordinator.errorMessage }
    private var lastCompletedOutput: IOSStudioInlinePlayerItem? { coordinator.lastCompletedOutput }

    private var studioGenState: IOSStudioGenState {
        if coordinator.isGenerating { return .generating }
        if let output = coordinator.lastCompletedOutput { return .complete(output) }
        return .idle
    }

    private func expandInlinePlayer() {
        guard let output = coordinator.lastCompletedOutput else { return }
        presentPlayerSheet(output.playerSheetItem)
    }

    private var referenceChipLabel: String {
        if let voice = selectedVoice { return voice.name }
        if draft.referenceAudioPath != nil { return "Imported clip" }
        return "Choose reference"
    }

    private var cloneModel: TTSModel? {
        TTSModel.model(for: .clone)
    }

    private var isModelAvailable: Bool {
        guard let cloneModel else { return false }
        return modelManager.isAvailable(cloneModel)
    }

    private var savedVoices: [Voice] {
        savedVoicesViewModel.voices
    }

    private var selectedVoice: Voice? {
        guard let selectedSavedVoiceID = draft.selectedSavedVoiceID else { return nil }
        return savedVoices.first(where: { $0.id == selectedSavedVoiceID })
    }

    private var clonePrimingRequestKey: String? {
        guard let model = cloneModel,
              ttsEngine.isReady,
              isModelAvailable,
              let referenceAudioPath = draft.referenceAudioPath else {
            return nil
        }
        if let selectedSavedVoiceID = draft.selectedSavedVoiceID,
           hydratedSavedVoiceID != selectedSavedVoiceID,
           transcriptLoadError == nil {
            return nil
        }
        return GenerationSemantics.cloneReferenceIdentityKey(
            modelID: model.id,
            refAudio: referenceAudioPath,
            refText: draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript
        )
    }

    private var clonePrimingTaskID: String {
        "\(isActive)-\(clonePrimingRequestKey ?? "clone-priming-idle")"
    }

    private var promptText: String {
        IOSGenerationTextLimitPolicy.clamped(draft.text, mode: .clone)
    }

    private var promptTextBinding: Binding<String> {
        Binding(
            get: { promptText },
            set: { draft.text = IOSGenerationTextLimitPolicy.clamped($0, mode: .clone) }
        )
    }

    private var scriptLimitState: IOSGenerationTextLimitPolicy.State {
        IOSGenerationTextLimitPolicy.state(for: promptText, mode: .clone)
    }

    private var allowsExecution: Bool {
        ttsEngine.supportsMode(.clone)
    }

    private var cloneContextStatus: VoiceCloningContextStatus? {
        VoiceCloningContextStatus(
            CloneReferenceContextResolver.resolve(
                hasReference: draft.referenceAudioPath != nil,
                selectedSavedVoiceID: draft.selectedSavedVoiceID,
                hydratedSavedVoiceID: hydratedSavedVoiceID,
                transcriptLoadError: transcriptLoadError,
                expectedPreparationKey: clonePrimingRequestKey,
                preparationState: ttsEngine.clonePreparationState
            )
        )
    }

    private var canGenerate: Bool {
        ttsEngine.isReady
            && allowsExecution
            && isModelAvailable
            && draft.referenceAudioPath != nil
            && !scriptLimitState.trimmedIsEmpty
            && !scriptLimitState.isOverLimit
            && !ttsEngine.hasActiveGeneration
    }

    private var setupMessage: String? {
        if !isModelAvailable, let cloneModel {
            return "Install \(cloneModel.name) in Settings."
        }
        if draft.referenceAudioPath == nil {
            return "Choose a saved voice or import a recording. Imported clips are session-only. Tap Save to Saved Voices to keep one for next time."
        }
        if let cloneContextStatus {
            switch cloneContextStatus {
            case .waitingForHydration:
                return "Loading the selected voice."
            case .preparing:
                return "Preparing the reference audio."
            case .primed:
                return nil
            case .fallback(let message):
                return message
            }
        }
        return nil
    }

    private var promptHelper: String? {
        if !isScriptFocused && promptText.isEmpty {
            return nil
        }
        return scriptLimitState.helperMessage
    }

    private var canGenerateInCurrentRuntime: Bool {
        canGenerate
    }

    private var primaryActionToken: String {
        "\(isGenerationActive)-\(canGenerateInCurrentRuntime)"
    }

    private var isGenerationActive: Bool {
        isGenerating || ttsEngine.hasActiveGeneration
    }

    var body: some View {
        pageContent
            .accessibilityIdentifier("screen_voiceCloning")
            .task(id: primaryActionToken) {
                guard isActive else { return }
                publishPrimaryAction()
            }
            .task {
                guard isActive else { return }
                if ttsEngine.isReady {
                    await savedVoicesViewModel.ensureLoaded(using: ttsEngine)
                }
                consumePendingSavedVoiceHandoffIfNeeded()
                syncSavedVoiceSelectionState()
            }
            .task(id: clonePrimingTaskID) {
                guard isActive else {
                    await ttsEngine.cancelClonePreparationIfNeeded()
                    return
                }
                await syncCloneReferencePriming()
            }
            .onChange(of: isActive) { _, active in
                guard active else { return }
                publishPrimaryAction()
                consumePendingSavedVoiceHandoffIfNeeded()
                syncSavedVoiceSelectionState()
            }
            .onChange(of: pendingSavedVoiceHandoff) { _, _ in
                guard isActive else { return }
                consumePendingSavedVoiceHandoffIfNeeded()
            }
            .onChange(of: savedVoicesViewModel.voices) { _, _ in
                guard isActive else { return }
                syncSavedVoiceSelectionState()
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.audio, .wav, .mp3, .aiff, .mpeg4Audio]
            ) { result in
                switch result {
                case .success(let url):
                    applyImportedReferenceAudio(from: url)
                case .failure(let error):
                    coordinator.fail(error.localizedDescription)
                }
            }
            .sheet(isPresented: $isBatchSheetPresented) {
                IOSBatchGenerationSheet(
                    mode: .clone,
                    tint: IOSGenerationSection.clone.primaryActionTint,
                    requestBuilder: { line in
                        guard let model = cloneModel,
                              let refPath = draft.referenceAudioPath
                        else { return nil }
                        let outputPath = makeOutputPath(subfolder: model.outputSubfolder, text: line)
                        let request = GenerationRequest(
                            mode: .clone,
                            modelID: model.id,
                            text: line,
                            outputPath: outputPath,
                            shouldStream: true,
                            streamingInterval: GenerationSemantics.appStreamingInterval,
                            languageHint: draft.selectedLanguage.rawValue,
                            payload: .clone(
                                reference: CloneReference(
                                    audioPath: refPath,
                                    transcript: draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript,
                                    preparedVoiceID: draft.selectedSavedVoiceID
                                )
                            )
                        )
                        return (request, model)
                    }
                )
            }
            .fullScreenCover(isPresented: $isRecorderPresented) {
                IOSRecordingOverlay(
                    onComplete: { url in
                        isRecorderPresented = false
                        applyRecordedReferenceAudio(at: url)
                    },
                    onCancel: { isRecorderPresented = false }
                )
            }
    }

    /// Track H landing point for freshly-recorded reference clips. Route
    /// through `ttsEngine.importReferenceAudio(from:)` so recordings are
    /// materialized under `AppPaths.importedReferenceAudioDir` instead of
    /// staying in `tmp/`.
    private func applyRecordedReferenceAudio(at url: URL) {
        do {
            let imported = try ttsEngine.importReferenceAudio(from: url)
            draft.selectedSavedVoiceID = nil
            hydratedSavedVoiceID = nil
            transcriptLoadError = nil
            draft.referenceAudioPath = imported.materializedPath
            draft.referenceTranscript = ""
            coordinator.errorMessage = nil
            if let transcriptSidecarURL = imported.transcriptSidecarURL,
               let transcript = try? String(contentsOf: transcriptSidecarURL, encoding: .utf8) {
                draft.referenceTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            coordinator.fail("Couldn't import the reference recording: \(error.localizedDescription)")
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            IOSStudioCanvas(
                mode: .clone,
                script: promptTextBinding,
                placeholder: "Type the new text. The reference voice will speak it.",
                modeMetaLabel: "Voice cloning",
                charLimit: scriptLimitState.limit,
                tint: IOSBrandTheme.clone,
                genState: studioGenState,
                errorMessage: coordinator.errorMessage,
                canGenerate: canGenerateInCurrentRuntime,
                modelInstalled: isModelAvailable,
                modelDisplayName: cloneModel?.name ?? "Voice Cloning model",
                setupChips: { cloneModeChips },
                onGenerate: generate,
                onCancel: cancelGeneration,
                onInstallModel: { selectedTab = .settings },
                onPlayerDismiss: { coordinator.dismissInlinePlayer() },
                onPlayerExpand: expandInlinePlayer
            )

            if isBatchTriggerEnabled {
                Button {
                    IOSHaptics.selection()
                    isBatchSheetPresented = true
                } label: {
                    Label("Generate batch…", systemImage: "list.bullet.indent")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(IOSGenerationSection.clone.primaryActionTint)
                .accessibilityIdentifier("textInput_generateBatchButton")
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var cloneModeChips: some View {
        IOSStudioSetupChip(
            eyebrow: draft.referenceAudioPath == nil ? "Reference" : "Voice",
            value: referenceChipLabel,
            leadingSymbol: draft.referenceAudioPath == nil ? "mic.fill" : "person.wave.2.fill",
            tint: IOSBrandTheme.clone,
            isPlaceholder: draft.referenceAudioPath == nil,
            action: presentReferencePicker
        )
        IOSStudioSetupChip(
            eyebrow: "Language",
            value: draft.selectedLanguage.displayName,
            leadingSymbol: "globe",
            tint: IOSBrandTheme.clone,
            action: presentCloneLanguagePicker
        )
    }

    private func presentReferencePicker() {
        appModel.presentBottomPanel { bottomSafeAreaInset, dismiss in
            AnyView(
                IOSReferenceClipSheet(
                    savedVoices: savedVoiceOptions,
                    selectedSavedVoiceID: Binding(
                        get: { draft.selectedSavedVoiceID },
                        set: { newValue in
                            guard let id = newValue,
                                  let voice = savedVoices.first(where: { $0.id == id })
                            else { return }
                            applySavedVoice(voice)
                            dismiss()
                        }
                    ),
                    onImportFromFiles: {
                        dismiss()
                        isImporterPresented = true
                    },
                    onRecorded: { url in
                        applyRecordedReferenceAudio(at: url)
                        dismiss()
                    },
                    onDismiss: dismiss,
                    presentation: .edgeToEdge(
                        bottomSafeAreaInset: bottomSafeAreaInset,
                        height: IOSBottomSheetChrome.referenceClipHeight
                    )
                )
            )
        }
    }

    private func presentCloneLanguagePicker() {
        appModel.presentBottomPanel { bottomSafeAreaInset, dismiss in
            AnyView(
                IOSQwenLanguagePickerSheet(
                    selectedLanguage: $draft.selectedLanguage,
                    tint: IOSBrandTheme.clone,
                    onDismiss: dismiss,
                    presentation: .edgeToEdge(
                        bottomSafeAreaInset: bottomSafeAreaInset,
                        height: IOSBottomSheetChrome.voicePickerHeight
                    )
                )
            )
        }
    }

    private var savedVoiceOptions: [IOSVoicePickerOption] {
        savedVoices.map { voice in
            IOSVoicePickerOption(
                id: voice.id,
                name: voice.name,
                subtitle: "Cloned reference"
            )
        }
    }

    private var isBatchTriggerEnabled: Bool {
        ttsEngine.isReady
            && !ttsEngine.hasActiveGeneration
            && isModelAvailable
            && draft.referenceAudioPath != nil
    }

    private func publishPrimaryAction() {
        if isGenerationActive {
            primaryAction = IOSGeneratePrimaryActionDescriptor(
                title: "Cancel",
                systemImage: "stop.fill",
                tint: .red,
                isRunning: false,
                isEnabled: true,
                accessibilityIdentifier: "textInput_cancelButton",
                action: cancelGeneration
            )
            return
        }
        primaryAction = IOSGeneratePrimaryActionDescriptor(
            title: "Create",
            systemImage: IOSGenerationSection.clone.primaryActionSystemImage,
            tint: IOSGenerationSection.clone.primaryActionTint,
            isRunning: isGenerationActive,
            isEnabled: canGenerateInCurrentRuntime,
            accessibilityIdentifier: "textInput_generateButton",
            action: generate
        )
    }

    private func consumePendingSavedVoiceHandoffIfNeeded() {
        guard let pendingSavedVoiceHandoff else { return }
        draft.applySavedVoiceSelection(
            id: pendingSavedVoiceHandoff.savedVoiceID,
            wavPath: pendingSavedVoiceHandoff.wavPath,
            transcript: pendingSavedVoiceHandoff.transcript
        )
        transcriptLoadError = pendingSavedVoiceHandoff.transcriptLoadError
        hydratedSavedVoiceID = pendingSavedVoiceHandoff.savedVoiceID
        self.pendingSavedVoiceHandoff = nil
    }

    private func generate() {
        guard !scriptLimitState.trimmedIsEmpty, ttsEngine.isReady, !ttsEngine.hasActiveGeneration else { return }
        guard !scriptLimitState.isOverLimit else {
            coordinator.fail(scriptLimitState.warningMessage)
            return
        }
        guard let model = cloneModel else { return }
        guard isModelAvailable else {
            coordinator.fail("Install \(model.name) in Settings to generate audio.")
            return
        }

        coordinator.start()

        coordinator.generationTask = Task {
            defer {
                Task { @MainActor in
                    if coordinator.isGenerating {
                        coordinator.finish()
                    }
                }
            }
            do {
                ensureSelectedSavedVoiceHydratedIfNeeded()
                guard let refPath = draft.referenceAudioPath else {
                    throw NSError(
                        domain: "QVoice.AppGeneration",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Select a reference audio file before generating."]
                    )
                }
                if ttsEngine.clonePreparationState.phase != .failed || ttsEngine.clonePreparationState.identityKey != clonePrimingRequestKey {
                    try? await ttsEngine.ensureCloneReferencePrimed(
                        modelID: model.id,
                        reference: CloneReference(
                            audioPath: refPath,
                            transcript: draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript,
                            preparedVoiceID: draft.selectedSavedVoiceID
                        )
                    )
                }

                let outputPath = makeOutputPath(subfolder: model.outputSubfolder, text: promptText)
                let result = try await ttsEngine.generate(
                    GenerationRequest(
                        mode: .clone,
                        modelID: model.id,
                        text: promptText,
                        outputPath: outputPath,
                        shouldStream: true,
                        streamingInterval: GenerationSemantics.appStreamingInterval,
                        languageHint: draft.selectedLanguage.rawValue,
                        payload: .clone(
                            reference: CloneReference(
                                audioPath: refPath,
                                transcript: draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript,
                                preparedVoiceID: draft.selectedSavedVoiceID
                            )
                        )
                    )
                )
                let voiceName = selectedVoice?.name ?? URL(fileURLWithPath: refPath).deletingPathExtension().lastPathComponent
                let generation = Generation(
                    text: promptText,
                    mode: model.mode.rawValue,
                    modelTier: model.tier,
                    voice: voiceName,
                    emotion: nil,
                    speed: nil,
                    audioPath: result.audioPath,
                    duration: result.durationSeconds,
                    createdAt: Date()
                )
                GenerationPersistence.persist(
                    generation,
                    caller: "IOSVoiceCloningView"
                )
                await MainActor.run {
                    coordinator.complete(
                        IOSStudioInlinePlayerItem(
                            audioURL: URL(fileURLWithPath: result.audioPath),
                            voiceName: voiceName,
                            modeLabel: "Clone",
                            mode: .clone,
                            transcript: promptText,
                            waveformSeed: IOSStableVisualHash.int(result.audioPath),
                            autoplay: AudioService.shouldAutoPlay
                        )
                    )
                }
                IOSHaptics.success()
            } catch is CancellationError {
                audioPlayer.abortLivePreviewIfNeeded()
                await MainActor.run { coordinator.errorMessage = nil }
            } catch {
                audioPlayer.abortLivePreviewIfNeeded()
                await MainActor.run { coordinator.fail(error.localizedDescription) }
                IOSHaptics.warning()
            }
        }
    }

    private func cancelGeneration() {
        coordinator.generationTask?.cancel()
        Task {
            try? await ttsEngine.cancelActiveGeneration()
            await MainActor.run {
                audioPlayer.abortLivePreviewIfNeeded()
                coordinator.finish()
            }
        }
    }

    private func syncCloneReferencePriming() async {
        guard !isGenerationActive else { return }
        guard allowsExecution else {
            await ttsEngine.cancelClonePreparationIfNeeded()
            return
        }
        guard let model = cloneModel,
              let refPath = draft.referenceAudioPath,
              clonePrimingRequestKey != nil else {
            await ttsEngine.cancelClonePreparationIfNeeded()
            return
        }

        if let selectedSavedVoiceID = draft.selectedSavedVoiceID,
           hydratedSavedVoiceID != selectedSavedVoiceID,
           transcriptLoadError == nil {
            await ttsEngine.cancelClonePreparationIfNeeded()
            return
        }

        do {
            try await ttsEngine.ensureCloneReferencePrimed(
                modelID: model.id,
                reference: CloneReference(
                    audioPath: refPath,
                    transcript: draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript,
                    preparedVoiceID: draft.selectedSavedVoiceID
                )
            )
        } catch {
            #if DEBUG
            print("[IOSVoiceCloningView] clone priming failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func applySavedVoice(_ voice: Voice) {
        do {
            let transcript = try SavedVoiceCloneHydration.loadTranscript(for: voice)
            draft.applySavedVoice(voice, transcript: transcript)
            transcriptLoadError = nil
        } catch {
            draft.applySavedVoice(voice, transcript: "")
            transcriptLoadError = "Couldn't load the saved transcript for \"\(voice.name)\". Cloning can still use the audio."
        }
        hydratedSavedVoiceID = voice.id
    }

    private func ensureSelectedSavedVoiceHydratedIfNeeded() {
        guard let selectedVoice else { return }
        guard draft.selectedSavedVoiceID == selectedVoice.id else { return }
        guard hydratedSavedVoiceID != selectedVoice.id else { return }
        guard transcriptLoadError == nil else { return }
        applySavedVoice(selectedVoice)
    }

    private func clearReference() {
        draft.clearReference()
        transcriptLoadError = nil
        hydratedSavedVoiceID = nil
    }

    private func syncSavedVoiceSelectionState() {
        if draft.selectedSavedVoiceID != nil,
           selectedVoice == nil,
           savedVoicesViewModel.isLoading || savedVoicesViewModel.loadError != nil {
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

    private func applyImportedReferenceAudio(from url: URL) {
        // The `url` argument must originate from a `fileImporter` callback
        // or another platform picker that hands out a security-scoped URL.
        // `LocalDocumentIO.importReferenceAudio` wraps the read with
        // `startAccessingSecurityScopedResource()` / `stopAccessing…`, so
        // the scope must travel with the URL through the engine indirection
        // (`ttsEngine.importReferenceAudio(from: url)` passes the URL by
        // value, preserving its scope context). Do NOT reconstruct the URL
        // from a `path` String before calling this — the rebuilt URL has
        // no scope and the import will fail on iCloud / third-party
        // providers.
        do {
            let imported = try ttsEngine.importReferenceAudio(from: url)
            draft.referenceAudioPath = imported.materializedPath
            draft.selectedSavedVoiceID = nil
            transcriptLoadError = nil
            hydratedSavedVoiceID = nil
            coordinator.errorMessage = nil
            if let transcriptSidecarURL = imported.transcriptSidecarURL,
               let transcript = try? String(contentsOf: transcriptSidecarURL, encoding: .utf8) {
                draft.referenceTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            coordinator.fail("Couldn't import the reference audio: \(error.localizedDescription)")
        }
    }
}

private extension VoiceCloningContextStatus {
    init?(_ resolution: CloneReferenceContextResolution?) {
        guard let resolution else { return nil }
        switch resolution {
        case .waitingForHydration:
            self = .waitingForHydration
        case .preparing:
            self = .preparing
        case .primed:
            self = .primed
        case .usableWithoutPriming:
            return nil
        case .degraded(let message):
            self = .fallback(message)
        }
    }
}
