import Foundation
import QwenVoiceCore

@MainActor
final class SavedVoicesViewModel: ObservableObject {
    @Published private(set) var voices: [Voice] = SavedVoicesSessionCache.voices
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private var hasLoadedOnce = !SavedVoicesSessionCache.voices.isEmpty
    private var pendingRefresh = false
    private var loadTask: Task<Void, Never>?
    private var lastRefreshAction: (() async -> Void)?

    func ensureLoaded(using ttsEngine: some TTSEngine) async {
        guard ttsEngine.isReady else { return }
        guard !hasLoadedOnce else { return }
        startLoad(using: ttsEngine, clearsVisibleError: true)
    }

    func refresh(using ttsEngine: some TTSEngine) async {
        guard ttsEngine.isReady else { return }

        if isLoading {
            pendingRefresh = true
            return
        }

        startLoad(using: ttsEngine, clearsVisibleError: voices.isEmpty)
    }

    func insertOrReplace(_ voice: Voice) {
        voices.removeAll { $0.id == voice.id }
        voices.append(voice)
        voices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        SavedVoicesSessionCache.voices = voices
        hasLoadedOnce = true
        loadError = nil
    }

    func removeVoiceFromVisibleState(id: String) {
        voices.removeAll { $0.id == id }
        SavedVoicesSessionCache.voices = voices
    }

    private func startLoad(using ttsEngine: some TTSEngine, clearsVisibleError: Bool) {
        guard !isLoading else { return }
        lastRefreshAction = { [weak self] in
            guard let self else { return }
            await self.refresh(using: ttsEngine)
        }

        let interval = AppPerformanceSignposts.begin("Saved Voices Load")
        let wallStart = DispatchTime.now().uptimeNanoseconds

        isLoading = true
        if clearsVisibleError {
            loadError = nil
        }

        loadTask = Task { [weak self] in
            guard let self else { return }

            defer {
                AppPerformanceSignposts.end(interval)
            }

            do {
                let loadedVoices = try await ttsEngine.listPreparedVoices()
                await MainActor.run {
                    self.voices = loadedVoices
                    SavedVoicesSessionCache.voices = loadedVoices
                    self.loadError = nil
                    self.hasLoadedOnce = true
                    self.finishLoad(wallStart: wallStart)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.loadError = error.localizedDescription
                    self.finishLoad(wallStart: wallStart)
                }
            }
        }
    }

    private func finishLoad(wallStart: UInt64) {
        #if DEBUG
        let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000)
        print("[Performance][SavedVoicesViewModel] load_wall_ms=\(elapsedMs)")
        #endif

        isLoading = false
        loadTask = nil

        if pendingRefresh {
            pendingRefresh = false
            if let lastRefreshAction {
                Task {
                    await lastRefreshAction()
                }
            }
        }
    }
}

@MainActor private enum SavedVoicesSessionCache {
    static var voices: [Voice] = []
}
