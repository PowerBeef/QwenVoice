import Foundation
import QwenVoiceNative
import SwiftUI

struct VoiceDesignActionAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct VoiceDesignSavedVoiceCandidate: Equatable {
    let audioPath: String
    let transcript: String
    let suggestedName: String
    let voiceDescription: String
    let emotion: String
    let text: String
    private(set) var savedVoiceName: String?

    var isSaved: Bool {
        savedVoiceName != nil
    }

    func matches(draft: VoiceDesignDraft) -> Bool {
        voiceDescription == draft.voiceDescription
            && emotion == draft.emotion
            && text == draft.text
    }

    mutating func markSaved(as voiceName: String) {
        savedVoiceName = voiceName
    }
}

@MainActor
final class VoiceDesignCoordinator: ObservableObject {
    @Published var isGenerating = false
    @Published var errorMessage: String?
    @Published var presentedSheet: VoiceDesignPresentedSheet?
    @Published var actionAlert: VoiceDesignActionAlert?
    @Published var latestSavedVoiceCandidate: VoiceDesignSavedVoiceCandidate?

    private var lastModelWarmupActivationID: Int?

    func handleScreenActivation(
        activationID: Int,
        model: TTSModel?,
        isModelAvailable: Bool,
        ttsEngineStore: TTSEngineStore
    ) async {
        guard activationID > 0 else { return }
        guard lastModelWarmupActivationID != activationID else { return }
        guard let model, ttsEngineStore.isReady, isModelAvailable else { return }

        lastModelWarmupActivationID = activationID
        await ttsEngineStore.ensureModelLoadedIfNeeded(id: model.id)
    }

    func currentSavedVoiceCandidate(for draft: VoiceDesignDraft) -> VoiceDesignSavedVoiceCandidate? {
        guard let latestSavedVoiceCandidate,
              latestSavedVoiceCandidate.matches(draft: draft) else {
            return nil
        }
        return latestSavedVoiceCandidate
    }

    func presentBatch(draft: VoiceDesignDraft) {
        presentedSheet = .batch(.design(draft: draft))
    }

    func presentSavedVoiceSheet(for draft: VoiceDesignDraft) {
        guard let candidate = currentSavedVoiceCandidate(for: draft) else { return }
        presentedSheet = .saveVoice(
            .designResult(
                voiceDescription: candidate.voiceDescription,
                audioPath: candidate.audioPath,
                transcript: candidate.transcript
            )
        )
    }

    func handleSavedVoice(
        _ voice: Voice,
        draft: VoiceDesignDraft,
        savedVoicesViewModel: SavedVoicesViewModel,
        ttsEngineStore: TTSEngineStore
    ) {
        if var candidate = latestSavedVoiceCandidate, candidate.matches(draft: draft) {
            candidate.markSaved(as: voice.name)
            latestSavedVoiceCandidate = candidate
        }
        savedVoicesViewModel.insertOrReplace(voice)
        Task { await savedVoicesViewModel.refresh(using: ttsEngineStore) }
        actionAlert = VoiceDesignActionAlert(
            title: "Saved Voice Added",
            message: "\"\(voice.name)\" is ready in Saved Voices."
        )
    }

    func scheduleIdlePrewarmIfNeeded(
        draft: VoiceDesignDraft,
        model: TTSModel?,
        isModelAvailable: Bool,
        ttsEngineStore: TTSEngineStore
    ) async {
        guard draft.idlePrewarmDebounceKey != nil else { return }
        do {
            try await Task.sleep(nanoseconds: 350_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        await prewarmSelectedModelIfNeeded(
            draft: draft,
            model: model,
            isModelAvailable: isModelAvailable,
            ttsEngineStore: ttsEngineStore
        )
    }

    func generate(
        draft: VoiceDesignDraft,
        activeModel: TTSModel?,
        isModelAvailable: Bool,
        ttsEngineStore: TTSEngineStore,
        audioPlayer: AudioPlayerViewModel,
        modelManager: ModelManagerViewModel
    ) {
        guard !draft.text.isEmpty, !draft.voiceDescription.isEmpty, ttsEngineStore.isReady else { return }

        if let model = activeModel, !isModelAvailable {
            errorMessage = modelManager.recoveryDetail(for: model)
            return
        }

        isGenerating = true
        errorMessage = nil
        latestSavedVoiceCandidate = nil

        let text = draft.text
        let voiceDescription = draft.voiceDescription
        let emotion = draft.emotion

        Task {
            do {
                guard let model = activeModel else {
                    self.errorMessage = "Model configuration not found"
                    self.isGenerating = false
                    return
                }

                let outputPath = makeOutputPath(subfolder: model.outputSubfolder, text: text)
                let generationRequest = Self.makeGenerationRequest(
                    draft: VoiceDesignDraft(
                        voiceDescription: voiceDescription,
                        emotion: emotion,
                        text: text
                    ),
                    model: model,
                    outputPath: outputPath
                )
                audioPlayer.prepareStreamingPreview(
                    title: String(text.prefix(40)),
                    shouldAutoPlay: AudioService.shouldAutoPlay
                )

                let result = try await ttsEngineStore.generate(generationRequest)

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
                    &generation,
                    result: result,
                    text: text,
                    audioPlayer: audioPlayer,
                    caller: "VoiceDesignCoordinator"
                )
                self.latestSavedVoiceCandidate = VoiceDesignSavedVoiceCandidate(
                    audioPath: generation.audioPath,
                    transcript: text,
                    suggestedName: SavedVoiceNameSuggestion.designResultName(from: voiceDescription),
                    voiceDescription: voiceDescription,
                    emotion: emotion,
                    text: text
                )
            } catch {
                if (error as? GenerationPersistence.PersistenceError) == nil {
                    audioPlayer.abortLivePreviewIfNeeded()
                }
                self.errorMessage = error.localizedDescription
            }

            self.isGenerating = false
        }
    }

    nonisolated static func makeGenerationRequest(
        draft: VoiceDesignDraft,
        model: TTSModel,
        outputPath: String
    ) -> GenerationRequest {
        GenerationRequest(
            modelID: model.id,
            text: draft.text,
            outputPath: outputPath,
            shouldStream: true,
            streamingTitle: String(draft.text.prefix(40)),
            payload: .design(
                voiceDescription: draft.voiceDescription,
                deliveryStyle: draft.emotion
            )
        )
    }

    nonisolated static func makeIdlePrewarmRequest(
        draft: VoiceDesignDraft,
        model: TTSModel
    ) -> GenerationRequest? {
        guard draft.shouldIdlePrewarm else { return nil }
        return GenerationRequest(
            modelID: model.id,
            text: draft.text,
            outputPath: "",
            payload: .design(
                voiceDescription: draft.voiceDescription,
                deliveryStyle: draft.emotion
            )
        )
    }

    private func prewarmSelectedModelIfNeeded(
        draft: VoiceDesignDraft,
        model: TTSModel?,
        isModelAvailable: Bool,
        ttsEngineStore: TTSEngineStore
    ) async {
        guard let model,
              let idlePrewarmRequest = Self.makeIdlePrewarmRequest(draft: draft, model: model),
              ttsEngineStore.isReady,
              isModelAvailable,
              !isGenerating else {
            return
        }
        await ttsEngineStore.prewarmModelIfNeeded(for: idlePrewarmRequest)
    }
}
