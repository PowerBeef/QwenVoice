import Foundation
import QwenVoiceCore
import QwenVoiceNative
import SwiftUI

@MainActor
final class CustomVoiceCoordinator: ObservableObject {
    @Published var isGenerating = false
    @Published var errorMessage: String?
    @Published var presentedSheet: CustomVoicePresentedSheet?
    private var generationTask: Task<Void, Never>?

    func presentBatch(draft: CustomVoiceDraft) {
        presentedSheet = .batch(.custom(draft: draft))
    }

    func presentLongFormBatch(draft: CustomVoiceDraft) {
        presentedSheet = .batch(
            .custom(
                draft: draft,
                initialText: draft.text,
                initialSegmentationMode: .longForm
            )
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
        guard !isGenerating, !ttsEngineStore.hasActiveGeneration else { return }
        guard draft.hasText, ttsEngineStore.isReady else { return }

        if let model = activeModel, !isModelAvailable {
            errorMessage = modelManager.recoveryDetail(for: model)
            return
        }

        if LongTextGenerationRouter.shouldRouteToLongFormBatch(draft.text) {
            presentLongFormBatch(draft: draft)
            return
        }

        isGenerating = true
        errorMessage = nil

        generationTask = Task { @MainActor in
            defer {
                audioPlayer.setLivePreviewEstimate(nil)
                self.isGenerating = false
                self.generationTask = nil
            }
            do {
                guard let model = activeModel else {
                    self.errorMessage = "Model configuration not found"
                    return
                }

                let outputPath = makeOutputPath(subfolder: model.outputSubfolder, text: draft.text)
                let generationRequest = Self.makeGenerationRequest(
                    draft: draft,
                    model: model,
                    outputPath: outputPath
                )
                AppGenerationTimeline.shared.recordSubmitted(
                    id: generationRequest.generationID,
                    mode: generationRequest.modeIdentifier
                )
                audioPlayer.setLivePreviewEstimate(
                    LivePreviewEstimate(text: draft.text)
                )
                let result = try await ttsEngineStore.generate(generationRequest)
                AppGenerationTimeline.shared.recordCompleted(
                    id: generationRequest.generationID,
                    mode: generationRequest.modeIdentifier,
                    usedStreaming: result.usedStreaming,
                    finishReason: result.finishReason?.rawValue,
                    summary: result.telemetrySummary
                )
                GenerationTelemetryMerger.scheduleMerge(generationID: generationRequest.generationID)

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

                GenerationPersistence.persistAndAutoplay(
                    generation,
                    result: result,
                    text: draft.text,
                    audioPlayer: audioPlayer,
                    caller: "CustomVoiceCoordinator"
                )
            } catch is CancellationError {
                audioPlayer.abortLivePreviewIfNeeded()
                self.errorMessage = nil
            } catch {
                audioPlayer.abortLivePreviewIfNeeded()
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelGeneration(
        ttsEngineStore: TTSEngineStore,
        audioPlayer: AudioPlayerViewModel
    ) {
        guard isGenerating || generationTask != nil else { return }
        generationTask?.cancel()
        Task { @MainActor in
            try? await ttsEngineStore.cancelActiveGeneration()
            audioPlayer.abortLivePreviewIfNeeded()
            self.errorMessage = nil
            self.isGenerating = false
            self.generationTask = nil
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
            streamingInterval: QwenVoiceCore.GenerationSemantics.appStreamingInterval,
            streamingTitle: Swift.String(draft.text.prefix(40)),
            languageHint: draft.selectedLanguage.rawValue,
            payload: .custom(
                speakerID: draft.selectedSpeaker,
                deliveryStyle: model.supportsInstructionControl ? draft.emotion : nil
            ),
            generationID: UUID()
        )
    }

}
