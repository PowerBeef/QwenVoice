import Foundation
import QwenVoiceNative
import SwiftUI

@MainActor
final class CustomVoiceCoordinator: ObservableObject {
    @Published var isGenerating = false
    @Published var errorMessage: String?
    @Published var presentedSheet: CustomVoicePresentedSheet?

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

    func presentBatch(draft: CustomVoiceDraft) {
        presentedSheet = .batch(.custom(draft: draft))
    }

    func scheduleIdlePrewarmIfNeeded(
        draft: CustomVoiceDraft,
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
        draft: CustomVoiceDraft,
        activeModel: TTSModel?,
        isModelAvailable: Bool,
        ttsEngineStore: TTSEngineStore,
        audioPlayer: AudioPlayerViewModel,
        modelManager: ModelManagerViewModel
    ) {
        guard !draft.text.isEmpty, ttsEngineStore.isReady else { return }

        if let model = activeModel, !isModelAvailable {
            errorMessage = modelManager.recoveryDetail(for: model)
            return
        }

        isGenerating = true
        errorMessage = nil

        Task {
            do {
                guard let model = activeModel else {
                    self.errorMessage = "Model configuration not found"
                    self.isGenerating = false
                    return
                }

                let outputPath = makeOutputPath(subfolder: model.outputSubfolder, text: draft.text)
                let generationRequest = Self.makeGenerationRequest(
                    draft: draft,
                    model: model,
                    outputPath: outputPath
                )
                audioPlayer.prepareStreamingPreview(
                    title: String(draft.text.prefix(40)),
                    shouldAutoPlay: AudioService.shouldAutoPlay
                )

                let result = try await ttsEngineStore.generate(generationRequest)

                var generation = Generation(
                    text: draft.text,
                    mode: model.mode.rawValue,
                    modelTier: model.tier,
                    voice: draft.selectedSpeaker,
                    emotion: draft.emotion,
                    speed: nil,
                    audioPath: result.audioPath,
                    duration: result.durationSeconds,
                    createdAt: Date()
                )

                try GenerationPersistence.persistAndAutoplay(
                    &generation,
                    result: result,
                    text: draft.text,
                    audioPlayer: audioPlayer,
                    caller: "CustomVoiceCoordinator"
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
        draft: CustomVoiceDraft,
        model: TTSModel,
        outputPath: String
    ) -> GenerationRequest {
        GenerationRequest(
            modelID: model.id,
            text: draft.text,
            outputPath: outputPath,
            shouldStream: true,
            streamingTitle: String(draft.text.prefix(40)),
            payload: .custom(
                speakerID: draft.selectedSpeaker,
                deliveryStyle: draft.emotion
            )
        )
    }

    nonisolated static func makeIdlePrewarmRequest(
        draft: CustomVoiceDraft,
        model: TTSModel
    ) -> GenerationRequest? {
        guard draft.shouldIdlePrewarm else { return nil }
        return GenerationRequest(
            modelID: model.id,
            text: draft.text,
            outputPath: "",
            payload: .custom(
                speakerID: draft.selectedSpeaker,
                deliveryStyle: draft.emotion
            )
        )
    }

    private func prewarmSelectedModelIfNeeded(
        draft: CustomVoiceDraft,
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
