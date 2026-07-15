import Foundation
import QwenVoiceCore

@MainActor
enum IOSStudioGenerationActions {
    static func cancelGeneration(
        coordinator: StudioGenerationCoordinator,
        ttsEngine: TTSEngineStore,
        audioPlayer: AudioPlayerViewModel
    ) {
        coordinator.generationTask?.cancel()
        // Stop audible preview immediately, but keep the generation coordinator
        // nonterminal until the engine-owned cancellation barrier confirms that
        // MLX compute has exited. The generation task's defer owns the UI finish.
        audioPlayer.abortLivePreviewIfNeeded()
        Task {
            try? await ttsEngine.cancelActiveGeneration()
        }
    }
}
