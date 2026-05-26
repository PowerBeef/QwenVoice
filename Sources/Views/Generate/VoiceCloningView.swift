import QwenVoiceCore
import QwenVoiceNative
import SwiftUI
import UniformTypeIdentifiers

enum VoiceCloningReferenceAudioSupport {
    static let allowedFileExtensions: Set<String> = [
        "wav", "mp3", "aiff", "aif", "m4a", "flac", "ogg", "webm",
    ]

    static let supportedFormatDescription = "WAV, MP3, AIFF, M4A, FLAC, OGG, or WebM"

    static let webMType = UTType(filenameExtension: "webm")
        ?? UTType(mimeType: "audio/webm")
        ?? UTType(mimeType: "video/webm")

    static let openPanelContentTypes: [UTType] = {
        var seen = Set<String>()
        var types: [UTType] = []

        func append(_ type: UTType) {
            if seen.insert(type.identifier).inserted {
                types.append(type)
            }
        }

        append(.audio)

        for ext in allowedFileExtensions.sorted() where ext != "webm" {
            if let type = UTType(filenameExtension: ext) {
                append(type)
            }
        }

        if let webMType {
            append(webMType)
        }

        return types
    }()
}

struct VoiceCloningView: View {
    @Binding private var draft: VoiceCloningDraft
    @Binding private var pendingSavedVoiceHandoff: PendingVoiceCloningHandoff?
    @StateObject private var coordinator = VoiceCloningCoordinator()

    @ObservedObject private var ttsEngineStore: TTSEngineStore
    @ObservedObject private var modelManager: ModelManagerViewModel
    private let audioPlayer: AudioPlayerViewModel
    private let savedVoicesViewModel: SavedVoicesViewModel

    private var cloneModel: TTSModel? {
        modelManager.generationActiveVariant(for: .clone)
    }

    private var isModelAvailable: Bool {
        guard let cloneModel else { return false }
        return modelManager.isAvailable(cloneModel)
    }

    private var modelDisplayName: String {
        cloneModel.map(modelManager.generationVariantDisplayName) ?? "Unknown"
    }

    private var canRunBatch: Bool {
        ttsEngineStore.isReady
            && draft.referenceAudioPath != nil
            && isModelAvailable
            && !ttsEngineStore.hasActiveGeneration
    }

    private var isGenerationActive: Bool {
        coordinator.isGenerating || ttsEngineStore.hasActiveGeneration
    }

    private var clonePrimingRequestKey: String? {
        guard let model = cloneModel,
              ttsEngineStore.isReady,
              isModelAvailable,
              let referenceAudioPath = draft.referenceAudioPath else {
            return nil
        }
        if let selectedSavedVoiceID = draft.selectedSavedVoiceID,
           coordinator.hydratedSavedVoiceID != selectedSavedVoiceID,
           coordinator.transcriptLoadError == nil {
            return nil
        }
        return GenerationSemantics.clonePreparationKey(
            modelID: model.id,
            reference: CloneReference(
                audioPath: referenceAudioPath,
                transcript: draft.trimmedReferenceTranscript,
                preparedVoiceID: draft.selectedSavedVoiceID
            )
        )
    }

    private var clonePrimingTaskID: String {
        clonePrimingRequestKey ?? "clone-priming-idle"
    }

    private var cloneContextStatus: VoiceCloningContextStatus? {
        VoiceCloningContextStatus(
            CloneReferenceContextResolver.resolve(
                hasReference: draft.referenceAudioPath != nil,
                selectedSavedVoiceID: draft.selectedSavedVoiceID,
                hydratedSavedVoiceID: coordinator.hydratedSavedVoiceID,
                transcriptLoadError: coordinator.transcriptLoadError,
                expectedPreparationKey: clonePrimingRequestKey,
                preparationState: ttsEngineStore.clonePreparationState
            )
        )
    }

    private var readinessDescriptor: VoiceCloningReadinessDescriptor {
        VoiceCloningReadiness.describe(
            engineReady: ttsEngineStore.isReady,
            isModelAvailable: isModelAvailable,
            modelDisplayName: modelDisplayName,
            referenceAudioPath: draft.referenceAudioPath,
            text: draft.text,
            contextStatus: cloneContextStatus
        )
    }

    private var savedVoicesLoadTaskID: String {
        "\(ttsEngineStore.isReady)-\(draft.selectedSavedVoiceID ?? "none")"
    }

    private var savedVoices: [Voice] {
        savedVoicesViewModel.voices
    }

    private var selectedVoice: Voice? {
        guard let selectedSavedVoiceID = draft.selectedSavedVoiceID else { return nil }
        return savedVoices.first(where: { $0.id == selectedSavedVoiceID })
    }

    private var savedVoicesLoadError: String? {
        guard let loadError = savedVoicesViewModel.loadError else { return nil }
        return "Couldn't load saved voices right now. You can still clone from a file. \(loadError)"
    }

    private var selectedSavedVoiceID: Binding<String?> {
        Binding(
            get: { draft.selectedSavedVoiceID },
            set: { newID in
                guard let newID else {
                    if draft.referenceAudioPath != nil || draft.selectedSavedVoiceID != nil {
                        coordinator.clearReference(draft: $draft)
                    }
                    return
                }

                guard let voice = savedVoices.first(where: { $0.id == newID }) else { return }
                coordinator.selectSavedVoice(voice, draft: $draft)
            }
        )
    }

    private var isDragOverBinding: Binding<Bool> {
        Binding(
            get: { coordinator.isDragOver },
            set: { coordinator.isDragOver = $0 }
        )
    }

    init(
        draft: Binding<VoiceCloningDraft>,
        pendingSavedVoiceHandoff: Binding<PendingVoiceCloningHandoff?>,
        ttsEngineStore: TTSEngineStore,
        audioPlayer: AudioPlayerViewModel,
        modelManager: ModelManagerViewModel,
        savedVoicesViewModel: SavedVoicesViewModel
    ) {
        _draft = draft
        _pendingSavedVoiceHandoff = pendingSavedVoiceHandoff
        _ttsEngineStore = ObservedObject(wrappedValue: ttsEngineStore)
        _modelManager = ObservedObject(wrappedValue: modelManager)
        self.audioPlayer = audioPlayer
        self.savedVoicesViewModel = savedVoicesViewModel
    }

    static func shouldStartDeferredClonePrewarm(
        clonePreparationState: ClonePreparationState,
        expectedKey: String?,
        isGenerating: Bool
    ) -> Bool {
        clonePreparationState.isPrimed
            && clonePreparationState.key == expectedKey
            && !isGenerating
    }

    var body: some View {
        PageScaffold(
            accessibilityIdentifier: "screen_voiceCloning",
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
        .onDrop(of: [.fileURL], isTargeted: isDragOverBinding) { providers in
            coordinator.handleDrop(providers, draft: $draft)
        }
        .overlay(
            coordinator.isDragOver
                ? RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.voiceCloning.opacity(0.5), lineWidth: 2)
                    .padding(8)
                : nil
        )
        .task(id: savedVoicesLoadTaskID) {
            guard ttsEngineStore.isReady else { return }

            if draft.selectedSavedVoiceID != nil {
                await savedVoicesViewModel.refresh(using: ttsEngineStore)
            } else {
                await savedVoicesViewModel.ensureLoaded(using: ttsEngineStore)
            }

            coordinator.syncSavedVoiceSelectionState(
                draft: $draft,
                selectedVoice: selectedVoice,
                savedVoicesViewModel: savedVoicesViewModel
            )
        }
        .onChange(of: savedVoicesViewModel.voices) { _, _ in
            coordinator.syncSavedVoiceSelectionState(
                draft: $draft,
                selectedVoice: selectedVoice,
                savedVoicesViewModel: savedVoicesViewModel
            )
        }
        .task(id: clonePrimingTaskID) {
            await coordinator.syncCloneReferencePriming(
                draft: draft,
                cloneModel: cloneModel,
                isModelAvailable: isModelAvailable,
                clonePrimingRequestKey: clonePrimingRequestKey,
                ttsEngineStore: ttsEngineStore
            )
        }
        .onAppear(perform: handleAppear)
        .onChange(of: modelManager.statuses) { _, _ in reconcileGenerationVariantSelection() }
        .onChange(of: modelManager.activeVariantRevision) { _, _ in reconcileGenerationVariantSelection() }
        .onChange(of: pendingSavedVoiceHandoff) { _, _ in
            coordinator.consumePendingSavedVoiceHandoffIfNeeded(
                draft: $draft,
                pendingSavedVoiceHandoff: $pendingSavedVoiceHandoff
            )
        }
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

// MARK: - Panel Layout

private extension VoiceCloningView {
    var configurationPanel: some View {
        CompactConfigurationSection(
            title: "Configuration",
            detail: "Transcript-backed saved voices give the strongest reusable clone prompts.",
            iconName: "slider.horizontal.3",
            accentColor: AppTheme.voiceCloning,
            trailingText: nil,
            trailingAccessory: AnyView(variantSelector),
            rowSpacing: LayoutConstants.generationConfigurationRowSpacing,
            panelPadding: LayoutConstants.generationConfigurationPanelPadding,
            contentSlotHeight: LayoutConstants.generationConfigurationSlotHeight
        ) {
            VStack(alignment: .leading, spacing: 0) {
                VoiceCloningReferenceSettings(
                    savedVoices: savedVoices,
                    selectedSavedVoiceID: selectedSavedVoiceID,
                    referenceAudioPath: draft.referenceAudioPath,
                    selectedVoice: selectedVoice,
                    savedVoicesLoadError: savedVoicesLoadError,
                    transcriptLoadError: coordinator.transcriptLoadError,
                    browseForAudio: { coordinator.browseForAudio(draft: $draft) },
                    clearReference: { coordinator.clearReference(draft: $draft) },
                    retrySavedVoices: { Task { await savedVoicesViewModel.refresh(using: ttsEngineStore) } }
                )
                VoiceCloningTranscriptSettings(referenceTranscript: $draft.referenceTranscript)
                languageSettings
            }
        }
        .overlay(alignment: .topLeading) {
            HiddenAccessibilityMarker(
                value: "Reference",
                identifier: "voiceCloning_configuration"
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    var variantSelector: some View {
        GenerationVariantSelector(
            mode: .clone,
            modelManager: modelManager,
            accentColor: AppTheme.voiceCloning,
            accessibilityPrefix: "voiceCloning",
            isDisabled: isGenerationActive
        )
    }

    var composerPanel: some View {
        StudioSectionCard(
            title: "Script",
            iconName: "text.alignleft",
            accentColor: AppTheme.voiceCloning,
            trailingText: isGenerationActive ? "Generating" : readinessDescriptor.trailingText,
            fillsAvailableHeight: true,
            accessibilityIdentifier: "voiceCloning_script"
        ) {
            VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
                TextInputView(
                    text: $draft.text,
                    isGenerating: isGenerationActive,
                    placeholder: "Type the line for the cloned voice",
                    buttonColor: AppTheme.voiceCloning,
                    batchAction: { coordinator.presentBatch(draft: draft) },
                    batchDisabled: !canRunBatch,
                    generateDisabled: !ttsEngineStore.isReady
                        || !isModelAvailable
                        || draft.referenceAudioPath == nil
                        || !draft.hasText
                        || ttsEngineStore.hasActiveGeneration,
                    isEmbedded: true,
                    usesFlexibleEmbeddedHeight: true,
                    onGenerate: {
                        coordinator.generate(
                            draft: $draft,
                            cloneModel: cloneModel,
                            isModelAvailable: isModelAvailable,
                            clonePrimingRequestKey: clonePrimingRequestKey,
                            selectedVoice: selectedVoice,
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

                VoiceCloningComposerFooter(
                    isReadyForFastGenerate: readinessDescriptor.noteIsReady,
                    readinessTitle: readinessDescriptor.title,
                    readinessDetail: readinessDescriptor.detail,
                    isGenerating: isGenerationActive,
                    errorMessage: coordinator.errorMessage
                )
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    var languageSettings: some View {
        QwenLanguagePickerRow(
            selectedLanguage: $draft.selectedLanguage,
            accentColor: AppTheme.voiceCloning,
            accessibilityPrefix: "voiceCloning"
        )
    }
}

private extension VoiceCloningView {
    func handleAppear() {
        reconcileGenerationVariantSelection()
        coordinator.handleAppear(
            draft: $draft,
            pendingSavedVoiceHandoff: $pendingSavedVoiceHandoff
        )
    }

    func reconcileGenerationVariantSelection() {
        modelManager.reconcileGenerationVariantSelectionIfNeeded(for: .clone)
    }
}

// MARK: - Reference Settings

private struct VoiceCloningReferenceSettings: View {
    let savedVoices: [Voice]
    @Binding var selectedSavedVoiceID: String?
    let referenceAudioPath: String?
    let selectedVoice: Voice?
    let savedVoicesLoadError: String?
    let transcriptLoadError: String?
    let browseForAudio: () -> Void
    let clearReference: () -> Void
    let retrySavedVoices: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
            Text("Source")
                .font(.subheadline.weight(.semibold))

            CloneSourceRow(
                savedVoices: savedVoices,
                selectedSavedVoiceID: $selectedSavedVoiceID,
                browseForAudio: browseForAudio,
                referenceAudioPath: referenceAudioPath
            )

            Text("Only use voice clips you own or have permission to clone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("voiceCloning_consentNotice")

            CloneReferenceStatus(
                referenceAudioPath: referenceAudioPath,
                selectedVoice: selectedVoice,
                clearReference: clearReference,
                accentColor: AppTheme.voiceCloning
            )

            if let savedVoicesLoadError {
                CloneWarningCard(
                    message: savedVoicesLoadError,
                    actionLabel: "Retry",
                    action: retrySavedVoices,
                    accentColor: AppTheme.voiceCloning,
                    accessibilityIdentifier: "voiceCloning_savedVoicesWarning",
                    actionAccessibilityIdentifier: "voiceCloning_savedVoicesRetry"
                )
            }

            if let transcriptLoadError {
                CloneWarningCard(
                    message: transcriptLoadError,
                    actionLabel: nil,
                    action: nil,
                    accentColor: AppTheme.voiceCloning,
                    accessibilityIdentifier: "voiceCloning_transcriptWarning",
                    actionAccessibilityIdentifier: nil
                )
            }
        }
        .padding(.vertical, LayoutConstants.generationConfigurationRowVerticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceCloning_voiceSetup")
    }
}

// MARK: - Transcript Settings

private struct VoiceCloningTranscriptSettings: View {
    @Binding var referenceTranscript: String

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
            Text("Transcript")
                .font(.subheadline.weight(.semibold))

            TextField(
                "What does the reference audio say? (optional)",
                text: $referenceTranscript
            )
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassTextField(radius: 8)
            .accessibilityLabel("Transcript")
            .accessibilityIdentifier("voiceCloning_transcriptInput")

            Text("Best quality uses reference audio plus an accurate transcript; audio-only cloning remains available as a lower-guidance fallback.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, LayoutConstants.generationConfigurationRowVerticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceCloning_transcriptField")
    }
}

// MARK: - Composer Footer

private struct VoiceCloningComposerFooter: View {
    let isReadyForFastGenerate: Bool
    let readinessTitle: String
    let readinessDetail: String
    let isGenerating: Bool
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.compactGap) {
            WorkflowReadinessNote(
                isReady: isReadyForFastGenerate && !isGenerating,
                title: isGenerating ? "Generating final audio" : readinessTitle,
                detail: isGenerating ? "Rendering the complete take. The file lands in the player when ready." : readinessDetail,
                accentColor: AppTheme.voiceCloning,
                isBusy: isGenerating,
                accessibilityIdentifier: "voiceCloning_readiness"
            )

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

// MARK: - Reference Status

private struct CloneReferenceStatus: View {
    let referenceAudioPath: String?
    let selectedVoice: Voice?
    let clearReference: () -> Void
    let accentColor: Color

    @State private var showsWarningDetails = false

    var body: some View {
        if let path = referenceAudioPath {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)

                    // When a quality warning is present, the second
                    // line in this VStack becomes a tappable chip
                    // instead of the reference-detail caption, so
                    // the saved-voice panel stays a single row and the
                    // Transcript field below it keeps its room inside
                    // the fixed 184 pt configuration slot. Popover-on-
                    // tap carries the full headline + summary so the
                    // user can still see everything the wrapping
                    // Label used to render inline.
                    if let token = selectedVoice?.qualityWarnings.first,
                       let shortLabel = PreparedVoiceQualityWarning.shortLabel(for: token) {
                        warningChip(token: token, shortLabel: shortLabel)
                    } else {
                        Text(referenceDetail)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                Button("Clear") {
                    AppLaunchConfiguration.performAnimated(.default) {
                        clearReference()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .inlinePanel(padding: 8, radius: 10)
            .accessibilityIdentifier("voiceCloning_activeReference")
        } else {
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Add a reference clip to unlock the script composer and generation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 1)
        }
    }

    private var referenceDetail: String {
        guard let selectedVoice else {
            return "Imported file ready"
        }
        return selectedVoice.hasTranscript
            ? "Transcript-backed saved voice"
            : "Audio-only saved voice"
    }

    @ViewBuilder
    private func warningChip(token: String, shortLabel: String) -> some View {
        // Inline (no-capsule) variant of the saved-voices warning chip
        // — the capsule background + stroke + 3 pt vertical padding
        // would make this row ~6-10 pt taller than the 10 pt "Saved
        // voice ready" Text it replaces, which would shift every
        // element below it (Transcript label, Transcript field) down.
        // Keeping the row height identical to the no-warning state
        // means the saved-voice panel renders at a constant total
        // height regardless of warning presence, so the Transcript
        // position is invariant.
        Button {
            showsWarningDetails = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                Text(shortLabel)
                    .font(.system(size: 10, weight: .medium))
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("voiceCloning_referenceWarning")
        .accessibilityHint(selectedVoice?.qualityHeadline ?? shortLabel)
        .popover(isPresented: $showsWarningDetails, arrowEdge: .top) {
            warningDetailsPopover(warnings: selectedVoice?.qualityWarnings ?? [token])
        }
    }

    @ViewBuilder
    private func warningDetailsPopover(warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Reference outside recommended range",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(PreparedVoiceQualityWarning.summary(for: warnings))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: 340)
    }
}

// MARK: - Source Row

private struct CloneSourceRow: View {
    let savedVoices: [Voice]
    @Binding var selectedSavedVoiceID: String?
    let browseForAudio: () -> Void
    let referenceAudioPath: String?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if !savedVoices.isEmpty {
                savedVoicePicker
            }

            importButton

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var savedVoicePicker: some View {
        if !savedVoices.isEmpty {
            Picker("Saved voice", selection: $selectedSavedVoiceID) {
                Text("Choose a saved voice")
                    .tag(Optional<String>.none)

                ForEach(savedVoices) { voice in
                    Text(voice.hasTranscript ? "\(voice.name) · transcript" : "\(voice.name) · audio only")
                        .tag(Optional(voice.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .focusEffectDisabled()
            .frame(minWidth: LayoutConstants.configurationControlMinWidth, maxWidth: 180, alignment: .leading)
            .accessibilityValue(savedVoices.first(where: { $0.id == selectedSavedVoiceID })?.name ?? "")
            .accessibilityIdentifier("voiceCloning_savedVoicePicker")
        }
    }

    private var importButton: some View {
        Button {
            browseForAudio()
        } label: {
            Label(referenceAudioPath == nil ? "Import reference audio..." : "Replace reference audio...", systemImage: "waveform.badge.plus")
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .tint(AppTheme.voiceCloning)
        .controlSize(.small)
        .accessibilityIdentifier("voiceCloning_importButton")
    }
}

// MARK: - Warning Card

private struct CloneWarningCard: View {
    let message: String
    let actionLabel: String?
    let action: (() -> Void)?
    let accentColor: Color
    let accessibilityIdentifier: String
    let actionAccessibilityIdentifier: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionLabel, let action {
                    Button(actionLabel) {
                        action()
                    }
                    .buttonStyle(.bordered)
                    .tint(accentColor)
                    .controlSize(.small)
                    .accessibilityIdentifier(actionAccessibilityIdentifier ?? "")
                }
            }

            Spacer(minLength: 0)
        }
        .inlinePanel(padding: 12, radius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
