import Combine
import Foundation
import QwenVoiceCore
import QwenVoiceNative

@MainActor
final class MacGenerationWarmupCoordinator: ObservableObject {
    struct WarmupRequest: Equatable {
        let mode: GenerationMode
        let modelID: String
    }

    private let debounce: Duration
    private let customVoiceDebounce: Duration
    private var pendingTask: Task<Void, Never>?
    private var pendingRequest: WarmupRequest?
    private var dispatchedRequest: WarmupRequest?
    private var completedRequest: WarmupRequest?
    private var revision: UInt64 = 0

    init(debounce: Duration = .milliseconds(300), customVoiceDebounce: Duration = .milliseconds(100)) {
        self.debounce = debounce
        self.customVoiceDebounce = customVoiceDebounce
    }

    func scheduleWarmupIfNeeded(
        mode: GenerationMode?,
        modelID: String?,
        isModelAvailable: Bool,
        snapshot: TTSEngineSnapshot,
        ttsEngineStore: TTSEngineStore
    ) {
        guard let mode,
              let modelID,
              isModelAvailable,
              snapshot.isReady else {
            cancelPendingWarmup()
            return
        }

        let request = WarmupRequest(mode: mode, modelID: modelID)
        guard shouldAllowNavigationWarmup(snapshot: snapshot, request: request) else {
            cancelPendingWarmup()
            return
        }
        guard completedRequest != request else {
            cancelPendingWarmup()
            return
        }
        guard dispatchedRequest == nil else {
            cancelPendingWarmup()
            return
        }
        guard pendingRequest != request else { return }

        revision += 1
        let scheduledRevision = revision
        let debounce = request.mode == .custom ? customVoiceDebounce : self.debounce
        pendingRequest = request
        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self, weak ttsEngineStore] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            guard let self,
                  let ttsEngineStore,
                  !Task.isCancelled,
                  self.revision == scheduledRevision,
                  self.pendingRequest == request,
                  self.dispatchedRequest == nil,
                  ttsEngineStore.snapshot.isReady,
                  self.shouldAllowNavigationWarmup(
                    snapshot: ttsEngineStore.snapshot,
                    request: request
                  ) else {
                return
            }

            self.pendingRequest = nil
            self.dispatchedRequest = request
            if let prewarmRequest = self.interactivePrewarmRequest(for: request) {
                _ = await ttsEngineStore.prefetchInteractiveReadinessIfNeeded(for: prewarmRequest)
            } else {
                await ttsEngineStore.ensureModelLoadedIfNeeded(id: request.modelID)
            }
            if case .loaded(let loadedModelID) = ttsEngineStore.snapshot.loadState,
               loadedModelID == request.modelID {
                self.completedRequest = request
            }
        }
    }

    func cancelPendingWarmup() {
        revision += 1
        pendingTask?.cancel()
        pendingTask = nil
        pendingRequest = nil
    }

    func observe(snapshot: TTSEngineSnapshot) {
        if !shouldAllowAnyNavigationWarmup(snapshot: snapshot) {
            cancelPendingWarmup()
        }

        switch snapshot.loadState {
        case .idle:
            dispatchedRequest = nil
            completedRequest = nil
        case .loaded(let modelID):
            dispatchedRequest = nil
            if completedRequest?.modelID != modelID {
                completedRequest = nil
            }
        case .failed:
            dispatchedRequest = nil
            completedRequest = nil
        case .starting, .running:
            completedRequest = nil
            break
        }
    }

    private func shouldAllowNavigationWarmup(
        snapshot: TTSEngineSnapshot,
        request: WarmupRequest
    ) -> Bool {
        switch snapshot.loadState {
        case .idle:
            return true
        case .loaded(let modelID):
            return request.mode == .custom && modelID == request.modelID
        case .failed, .running, .starting:
            return false
        }
    }

    private func shouldAllowAnyNavigationWarmup(snapshot: TTSEngineSnapshot) -> Bool {
        switch snapshot.loadState {
        case .idle, .loaded:
            return true
        case .failed, .running, .starting:
            return false
        }
    }

    private func interactivePrewarmRequest(for request: WarmupRequest) -> GenerationRequest? {
        guard request.mode == .custom else { return nil }
        return GenerationRequest(
            modelID: request.modelID,
            text: QwenVoiceCore.GenerationSemantics.canonicalCustomWarmText,
            outputPath: "",
            shouldStream: true,
            streamingInterval: QwenVoiceCore.GenerationSemantics.appStreamingInterval,
            payload: .custom(
                speakerID: QwenVoiceCore.GenerationSemantics.canonicalCustomWarmSpeaker,
                deliveryStyle: QwenVoiceCore.GenerationSemantics.canonicalCustomWarmInstruction()
            )
        )
    }
}
