import Combine
import Foundation
import QwenVoiceNative

@MainActor
final class MacGenerationWarmupCoordinator: ObservableObject {
    struct WarmupRequest: Equatable {
        let mode: GenerationMode
        let modelID: String
    }

    private let debounce: Duration
    private var pendingTask: Task<Void, Never>?
    private var pendingRequest: WarmupRequest?
    private var dispatchedRequest: WarmupRequest?
    private var revision: UInt64 = 0

    init(debounce: Duration = .milliseconds(300)) {
        self.debounce = debounce
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
              snapshot.isReady,
              shouldAllowNavigationWarmup(snapshot: snapshot) else {
            cancelPendingWarmup()
            return
        }

        let request = WarmupRequest(mode: mode, modelID: modelID)
        guard dispatchedRequest == nil else {
            cancelPendingWarmup()
            return
        }
        guard pendingRequest != request else { return }

        revision += 1
        let scheduledRevision = revision
        let debounce = self.debounce
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
                  self.shouldAllowNavigationWarmup(snapshot: ttsEngineStore.snapshot) else {
                return
            }

            self.pendingRequest = nil
            self.dispatchedRequest = request
            await ttsEngineStore.ensureModelLoadedIfNeeded(id: request.modelID)
        }
    }

    func cancelPendingWarmup() {
        revision += 1
        pendingTask?.cancel()
        pendingTask = nil
        pendingRequest = nil
    }

    func observe(snapshot: TTSEngineSnapshot) {
        if !shouldAllowNavigationWarmup(snapshot: snapshot) {
            cancelPendingWarmup()
        }

        switch snapshot.loadState {
        case .loaded, .failed:
            dispatchedRequest = nil
        case .idle, .starting, .running:
            break
        }
    }

    private func shouldAllowNavigationWarmup(snapshot: TTSEngineSnapshot) -> Bool {
        if case .idle = snapshot.loadState {
            return true
        }
        return false
    }
}
