import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class VoiceCloningCoordinator: ObservableObject {
    @Published var isGenerating = false
    @Published var errorMessage: String?
    @Published var transcriptLoadError: String?
    @Published var hydratedSavedVoiceID: String?
    @Published var isDragOver = false
    @Published var showingBatch = false

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

    func syncUITestState(
        draft: VoiceCloningDraft,
        cloneContextStatus: VoiceCloningContextStatus?,
        readinessDescriptor: VoiceCloningReadinessDescriptor
    ) {
        guard UITestAutomationSupport.isEnabled else { return }
        TestStateProvider.shared.referenceAudioPath = draft.referenceAudioPath ?? ""
        TestStateProvider.shared.referenceTranscript = draft.referenceTranscript
        TestStateProvider.shared.text = draft.text
        TestStateProvider.shared.isGenerating = isGenerating
        TestStateProvider.shared.clonePrimingPhase = cloneContextStatusTestValue(cloneContextStatus)
        TestStateProvider.shared.cloneFastReady = readinessDescriptor.noteIsReady
    }

    func handleTestSeedScreenState(
        _ notification: Notification,
        draft: Binding<VoiceCloningDraft>
    ) {
        guard UITestAutomationSupport.isEnabled,
              let screen = notification.userInfo?["screen"] as? String,
              screen == "voiceCloning" else { return }

        if let referenceAudioPath = notification.userInfo?["referenceAudioPath"] as? String {
            draft.wrappedValue.selectedSavedVoiceID = nil
            draft.wrappedValue.referenceAudioPath = referenceAudioPath.isEmpty ? nil : referenceAudioPath
            hydratedSavedVoiceID = nil
        }
        if let referenceTranscript = notification.userInfo?["referenceTranscript"] as? String {
            draft.wrappedValue.referenceTranscript = referenceTranscript
        }
        if let text = notification.userInfo?["text"] as? String {
            draft.wrappedValue.text = text
        }
    }

    func handleTestStartGeneration(
        _ notification: Notification,
        draft: Binding<VoiceCloningDraft>,
        cloneModel: TTSModel?,
        isModelAvailable: Bool,
        clonePrimingRequestKey: String?,
        selectedVoice: Voice?,
        pythonBridge: PythonBridge,
        audioPlayer: AudioPlayerViewModel,
        modelManager: ModelManagerViewModel
    ) {
        guard UITestAutomationSupport.isEnabled,
              let screen = notification.userInfo?["screen"] as? String,
              screen == "voiceCloning" else { return }

        if let text = notification.userInfo?["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.wrappedValue.text = text
        }
        if let referenceAudioPath = notification.userInfo?["referenceAudioPath"] as? String,
           !referenceAudioPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            replaceReference(with: referenceAudioPath, draft: draft)
        }
        if let referenceTranscript = notification.userInfo?["referenceTranscript"] as? String {
            draft.wrappedValue.referenceTranscript = referenceTranscript
        }

        generate(
            draft: draft,
            cloneModel: cloneModel,
            isModelAvailable: isModelAvailable,
            clonePrimingRequestKey: clonePrimingRequestKey,
            selectedVoice: selectedVoice,
            pythonBridge: pythonBridge,
            audioPlayer: audioPlayer,
            modelManager: modelManager
        )
    }

    func generate(
        draft: Binding<VoiceCloningDraft>,
        cloneModel: TTSModel?,
        isModelAvailable: Bool,
        clonePrimingRequestKey: String?,
        selectedVoice: Voice?,
        pythonBridge: PythonBridge,
        audioPlayer: AudioPlayerViewModel,
        modelManager: ModelManagerViewModel
    ) {
        guard !draft.wrappedValue.text.isEmpty else { return }
        guard pythonBridge.isReady else { return }

        if let model = cloneModel, !isModelAvailable {
            errorMessage = modelManager.recoveryDetail(for: model)
            return
        }

        isGenerating = true
        errorMessage = nil

        Task { @MainActor in
            do {
                UITestAutomationSupport.recordAction(
                    "clone-generate-start",
                    appSupportDir: QwenVoiceApp.appSupportDir
                )

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

                if pythonBridge.cloneReferencePrimingPhase != .primed
                    || pythonBridge.cloneReferencePrimingKey != clonePrimingRequestKey {
                    do {
                        try await pythonBridge.ensureCloneReferencePrimed(
                            modelID: model.id,
                            refAudio: refPath,
                            refText: currentDraft.referenceTranscript.isEmpty ? nil : currentDraft.referenceTranscript
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
                audioPlayer.prepareStreamingPreview(
                    title: title,
                    shouldAutoPlay: AudioService.shouldAutoPlay
                )

                let result = try await pythonBridge.generateCloneStreamingFlow(
                    modelID: model.id,
                    text: currentDraft.text,
                    refAudio: refPath,
                    refText: currentDraft.referenceTranscript.isEmpty ? nil : currentDraft.referenceTranscript,
                    outputPath: outputPath
                )

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
                UITestAutomationSupport.recordAction(
                    "clone-generate-success",
                    appSupportDir: QwenVoiceApp.appSupportDir
                )
            } catch {
                UITestAutomationSupport.recordAction(
                    "clone-generate-error",
                    appSupportDir: QwenVoiceApp.appSupportDir
                )
                if (error as? GenerationPersistence.PersistenceError) == nil {
                    audioPlayer.abortLivePreviewIfNeeded()
                }
                errorMessage = error.localizedDescription
            }

            isGenerating = false
        }
    }

    func syncCloneReferencePriming(
        draft: VoiceCloningDraft,
        cloneModel: TTSModel?,
        isModelAvailable: Bool,
        clonePrimingRequestKey: String?,
        pythonBridge: PythonBridge
    ) async {
        guard !isGenerating else { return }
        guard let model = cloneModel,
              isModelAvailable,
              let refPath = draft.referenceAudioPath,
              let clonePrimingRequestKey else {
            await pythonBridge.cancelCloneReferencePrimingIfNeeded()
            return
        }

        if let selectedSavedVoiceID = draft.selectedSavedVoiceID,
           hydratedSavedVoiceID != selectedSavedVoiceID,
           transcriptLoadError == nil {
            await pythonBridge.cancelCloneReferencePrimingIfNeeded()
            return
        }

        let trimmedRefText = draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript
        do {
            try await pythonBridge.ensureCloneReferencePrimed(
                modelID: model.id,
                refAudio: refPath,
                refText: trimmedRefText
            )
        } catch {
            #if DEBUG
            print("[Performance][VoiceCloningCoordinator] clone priming failed key=\(clonePrimingRequestKey) error=\(error.localizedDescription)")
            #endif
        }
    }

    func prepareSelectedModelIfNeeded(
        cloneModel: TTSModel?,
        isModelAvailable: Bool,
        pythonBridge: PythonBridge
    ) async {
        guard let model = cloneModel else { return }
        guard pythonBridge.isReady, isModelAvailable, !isGenerating else { return }
        await pythonBridge.ensureModelLoadedIfNeeded(id: model.id)
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

    private func cloneContextStatusTestValue(
        _ status: VoiceCloningContextStatus?
    ) -> String {
        switch status {
        case .none:
            return "none"
        case .waitingForHydration:
            return "waitingForHydration"
        case .preparing:
            return "preparing"
        case .primed:
            return "primed"
        case .fallback:
            return "fallback"
        }
    }
}
