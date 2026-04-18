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
    @EnvironmentObject var ttsEngineStore: TTSEngineStore
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject var modelManager: ModelManagerViewModel
    @EnvironmentObject var savedVoicesViewModel: SavedVoicesViewModel
    @EnvironmentObject var appCommandRouter: AppCommandRouter

    @Binding private var draft: VoiceCloningDraft
    @Binding private var pendingSavedVoiceHandoff: PendingVoiceCloningHandoff?
    @StateObject private var coordinator = VoiceCloningCoordinator()

    private var cloneModel: TTSModel? {
        TTSModel.model(for: .clone)
    }

    private var isModelAvailable: Bool {
        guard let cloneModel else { return false }
        return modelManager.isAvailable(cloneModel)
    }

    private var modelDisplayName: String {
        cloneModel?.name ?? "Unknown"
    }

    private var canRunBatch: Bool {
        ttsEngineStore.isReady && draft.referenceAudioPath != nil && isModelAvailable
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
                transcript: draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript,
                preparedVoiceID: draft.selectedSavedVoiceID
            )
        )
    }

    private var clonePrimingTaskID: String {
        clonePrimingRequestKey ?? "clone-priming-idle"
    }

    private var modelPreparationTaskID: String {
        "\(ttsEngineStore.isReady)-\(cloneModel?.id ?? "none")-\(isModelAvailable)-\(coordinator.isGenerating)"
    }

    private var cloneContextStatus: VoiceCloningContextStatus? {
        guard draft.referenceAudioPath != nil else { return nil }

        if let selectedSavedVoiceID = draft.selectedSavedVoiceID,
           coordinator.hydratedSavedVoiceID != selectedSavedVoiceID,
           coordinator.transcriptLoadError == nil {
            return .waitingForHydration
        }

        guard let clonePrimingRequestKey else { return nil }

        if ttsEngineStore.clonePreparationState.key == clonePrimingRequestKey {
            switch ttsEngineStore.clonePreparationState {
            case .idle:
                break
            case .preparing:
                return .preparing
            case .primed:
                return .primed
            case .failed:
                return .fallback(
                    ttsEngineStore.clonePreparationState.errorMessage
                        ?? "Voice context priming didn't finish. Generation is still available, but the first preview may be slower."
                )
            }
        }

        return .preparing
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

    private var isShowingBatchBinding: Binding<Bool> {
        Binding(
            get: { coordinator.showingBatch },
            set: { coordinator.showingBatch = $0 }
        )
    }

    init(
        draft: Binding<VoiceCloningDraft>,
        pendingSavedVoiceHandoff: Binding<PendingVoiceCloningHandoff?>
    ) {
        _draft = draft
        _pendingSavedVoiceHandoff = pendingSavedVoiceHandoff
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
        .task(id: modelPreparationTaskID) {
            await coordinator.prepareSelectedModelIfNeeded(
                cloneModel: cloneModel,
                isModelAvailable: isModelAvailable,
                ttsEngineStore: ttsEngineStore
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
        .onChange(of: pendingSavedVoiceHandoff) { _, _ in
            coordinator.consumePendingSavedVoiceHandoffIfNeeded(
                draft: $draft,
                pendingSavedVoiceHandoff: $pendingSavedVoiceHandoff
            )
        }
        .sheet(isPresented: isShowingBatchBinding) {
            BatchGenerationSheet(
                mode: .clone,
                refAudio: draft.referenceAudioPath,
                refText: draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript
            )
            .environmentObject(ttsEngineStore)
            .environmentObject(audioPlayer)
        }
    }
}

// MARK: - Panel Layout

private extension VoiceCloningView {
    var configurationPanel: some View {
        CompactConfigurationSection(
            title: "Configuration",
            detail: "Choose a saved voice or import a reference clip, then add an optional transcript.",
            iconName: "slider.horizontal.3",
            accentColor: AppTheme.voiceCloning,
            trailingText: nil,
            rowSpacing: LayoutConstants.generationConfigurationRowSpacing,
            panelPadding: LayoutConstants.generationConfigurationPanelPadding,
            contentSlotHeight: LayoutConstants.generationConfigurationSlotHeight,
            accessibilityIdentifier: "voiceCloning_configuration"
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

    var composerPanel: some View {
        StudioSectionCard(
            title: "Script",
            iconName: "text.alignleft",
            accentColor: AppTheme.voiceCloning,
            trailingText: readinessDescriptor.trailingText,
            fillsAvailableHeight: true,
            accessibilityIdentifier: "voiceCloning_script"
        ) {
            VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
                TextInputView(
                    text: $draft.text,
                    isGenerating: coordinator.isGenerating,
                    placeholder: "What should the cloned voice say?",
                    buttonColor: AppTheme.voiceCloning,
                    batchAction: { coordinator.showingBatch = true },
                    batchDisabled: !canRunBatch,
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
                    }
                )
                .disabled(!ttsEngineStore.isReady || !isModelAvailable || draft.referenceAudioPath == nil)

                VoiceCloningComposerFooter(
                    modelRecoveryCard: modelRecoveryCard,
                    isReadyForFastGenerate: readinessDescriptor.noteIsReady,
                    readinessTitle: readinessDescriptor.title,
                    readinessDetail: readinessDescriptor.detail,
                    errorMessage: coordinator.errorMessage
                )
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
}

private extension VoiceCloningView {
    func handleAppear() {
        coordinator.handleAppear(
            draft: $draft,
            pendingSavedVoiceHandoff: $pendingSavedVoiceHandoff
        )
    }

    var modelRecoveryCard: AnyView? {
        guard let model = cloneModel,
              let primaryActionTitle = modelManager.primaryActionTitle(for: model) else {
            return nil
        }

        return AnyView(
            ModelRecoveryCard(
                title: primaryActionTitle,
                detail: modelManager.recoveryDetail(for: model),
                primaryActionTitle: primaryActionTitle,
                accentColor: AppTheme.voiceCloning,
                accessibilityIdentifier: "voiceCloning_modelRecovery",
                onPrimaryAction: {
                    Task { await modelManager.download(model) }
                },
                onSecondaryAction: {
                    appCommandRouter.navigate(to: .models)
                }
            )
        )
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
        }
        .padding(.vertical, LayoutConstants.generationConfigurationRowVerticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceCloning_transcriptField")
    }
}

// MARK: - Composer Footer

private struct VoiceCloningComposerFooter: View {
    let modelRecoveryCard: AnyView?
    let isReadyForFastGenerate: Bool
    let readinessTitle: String
    let readinessDetail: String
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.compactGap) {
            if let modelRecoveryCard {
                modelRecoveryCard
            }

            WorkflowReadinessNote(
                isReady: isReadyForFastGenerate,
                title: readinessTitle,
                detail: readinessDetail,
                accentColor: AppTheme.voiceCloning,
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

                    Text(selectedVoice == nil ? "Imported file ready" : "Saved voice ready")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
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
                    Text(voice.name)
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
