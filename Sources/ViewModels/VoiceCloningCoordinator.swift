import AppKit
import Foundation
import QwenVoiceNative
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class VoiceCloningCoordinator: ObservableObject {
    @Published var isGenerating = false
    @Published var errorMessage: String?
    @Published var transcriptLoadError: String?
    @Published var hydratedSavedVoiceID: String?
    @Published var isDragOver = false
    @Published var presentedSheet: VoiceCloningPresentedSheet?

    private var lastModelWarmupActivationID: Int?

    func handleScreenActivation(
        activationID: Int,
        cloneModel: TTSModel?,
        isModelAvailable: Bool,
        ttsEngineStore: TTSEngineStore
    ) async {
        guard activationID > 0 else { return }
        guard lastModelWarmupActivationID != activationID else { return }
        guard let model = cloneModel, ttsEngineStore.isReady, isModelAvailable else { return }

        lastModelWarmupActivationID = activationID
        await ttsEngineStore.ensureModelLoadedIfNeeded(id: model.id)
    }

    func presentBatch(draft: VoiceCloningDraft) {
        presentedSheet = .batch(.clone(draft: draft))
    }

    func handleAppear(
        draft: Binding<VoiceCloningDraft>,
        pendingSavedVoiceHandoff: Binding<PendingVoiceCloningHandoff?>
    ) {
        consumePendingSavedVoiceHandoffIfNeeded(
            draft: draft,
            pendingSavedVoiceHandoff: pendingSavedVoiceHandoff
        )
    }

    func consumePendingSavedVoiceHandoffIfNeeded(
        draft: Binding<VoiceCloningDraft>,
        pendingSavedVoiceHandoff: Binding<PendingVoiceCloningHandoff?>
    ) {
        guard let handoff = pendingSavedVoiceHandoff.wrappedValue else { return }
        applyPendingSavedVoiceHandoff(handoff, draft: draft)
        pendingSavedVoiceHandoff.wrappedValue = nil
    }

    func generate(
        draft: Binding<VoiceCloningDraft>,
        cloneModel: TTSModel?,
        isModelAvailable: Bool,
        clonePrimingRequestKey: String?,
        selectedVoice: Voice?,
        ttsEngineStore: TTSEngineStore,
        audioPlayer: AudioPlayerViewModel,
        modelManager: ModelManagerViewModel
    ) {
        guard !draft.wrappedValue.text.isEmpty else { return }
        guard ttsEngineStore.isReady else { return }

        if let model = cloneModel, !isModelAvailable {
            errorMessage = modelManager.recoveryDetail(for: model)
            return
        }

        isGenerating = true
        errorMessage = nil

        Task { @MainActor in
            do {
                guard let model = cloneModel else {
                    errorMessage = "Model configuration not found"
                    isGenerating = false
                    return
                }

                ensureSelectedSavedVoiceHydratedIfNeeded(
                    draft: draft,
                    selectedVoice: selectedVoice
                )

                let currentDraft = draft.wrappedValue
                guard let refPath = currentDraft.referenceAudioPath else {
                    errorMessage = "Select a reference audio file before generating."
                    isGenerating = false
                    return
                }

                let primedReferenceMatches = ttsEngineStore.clonePreparationState.isPrimed
                    && ttsEngineStore.clonePreparationState.key == clonePrimingRequestKey

                if !primedReferenceMatches {
                    do {
                        try await ttsEngineStore.ensureCloneReferencePrimed(
                            modelID: model.id,
                            reference: CloneReference(
                                audioPath: refPath,
                                transcript: currentDraft.referenceTranscript.isEmpty ? nil : currentDraft.referenceTranscript,
                                preparedVoiceID: currentDraft.selectedSavedVoiceID
                            )
                        )
                    } catch {
                        #if DEBUG
                        print("[Performance][VoiceCloningCoordinator] clone priming degraded: \(error.localizedDescription)")
                        #endif
                    }
                }

                let outputPath = makeOutputPath(
                    subfolder: model.outputSubfolder,
                    text: currentDraft.text
                )
                let title = String(currentDraft.text.prefix(40))
                guard let generationRequest = Self.makeGenerationRequest(
                    draft: currentDraft,
                    model: model,
                    outputPath: outputPath
                ) else {
                    errorMessage = "Select a reference audio file before generating."
                    isGenerating = false
                    return
                }
                audioPlayer.prepareStreamingPreview(
                    title: title,
                    shouldAutoPlay: AudioService.shouldAutoPlay
                )

                let result = try await ttsEngineStore.generate(generationRequest)

                let voiceName = selectedVoice?.name
                    ?? URL(fileURLWithPath: refPath).deletingPathExtension().lastPathComponent
                var generation = Generation(
                    text: currentDraft.text,
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
                    text: currentDraft.text,
                    audioPlayer: audioPlayer,
                    caller: "VoiceCloningCoordinator"
                )
            } catch is CancellationError {
                audioPlayer.abortLivePreviewIfNeeded()
                errorMessage = nil
            } catch {
                if (error as? GenerationPersistence.PersistenceError) == nil {
                    audioPlayer.abortLivePreviewIfNeeded()
                }
                errorMessage = error.localizedDescription
            }

            isGenerating = false
        }
    }

    static func makeGenerationRequest(
        draft: VoiceCloningDraft,
        model: TTSModel,
        outputPath: String
    ) -> GenerationRequest? {
        guard let referenceAudioPath = draft.referenceAudioPath else { return nil }
        return GenerationRequest(
            modelID: model.id,
            text: draft.text,
            outputPath: outputPath,
            shouldStream: true,
            streamingTitle: String(draft.text.prefix(40)),
            payload: .clone(
                reference: CloneReference(
                    audioPath: referenceAudioPath,
                    transcript: draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript,
                    preparedVoiceID: draft.selectedSavedVoiceID
                )
            )
        )
    }

    func syncCloneReferencePriming(
        draft: VoiceCloningDraft,
        cloneModel: TTSModel?,
        isModelAvailable: Bool,
        clonePrimingRequestKey: String?,
        ttsEngineStore: TTSEngineStore
    ) async {
        guard !isGenerating else { return }
        guard let model = cloneModel,
              isModelAvailable,
              let refPath = draft.referenceAudioPath,
              let clonePrimingRequestKey else {
            await ttsEngineStore.cancelClonePreparationIfNeeded()
            return
        }

        if let selectedSavedVoiceID = draft.selectedSavedVoiceID,
           hydratedSavedVoiceID != selectedSavedVoiceID,
           transcriptLoadError == nil {
            await ttsEngineStore.cancelClonePreparationIfNeeded()
            return
        }

        let trimmedRefText = draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript
        do {
            try await ttsEngineStore.ensureCloneReferencePrimed(
                modelID: model.id,
                reference: CloneReference(
                    audioPath: refPath,
                    transcript: trimmedRefText,
                    preparedVoiceID: draft.selectedSavedVoiceID
                )
            )
        } catch {
            #if DEBUG
            print("[Performance][VoiceCloningCoordinator] clone priming failed key=\(clonePrimingRequestKey) error=\(error.localizedDescription)")
            #endif
        }
    }

    func selectSavedVoice(
        _ voice: Voice,
        draft: Binding<VoiceCloningDraft>
    ) {
        applySavedVoice(voice, draft: draft)
    }

    func ensureSelectedSavedVoiceHydratedIfNeeded(
        draft: Binding<VoiceCloningDraft>,
        selectedVoice: Voice?
    ) {
        guard let selectedVoice else { return }
        guard draft.wrappedValue.selectedSavedVoiceID == selectedVoice.id else { return }
        guard hydratedSavedVoiceID != selectedVoice.id else { return }
        guard transcriptLoadError == nil else { return }
        applySavedVoice(selectedVoice, draft: draft)
    }

    func clearReference(draft: Binding<VoiceCloningDraft>) {
        draft.wrappedValue.clearReference()
        transcriptLoadError = nil
        hydratedSavedVoiceID = nil
    }

    func syncSavedVoiceSelectionState(
        draft: Binding<VoiceCloningDraft>,
        selectedVoice: Voice?,
        savedVoicesViewModel: SavedVoicesViewModel
    ) {
        if draft.wrappedValue.selectedSavedVoiceID != nil,
           selectedVoice == nil,
           (savedVoicesViewModel.isLoading || savedVoicesViewModel.loadError != nil) {
            return
        }

        switch SavedVoiceCloneHydration.action(
            draft: draft.wrappedValue,
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
                applySavedVoice(selectedVoice, draft: draft)
            }
        case .clearStaleSelection:
            clearReference(draft: draft)
        }
    }

    func handleDrop(
        _ providers: [NSItemProvider],
        draft: Binding<VoiceCloningDraft>
    ) -> Bool {
        guard let provider = providers.first else { return false }
        let allowedExtensions = VoiceCloningReferenceAudioSupport.allowedFileExtensions
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            let ext = url.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else {
                Task { @MainActor in
                    self.errorMessage = "Unsupported file type '.\(ext)'. Drop an audio file (\(VoiceCloningReferenceAudioSupport.supportedFormatDescription))."
                }
                return
            }

            Task { @MainActor in
                self.replaceReference(with: url.path, draft: draft)
            }
        }
        return true
    }

    func browseForAudio(draft: Binding<VoiceCloningDraft>) {
        if UITestAutomationSupport.isStubBackendMode,
           let url = UITestAutomationSupport.importAudioURL {
            replaceReference(with: url.path, draft: draft)
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = VoiceCloningReferenceAudioSupport.openPanelContentTypes
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            replaceReference(with: url.path, draft: draft)
        }
    }

    private func applyPendingSavedVoiceHandoff(
        _ handoff: PendingVoiceCloningHandoff,
        draft: Binding<VoiceCloningDraft>
    ) {
        draft.wrappedValue.applySavedVoiceSelection(
            id: handoff.savedVoiceID,
            wavPath: handoff.wavPath,
            transcript: handoff.transcript
        )
        transcriptLoadError = handoff.transcriptLoadError
        hydratedSavedVoiceID = handoff.savedVoiceID
    }

    private func applySavedVoice(
        _ voice: Voice,
        draft: Binding<VoiceCloningDraft>
    ) {
        do {
            let transcript = try SavedVoiceCloneHydration.loadTranscript(for: voice)
            draft.wrappedValue.applySavedVoice(voice, transcript: transcript)
            transcriptLoadError = nil
        } catch {
            draft.wrappedValue.applySavedVoice(voice, transcript: "")
            transcriptLoadError = "Couldn't load the saved transcript for \"\(voice.name)\". You can still clone from the audio file alone."
        }
        hydratedSavedVoiceID = voice.id
    }

    private func replaceReference(
        with path: String,
        draft: Binding<VoiceCloningDraft>
    ) {
        draft.wrappedValue.referenceAudioPath = path
        draft.wrappedValue.selectedSavedVoiceID = nil
        transcriptLoadError = nil
        hydratedSavedVoiceID = nil
    }
}
