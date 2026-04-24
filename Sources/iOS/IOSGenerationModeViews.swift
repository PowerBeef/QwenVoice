import SwiftUI
import UniformTypeIdentifiers
import QwenVoiceCore

struct IOSCustomVoiceView: View {
    @EnvironmentObject private var ttsEngine: TTSEngineStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var modelManager: ModelManagerViewModel

    let isActive: Bool
    @Binding var draft: CustomVoiceDraft
    @Binding var primaryAction: IOSGeneratePrimaryActionDescriptor
    @State private var isGenerating = false
    @State private var isScriptFocused = false
    @State private var errorMessage: String?

    private var activeModel: TTSModel? {
        TTSModel.model(for: .custom)
    }

    private var isSimulatorPreview: Bool {
        IOSSimulatorPreviewPolicy.isSimulatorPreview
    }

    private var allowsExecution: Bool {
        IOSSimulatorPreviewPolicy.allowsExecution(for: .custom, declaredModes: ttsEngine.supportedModes)
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
    }

    private var chromeOpacity: Double {
        isGenerating ? 0.76 : 1
    }

    private var setupMessage: String? {
        if !isModelAvailable, !isSimulatorPreview, let activeModel {
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
        "\(isGenerating)-\(isSimulatorPreview || canGenerate)"
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
        VStack(alignment: .leading, spacing: 14) {
            IOSStudioComposerCard(
                title: "Use an existing voice",
                subtitle: "",
                promptSectionTitle: "Script",
                setupSectionTitle: "Voice",
                tint: IOSBrandTheme.custom,
                helper: promptHelper,
                text: promptTextBinding,
                placeholder: "Type the text to speak",
                isFocused: $isScriptFocused,
                accessibilityIdentifier: "textInput_textEditor",
                counterText: scriptLimitState.counterText,
                counterTone: scriptLimitState.isOverLimit ? .orange : IOSBrandTheme.custom,
                helperTone: scriptLimitState.isOverLimit ? .orange : IOSAppTheme.textSecondary,
                notice: errorMessage,
                noticeTint: .orange,
                maxCharacterCount: scriptLimitState.limit
            ) {
                EmptyView()
            } setup: {
                IOSCustomVoiceSetupCard(
                    selectedSpeaker: $draft.selectedSpeaker,
                    delivery: $draft.delivery,
                    setupMessage: setupMessage,
                    badgeText: nil,
                    badgeTone: nil,
                    modelInstallMessage: activeModel.flatMap { model in
                        guard !isModelAvailable, !isSimulatorPreview else { return nil }
                        return "Install \(model.name) in Settings."
                    }
                )
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(chromeOpacity)
        .animation(IOSSelectionMotion.modeCrossfade, value: isGenerating)
        .onChange(of: draft.text) { _, newValue in
            let clamped = IOSGenerationTextLimitPolicy.clamped(newValue, mode: .custom)
            if clamped != newValue {
                draft.text = clamped
            }
        }
    }

    private func publishPrimaryAction() {
        primaryAction = IOSGeneratePrimaryActionDescriptor(
            title: "Create",
            systemImage: IOSGenerationSection.custom.primaryActionSystemImage,
            tint: IOSGenerationSection.custom.primaryActionTint,
            isRunning: isGenerating,
            isEnabled: isSimulatorPreview || canGenerate,
            accessibilityIdentifier: "textInput_generateButton",
            action: generate
        )
    }

    private func generate() {
        if isSimulatorPreview {
            errorMessage = nil
            return
        }
        guard !scriptLimitState.trimmedIsEmpty, ttsEngine.isReady else { return }
        guard !scriptLimitState.isOverLimit else {
            errorMessage = scriptLimitState.warningMessage
            return
        }
        guard let model = activeModel else { return }
        guard isModelAvailable else {
            errorMessage = "Install \(model.name) in Settings to generate audio."
            return
        }

        isGenerating = true
        errorMessage = nil

        Task {
            let outputPath = makeOutputPath(subfolder: model.outputSubfolder, text: promptText)
            do {
                audioPlayer.prepareStreamingPreview(
                    title: String(promptText.prefix(40)),
                    shouldAutoPlay: AudioService.shouldAutoPlay
                )
                let result = try await ttsEngine.generate(
                    GenerationRequest(
                        mode: .custom,
                        modelID: model.id,
                        text: promptText,
                        outputPath: outputPath,
                        shouldStream: true,
                        streamingInterval: GenerationSemantics.appStreamingInterval,
                        payload: .custom(
                            speakerID: draft.selectedSpeaker,
                            deliveryStyle: draft.resolvedDeliveryInstruction
                        )
                    )
                )
                var generation = Generation(
                    text: promptText,
                    mode: model.mode.rawValue,
                    modelTier: model.tier,
                    voice: draft.selectedSpeaker,
                    emotion: draft.resolvedDeliveryInstruction,
                    speed: nil,
                    audioPath: result.audioPath,
                    duration: result.durationSeconds,
                    createdAt: Date()
                )
                try GenerationPersistence.persistAndAutoplay(
                    &generation,
                    result: result,
                    text: promptText,
                    audioPlayer: audioPlayer,
                    caller: "IOSCustomVoiceView"
                )
                IOSHaptics.success()
            } catch {
                if (error as? GenerationPersistence.PersistenceError) == nil {
                    audioPlayer.abortLivePreviewIfNeeded()
                }
                errorMessage = error.localizedDescription
                IOSHaptics.warning()
            }

            isGenerating = false
        }
    }
}

struct IOSVoiceDesignView: View {
    @EnvironmentObject private var ttsEngine: TTSEngineStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var modelManager: ModelManagerViewModel
    @EnvironmentObject private var savedVoicesViewModel: SavedVoicesViewModel

    let isActive: Bool
    @Binding var draft: VoiceDesignDraft
    @Binding var primaryAction: IOSGeneratePrimaryActionDescriptor
    @State private var isGenerating = false
    @State private var isScriptFocused = false
    @State private var errorMessage: String?
    @State private var saveSheetAudioPath: String?
    @State private var isSaveSheetPresented = false
    @State private var saveSheetSuggestedName = ""
    @State private var saveSheetTranscript = ""
    @State private var saveError: String?

    private var activeModel: TTSModel? {
        TTSModel.model(for: .design)
    }

    private var isSimulatorPreview: Bool {
        IOSSimulatorPreviewPolicy.isSimulatorPreview
    }

    private var allowsExecution: Bool {
        IOSSimulatorPreviewPolicy.allowsExecution(for: .design, declaredModes: ttsEngine.supportedModes)
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
    }

    private var chromeOpacity: Double {
        isGenerating ? 0.76 : 1
    }

    private var setupMessage: String? {
        if !isModelAvailable, !isSimulatorPreview, let activeModel {
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
        "\(isGenerating)-\(isSimulatorPreview || canGenerate)"
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
                                        savedVoicesViewModel.insertOrReplace(voice)
                                        isSaveSheetPresented = false
                                        saveSheetSuggestedName = ""
                                        saveSheetTranscript = ""
                                        saveError = nil
                                    }
                                    await savedVoicesViewModel.refresh(using: ttsEngine)
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
    }

    @ViewBuilder
    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            IOSStudioComposerCard(
                title: "Describe the voice you want",
                subtitle: "",
                promptSectionTitle: "Script",
                setupSectionTitle: "Voice",
                tint: IOSBrandTheme.design,
                helper: promptHelper,
                text: promptTextBinding,
                placeholder: "Type the text to speak",
                isFocused: $isScriptFocused,
                accessibilityIdentifier: "textInput_textEditor",
                counterText: scriptLimitState.counterText,
                counterTone: scriptLimitState.isOverLimit ? .orange : IOSBrandTheme.design,
                helperTone: scriptLimitState.isOverLimit ? .orange : IOSAppTheme.textSecondary,
                notice: errorMessage,
                noticeTint: .orange,
                maxCharacterCount: scriptLimitState.limit
            ) {
                if canSaveVoice {
                    IOSComposerCardAction(
                        title: "Save",
                        systemImage: "person.crop.circle.badge.plus",
                        tint: IOSBrandTheme.design,
                        accessibilityIdentifier: "voiceDesign_saveVoiceButton"
                    ) {
                        saveSheetSuggestedName = suggestedSavedVoiceName
                        saveSheetTranscript = promptText
                        isSaveSheetPresented = true
                    }
                } else {
                    EmptyView()
                }
            } setup: {
                IOSVoiceDesignSetupCard(
                    voiceDescription: $draft.voiceDescription,
                    delivery: $draft.delivery,
                    setupMessage: setupMessage,
                    badgeText: nil,
                    badgeTone: nil,
                    modelInstallMessage: activeModel.flatMap { model in
                        guard !isModelAvailable, !isSimulatorPreview else { return nil }
                        return "Install \(model.name) in Settings."
                    }
                )
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(chromeOpacity)
        .animation(IOSSelectionMotion.modeCrossfade, value: isGenerating)
        .onChange(of: draft.text) { _, newValue in
            let clamped = IOSGenerationTextLimitPolicy.clamped(newValue, mode: .design)
            if clamped != newValue {
                draft.text = clamped
            }
        }
    }

    private func publishPrimaryAction() {
        primaryAction = IOSGeneratePrimaryActionDescriptor(
            title: "Create",
            systemImage: IOSGenerationSection.design.primaryActionSystemImage,
            tint: IOSGenerationSection.design.primaryActionTint,
            isRunning: isGenerating,
            isEnabled: isSimulatorPreview || canGenerate,
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
        if isSimulatorPreview {
            errorMessage = nil
            return
        }
        guard let model = activeModel else { return }
        guard canGenerate else {
            if !isModelAvailable {
                errorMessage = "Install \(model.name) in Settings to generate audio."
            } else if scriptLimitState.isOverLimit {
                errorMessage = scriptLimitState.warningMessage
            }
            return
        }

        isGenerating = true
        errorMessage = nil

        Task {
            let outputPath = makeOutputPath(subfolder: model.outputSubfolder, text: promptText)
            do {
                audioPlayer.prepareStreamingPreview(
                    title: String(promptText.prefix(40)),
                    shouldAutoPlay: AudioService.shouldAutoPlay
                )
                let result = try await ttsEngine.generate(
                    GenerationRequest(
                        mode: .design,
                        modelID: model.id,
                        text: promptText,
                        outputPath: outputPath,
                        shouldStream: true,
                        streamingInterval: GenerationSemantics.appStreamingInterval,
                        payload: .design(
                            voiceDescription: draft.voiceDescription,
                            deliveryStyle: draft.resolvedDeliveryInstruction
                        )
                    )
                )
                var generation = Generation(
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
                try GenerationPersistence.persistAndAutoplay(
                    &generation,
                    result: result,
                    text: promptText,
                    audioPlayer: audioPlayer,
                    caller: "IOSVoiceDesignView"
                )
                saveSheetAudioPath = result.audioPath
                IOSHaptics.success()
            } catch {
                if (error as? GenerationPersistence.PersistenceError) == nil {
                    audioPlayer.abortLivePreviewIfNeeded()
                }
                errorMessage = error.localizedDescription
                IOSHaptics.warning()
            }
            isGenerating = false
        }
    }
}

struct IOSVoiceCloningView: View {
    @EnvironmentObject private var ttsEngine: TTSEngineStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var modelManager: ModelManagerViewModel
    @EnvironmentObject private var savedVoicesViewModel: SavedVoicesViewModel

    let isActive: Bool
    @Binding var draft: VoiceCloningDraft
    @Binding var primaryAction: IOSGeneratePrimaryActionDescriptor
    @Binding var pendingSavedVoiceHandoff: PendingVoiceCloningHandoff?

    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var transcriptLoadError: String?
    @State private var hydratedSavedVoiceID: String?
    @State private var isImporterPresented = false
    @State private var isTranscriptExpanded = false
    @State private var isScriptFocused = false

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

    private var isSimulatorPreview: Bool {
        IOSSimulatorPreviewPolicy.isSimulatorPreview
    }

    private var allowsExecution: Bool {
        IOSSimulatorPreviewPolicy.allowsExecution(for: .clone, declaredModes: ttsEngine.supportedModes)
    }

    private var cloneContextStatus: VoiceCloningContextStatus? {
        guard draft.referenceAudioPath != nil else { return nil }
        if let selectedSavedVoiceID = draft.selectedSavedVoiceID,
           hydratedSavedVoiceID != selectedSavedVoiceID,
           transcriptLoadError == nil {
            return .waitingForHydration
        }
        guard let clonePrimingRequestKey else { return nil }
        if ttsEngine.clonePreparationState.identityKey == clonePrimingRequestKey {
            switch ttsEngine.clonePreparationState.phase {
            case .idle:
                break
            case .preparing:
                return .preparing
            case .primed:
                return .primed
            case .failed:
                return .fallback(
                    ttsEngine.clonePreparationState.message
                        ?? "Reference prep didn't finish. The first preview may be slower."
                )
            }
        }
        return .preparing
    }

    private var canGenerate: Bool {
        ttsEngine.isReady
            && allowsExecution
            && isModelAvailable
            && draft.referenceAudioPath != nil
            && !scriptLimitState.trimmedIsEmpty
            && !scriptLimitState.isOverLimit
    }

    private var setupMessage: String? {
        if !isModelAvailable, !isSimulatorPreview, let cloneModel {
            return "Install \(cloneModel.name) in Settings."
        }
        if draft.referenceAudioPath == nil {
            return "Choose a saved voice or import a recording."
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

    private var primaryActionToken: String {
        "\(isGenerating)-\(isSimulatorPreview || canGenerate)"
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
                    errorMessage = error.localizedDescription
                }
            }
    }

    @ViewBuilder
    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            IOSStudioComposerCard(
                title: "Use a reference recording",
                subtitle: "",
                promptSectionTitle: "Script",
                setupSectionTitle: "Reference",
                tint: IOSBrandTheme.clone,
                helper: promptHelper,
                text: promptTextBinding,
                placeholder: "Type the new text to speak",
                isFocused: $isScriptFocused,
                accessibilityIdentifier: "textInput_textEditor",
                counterText: scriptLimitState.counterText,
                counterTone: scriptLimitState.isOverLimit ? .orange : IOSBrandTheme.clone,
                helperTone: scriptLimitState.isOverLimit ? .orange : IOSAppTheme.textSecondary,
                notice: errorMessage,
                noticeTint: .orange,
                maxCharacterCount: scriptLimitState.limit
            ) {
                EmptyView()
            } setup: {
                IOSVoiceCloningReferenceCard(
                    savedVoices: savedVoices,
                    selectedSavedVoiceID: draft.selectedSavedVoiceID,
                    referenceAudioPath: draft.referenceAudioPath,
                    transcriptLoadError: transcriptLoadError,
                    setupMessage: setupMessage,
                    badgeText: nil,
                    badgeTone: nil,
                    onSelectSavedVoice: { newValue in
                        guard let newValue else {
                            clearReference()
                            return
                        }
                        guard let voice = savedVoices.first(where: { $0.id == newValue }) else { return }
                        applySavedVoice(voice)
                    },
                    onImportReference: {
                        isImporterPresented = true
                    },
                    onClearReference: clearReference,
                    referenceTranscript: $draft.referenceTranscript,
                    isTranscriptExpanded: $isTranscriptExpanded
                )
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: draft.text) { _, newValue in
            let clamped = IOSGenerationTextLimitPolicy.clamped(newValue, mode: .clone)
            if clamped != newValue {
                draft.text = clamped
            }
        }
    }

    private func publishPrimaryAction() {
        primaryAction = IOSGeneratePrimaryActionDescriptor(
            title: "Create",
            systemImage: IOSGenerationSection.clone.primaryActionSystemImage,
            tint: IOSGenerationSection.clone.primaryActionTint,
            isRunning: isGenerating,
            isEnabled: isSimulatorPreview || canGenerate,
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
        if isSimulatorPreview {
            errorMessage = nil
            return
        }
        guard !scriptLimitState.trimmedIsEmpty, ttsEngine.isReady else { return }
        guard !scriptLimitState.isOverLimit else {
            errorMessage = scriptLimitState.warningMessage
            return
        }
        guard let model = cloneModel else { return }
        guard isModelAvailable else {
            errorMessage = "Install \(model.name) in Settings to generate audio."
            return
        }

        isGenerating = true
        errorMessage = nil

        Task {
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
                audioPlayer.prepareStreamingPreview(
                    title: String(promptText.prefix(40)),
                    shouldAutoPlay: AudioService.shouldAutoPlay
                )
                let result = try await ttsEngine.generate(
                    GenerationRequest(
                        mode: .clone,
                        modelID: model.id,
                        text: promptText,
                        outputPath: outputPath,
                        shouldStream: true,
                        streamingInterval: GenerationSemantics.appStreamingInterval,
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
                var generation = Generation(
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
                try GenerationPersistence.persistAndAutoplay(
                    &generation,
                    result: result,
                    text: promptText,
                    audioPlayer: audioPlayer,
                    caller: "IOSVoiceCloningView"
                )
                IOSHaptics.success()
            } catch {
                if (error as? GenerationPersistence.PersistenceError) == nil {
                    audioPlayer.abortLivePreviewIfNeeded()
                }
                errorMessage = error.localizedDescription
                IOSHaptics.warning()
            }
            isGenerating = false
        }
    }

    private func syncCloneReferencePriming() async {
        guard !isGenerating else { return }
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
        do {
            let imported = try ttsEngine.importReferenceAudio(from: url)
            draft.referenceAudioPath = imported.materializedPath
            draft.selectedSavedVoiceID = nil
            transcriptLoadError = nil
            hydratedSavedVoiceID = nil
            errorMessage = nil
            if let transcriptSidecarURL = imported.transcriptSidecarURL,
               let transcript = try? String(contentsOf: transcriptSidecarURL, encoding: .utf8) {
                draft.referenceTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            errorMessage = "Couldn't import the reference audio: \(error.localizedDescription)"
        }
    }
}
