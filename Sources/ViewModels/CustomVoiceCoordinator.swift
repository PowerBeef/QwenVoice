import Foundation
import QwenVoiceNative
import SwiftUI

@MainActor
final class CustomVoiceCoordinator: ObservableObject {
    @Published var isGenerating = false
    @Published var errorMessage: String?
    @Published var presentedSheet: CustomVoicePresentedSheet?

    func presentBatch(draft: CustomVoiceDraft) {
        presentedSheet = .batch(.custom(draft: draft))
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
            } catch is CancellationError {
                audioPlayer.abortLivePreviewIfNeeded()
                self.errorMessage = nil
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

}
