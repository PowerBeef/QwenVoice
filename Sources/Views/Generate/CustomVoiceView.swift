import QwenVoiceCore
import QwenVoiceNative
import SwiftUI

struct CustomVoiceReadinessPresentation: Equatable {
    let isReady: Bool
    let title: String
    let detail: String
    let trailingText: String?
    let isBusy: Bool

    static func resolve(
        snapshot: TTSEngineSnapshot,
        activeModelID: String?,
        isModelAvailable: Bool,
        hasText: Bool,
        isGenerating: Bool,
        modelDisplayName: String
    ) -> CustomVoiceReadinessPresentation {
        if isGenerating {
            return CustomVoiceReadinessPresentation(
                isReady: false,
                title: "Generating final audio",
                detail: "Rendering the complete take. The file lands in the player when ready.",
                trailingText: "Generating",
                isBusy: true
            )
        }

        guard snapshot.isReady else {
            return CustomVoiceReadinessPresentation(
                isReady: false,
                title: "Engine starting",
                detail: "The engine is still preparing.",
                trailingText: nil,
                isBusy: snapshot.loadState == .starting
            )
        }

        guard isModelAvailable else {
            return CustomVoiceReadinessPresentation(
                isReady: false,
                title: "Install the active model",
                detail: "Install \(modelDisplayName) in Models to enable generation.",
                trailingText: nil,
                isBusy: false
            )
        }

        guard hasText else {
            return CustomVoiceReadinessPresentation(
                isReady: false,
                title: "Add a script",
                detail: "Speaker and delivery are set. Add a line to generate.",
                trailingText: nil,
                isBusy: false
            )
        }

        switch snapshot.loadState {
        case .loaded(let modelID) where modelID == activeModelID:
            return CustomVoiceReadinessPresentation(
                isReady: true,
                title: "Ready to generate",
                detail: "Ready to generate and save.",
                trailingText: "Ready",
                isBusy: false
            )
        case .starting:
            return CustomVoiceReadinessPresentation(
                isReady: false,
                title: "Preparing Custom Voice",
                detail: "Loading the Custom Voice path. You can generate now; preparation finishes in the background.",
                trailingText: "Preparing",
                isBusy: true
            )
        case .idle:
            return CustomVoiceReadinessPresentation(
                isReady: false,
                title: "Preparing Custom Voice",
                detail: "Warming the Custom Voice path. Generation will finish preparation if it hasn't yet.",
                trailingText: "Preparing",
                isBusy: true
            )
        case .running(let modelID, _, _) where modelID == activeModelID:
            return CustomVoiceReadinessPresentation(
                isReady: false,
                title: "Preparing Custom Voice",
                detail: "Warming the Custom Voice path.",
                trailingText: "Preparing",
                isBusy: true
            )
        case .running:
            return CustomVoiceReadinessPresentation(
                isReady: false,
                title: "Engine busy",
                detail: "Finishing another engine task before Custom Voice can be ready.",
                trailingText: nil,
                isBusy: true
            )
        case .loaded:
            return CustomVoiceReadinessPresentation(
                isReady: false,
                title: "Custom Voice will prepare on generate",
                detail: "A different model is loaded. The engine will switch to Custom Voice on generate.",
                trailingText: nil,
                isBusy: false
            )
        case .failed(let message):
            return CustomVoiceReadinessPresentation(
                isReady: false,
                title: "Engine needs attention",
                detail: message,
                trailingText: nil,
                isBusy: false
            )
        }
    }
}

struct CustomVoiceView: View {
    @Binding private var draft: CustomVoiceDraft
    @StateObject private var coordinator = CustomVoiceCoordinator()
    /// Language detected from the typed script; floats matching speakers and
    /// the matching language to "Recommended" sections in the pickers.
    @State private var detectedPromptLanguage: Qwen3SupportedLanguage = .auto

    @ObservedObject private var ttsEngineStore: TTSEngineStore
    @ObservedObject private var modelManager: ModelManagerViewModel
    private let audioPlayer: AudioPlayerViewModel

    private var activeMode: GenerationMode {
        .custom
    }

    private var activeModel: TTSModel? {
        modelManager.generationActiveVariant(for: activeMode)
    }

    private var isModelAvailable: Bool {
        guard let activeModel else { return false }
        return modelManager.isAvailable(activeModel)
    }

    private var modelDisplayName: String {
        activeModel.map(modelManager.generationVariantDisplayName) ?? "Unknown"
    }

    private var supportsDeliveryControl: Bool {
        activeModel?.supportsInstructionControl ?? false
    }

    private var speakerNativeLanguage: Qwen3SupportedLanguage {
        TTSModel.qwenLanguage(forSpeaker: draft.selectedSpeaker)
    }

    private var languageHintMessage: String? {
        guard draft.selectedLanguage != .auto,
              draft.selectedLanguage != speakerNativeLanguage else {
            return nil
        }
        let speakerName = TTSModel.speakerDescriptor(id: draft.selectedSpeaker)?.displayName
            ?? draft.selectedSpeaker.capitalized
        return "\(speakerName) is native to \(speakerNativeLanguage.displayName). \(draft.selectedLanguage.displayName) can still work, but pronunciation is usually best in the speaker's native language."
    }

    private var readinessPresentation: CustomVoiceReadinessPresentation {
        CustomVoiceReadinessPresentation.resolve(
            snapshot: ttsEngineStore.snapshot,
            activeModelID: activeModel?.id,
            isModelAvailable: isModelAvailable,
            hasText: draft.hasText,
            isGenerating: isGenerationActive,
            modelDisplayName: modelDisplayName
        )
    }

    private var isGenerationActive: Bool {
        coordinator.isGenerating || ttsEngineStore.hasActiveGeneration
    }

    private var canGenerate: Bool {
        ttsEngineStore.isReady
            && isModelAvailable
            && draft.hasText
            && !ttsEngineStore.hasActiveGeneration
    }

    private var canRunBatch: Bool {
        ttsEngineStore.isReady
            && isModelAvailable
            && !ttsEngineStore.hasActiveGeneration
    }

    init(
        draft: Binding<CustomVoiceDraft>,
        ttsEngineStore: TTSEngineStore,
        audioPlayer: AudioPlayerViewModel,
        modelManager: ModelManagerViewModel
    ) {
        _draft = draft
        _ttsEngineStore = ObservedObject(wrappedValue: ttsEngineStore)
        _modelManager = ObservedObject(wrappedValue: modelManager)
        self.audioPlayer = audioPlayer
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
        .modeGlassTint(AppTheme.customVoice)
        .modeCanvasBackdrop(AppTheme.customVoice)
        .onAppear(perform: reconcileGenerationVariantSelection)
        .onAppear { detectedPromptLanguage = PromptLanguageDetector.detect(draft.text) }
        .onChange(of: draft.text) { _, newText in
            let detected = PromptLanguageDetector.detect(newText)
            if detected != detectedPromptLanguage {
                detectedPromptLanguage = detected
            }
        }
        .onChange(of: modelManager.statuses) { _, _ in reconcileGenerationVariantSelection() }
        .onChange(of: modelManager.activeVariantRevision) { _, _ in reconcileGenerationVariantSelection() }
        .sheet(item: $coordinator.presentedSheet) { presentedSheet in
            switch presentedSheet {
            case .batch(let configuration):
                BatchGenerationSheet(
                    mode: configuration.mode,
                    voice: configuration.voice,
                    emotion: configuration.emotion,
                    languageHint: draft.selectedLanguage.rawValue,
                    voiceDescription: configuration.voiceDescription,
                    refAudio: configuration.refAudio,
                    refText: configuration.refText,
                    initialText: configuration.initialText,
                    initialSegmentationMode: configuration.initialSegmentationMode
                )
                .environmentObject(ttsEngineStore)
                .environmentObject(audioPlayer)
            }
        }
    }

    func reconcileGenerationVariantSelection() {
        modelManager.reconcileGenerationVariantSelectionIfNeeded(for: activeMode)
    }
}

// MARK: - Subviews

private extension CustomVoiceView {
    var configurationPanel: some View {
        CompactConfigurationSection(
            title: "Configuration",
            iconName: "slider.horizontal.3",
            accentColor: AppTheme.customVoice,
            trailingAccessory: AnyView(variantSelector),
            rowSpacing: LayoutConstants.generationConfigurationRowSpacing,
            panelPadding: LayoutConstants.generationConfigurationPanelPadding
        ) {
            VStack(alignment: .leading, spacing: 0) {
                speakerSettings
                languageSettings
                if supportsDeliveryControl {
                    deliverySettings
                } else {
                    deliveryUnsupportedHint
                }
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

    var variantSelector: some View {
        GenerationVariantSelector(
            mode: activeMode,
            modelManager: modelManager,
            accentColor: AppTheme.customVoice,
            accessibilityPrefix: "customVoice",
            isDisabled: isGenerationActive
        )
    }

    var composerPanel: some View {
        StudioSectionCard(
            title: "Script",
            iconName: "text.alignleft",
            accentColor: AppTheme.customVoice,
            trailingText: readinessPresentation.trailingText,
            fillsAvailableHeight: true,
            accessibilityIdentifier: "customVoice_script"
        ) {
            VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
                TextInputView(
                    text: $draft.text,
                    isGenerating: isGenerationActive,
                    placeholder: "Type or paste your script",
                    buttonColor: AppTheme.customVoice,
                    batchAction: { coordinator.presentBatch(draft: draft) },
                    batchDisabled: !canRunBatch,
                    generateDisabled: !ttsEngineStore.isReady || !isModelAvailable || ttsEngineStore.hasActiveGeneration,
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
                    },
                    onCancel: {
                        coordinator.cancelGeneration(
                            ttsEngineStore: ttsEngineStore,
                            audioPlayer: audioPlayer
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

    var speakerSettings: some View {
        SpeakerPickerRow(
            selectedSpeaker: $draft.selectedSpeaker,
            recommendedLanguage: detectedPromptLanguage
        ) { speaker in
            draft.selectedSpeaker = speaker
            draft.selectedLanguage = TTSModel.qwenLanguage(forSpeaker: speaker)
        }
    }

    var languageSettings: some View {
        QwenLanguagePickerRow(
            selectedLanguage: $draft.selectedLanguage,
            accentColor: AppTheme.customVoice,
            accessibilityPrefix: "customVoice",
            hint: languageHintMessage,
            showsDefaultHelp: false,
            recommended: detectedPromptLanguage
        )
    }

    var deliverySettings: some View {
        GenerationSetupRow(
            label: "Delivery",
            accessibilityIdentifier: "customVoice_toneSpeed"
        ) {
            DeliveryControlsView(
                emotion: $draft.emotion,
                accentColor: AppTheme.customVoice,
                isCompact: true,
                showsLabel: false
            )
        }
    }

    var deliveryUnsupportedHint: some View {
        GenerationSetupNotice(
            message: "Delivery controls are available with the active 1.7B Custom Voice models.",
            iconName: "slider.horizontal.3",
            accentColor: AppTheme.customVoice,
            accessibilityIdentifier: "customVoice_deliveryUnsupported"
        )
    }

    // speakerPicker moved to SpeakerPickerRow struct for rebuild isolation

    var generationReadiness: some View {
        WorkflowReadinessNote(
            isReady: readinessPresentation.isReady,
            title: readinessPresentation.title,
            detail: readinessPresentation.detail,
            accentColor: AppTheme.customVoice,
            isBusy: readinessPresentation.isBusy,
            accessibilityIdentifier: "customVoice_readiness"
        )
    }

    // selectedSpeakerValueAnchor moved to SpeakerPickerRow struct

    var composerFooter: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.compactGap) {
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
    /// Language detected from the typed prompt (`PromptLanguageDetector`).
    /// When confident (non-`.auto`), speakers native to it float to a
    /// "Recommended" section — mirroring the iOS voice-picker treatment.
    var recommendedLanguage: Qwen3SupportedLanguage? = nil
    var onSelectSpeaker: ((String) -> Void)?

    private var speakerSelection: Binding<String> {
        Binding(
            get: { selectedSpeaker },
            set: { newValue in
                if let onSelectSpeaker {
                    onSelectSpeaker(newValue)
                } else {
                    selectedSpeaker = newValue
                }
            }
        )
    }

    private var recommendedSpeakers: [String] {
        guard let recommendedLanguage, recommendedLanguage != .auto else { return [] }
        return TTSModel.allSpeakers.filter {
            TTSModel.qwenLanguage(forSpeaker: $0) == recommendedLanguage
        }
    }

    var body: some View {
        GenerationSetupRow(
            label: "Speaker",
            accessibilityIdentifier: "customVoice_voiceSetup"
        ) {
            Picker("Speaker", selection: speakerSelection) {
                if !recommendedSpeakers.isEmpty {
                    Section("Recommended for your script") {
                        ForEach(recommendedSpeakers, id: \.self) { speaker in
                            Text(TTSModel.speakerPickerLabel(for: speaker)).tag(speaker)
                        }
                    }
                    Section("All speakers") {
                        ForEach(TTSModel.allSpeakers.filter { !recommendedSpeakers.contains($0) }, id: \.self) { speaker in
                            Text(TTSModel.speakerPickerLabel(for: speaker)).tag(speaker)
                        }
                    }
                } else {
                    ForEach(TTSModel.allSpeakers, id: \.self) { speaker in
                        Text(TTSModel.speakerPickerLabel(for: speaker)).tag(speaker)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .focusEffectDisabled()
            .frame(minWidth: LayoutConstants.configurationControlMinWidth, maxWidth: 220, alignment: .leading)
            .accessibilityValue(TTSModel.speakerPickerLabel(for: selectedSpeaker))
            .accessibilityIdentifier("customVoice_speakerPicker")
        }
        .overlay(alignment: .topLeading) {
            Text(TTSModel.speakerPickerLabel(for: selectedSpeaker))
                .font(.caption2)
                .foregroundStyle(.clear)
                .opacity(0.01)
                .frame(width: 1, height: 1, alignment: .leading)
                .allowsHitTesting(false)
                .accessibilityLabel(TTSModel.speakerPickerLabel(for: selectedSpeaker))
                .accessibilityValue(TTSModel.speakerPickerLabel(for: selectedSpeaker))
                .accessibilityIdentifier("customVoice_selectedSpeaker")
        }
    }
}
