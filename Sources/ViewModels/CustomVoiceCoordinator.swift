import Foundation
import QwenVoiceCore
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
        guard !isGenerating else { return }
        guard draft.hasText, ttsEngineStore.isReady else { return }

        if let model = activeModel, !isModelAvailable {
            errorMessage = modelManager.recoveryDetail(for: model)
            return
        }

        if LongTextGenerationRouter.shouldRouteToLongFormBatch(draft.text) {
            presentLongFormBatch(draft: draft)
            return
        }

        let traceModelID = activeModel?.id ?? "missing-model"
        CustomVoiceUIPerformanceTrace.beginCustomVoiceGeneration(
            modelID: traceModelID,
            snapshotLoadState: CustomVoiceUIPerformanceTrace.loadStateDescription(for: ttsEngineStore.loadState),
            isEngineReady: ttsEngineStore.isReady
        )
        isGenerating = true
        errorMessage = nil
        CustomVoiceUIPerformanceTrace.mark(.coordinatorStarted)

        Task {
            do {
                guard let model = activeModel else {
                    self.errorMessage = "Model configuration not found"
                    self.isGenerating = false
                    CustomVoiceUIPerformanceTrace.finish(status: "failed_missing_model")
                    return
                }

                let outputPath = makeOutputPath(subfolder: model.outputSubfolder, text: draft.text)
                let generationRequest = Self.makeGenerationRequest(
                    draft: draft,
                    model: model,
                    outputPath: outputPath
                )
                CustomVoiceUIPerformanceTrace.mark(.previewSetupStarted)
                audioPlayer.prepareStreamingPreview(
                    title: String(draft.text.prefix(40)),
                    shouldAutoPlay: AudioService.shouldAutoPlay
                )

                CustomVoiceUIPerformanceTrace.mark(
                    .engineRequestStarted,
                    metadata: [
                        "model_id": model.id,
                        "speaker": draft.selectedSpeaker,
                        "delivery_style": draft.emotion,
                    ],
                    metrics: [
                        "text_characters": draft.text.count,
                    ]
                )
                let result = try await ttsEngineStore.generate(generationRequest)
                CustomVoiceUIPerformanceTrace.attachBenchmarkSample(result.benchmarkSample)
                CustomVoiceUIPerformanceTrace.mark(
                    .engineRequestFinished,
                    metadata: [
                        "used_streaming": result.usedStreaming ? "true" : "false",
                    ],
                    metrics: [
                        "duration_ms": Int(result.durationSeconds * 1_000),
                    ]
                )

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
                CustomVoiceUIPerformanceTrace.finish(
                    status: "success",
                    outputPath: result.audioPath,
                    durationSeconds: result.durationSeconds
                )
            } catch is CancellationError {
                audioPlayer.abortLivePreviewIfNeeded()
                self.errorMessage = nil
                CustomVoiceUIPerformanceTrace.finish(status: "cancelled")
            } catch {
                audioPlayer.abortLivePreviewIfNeeded()
                self.errorMessage = error.localizedDescription
                CustomVoiceUIPerformanceTrace.finish(status: "failed")
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
            streamingInterval: QwenVoiceCore.GenerationSemantics.appStreamingInterval,
            streamingTitle: Swift.String(draft.text.prefix(40)),
            payload: .custom(
                speakerID: draft.selectedSpeaker,
                deliveryStyle: draft.emotion
            )
        )
    }

}
