import Foundation

@MainActor
final class SavedVoicesViewModel: ObservableObject {
    @Published private(set) var voices: [Voice] = SavedVoicesSessionCache.voices
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private var hasLoadedOnce = !SavedVoicesSessionCache.voices.isEmpty
    private var pendingRefresh = false
    private var loadTask: Task<Void, Never>?
    private weak var lastPythonBridge: PythonBridge?

    func ensureLoaded(using pythonBridge: PythonBridge) async {
        guard pythonBridge.isReady else { return }
        guard !hasLoadedOnce else { return }
        startLoad(using: pythonBridge, clearsVisibleError: true)
    }

    func refresh(using pythonBridge: PythonBridge) async {
        guard pythonBridge.isReady else { return }

        if isLoading {
            pendingRefresh = true
            return
        }

        startLoad(using: pythonBridge, clearsVisibleError: voices.isEmpty)
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

    private func startLoad(using pythonBridge: PythonBridge, clearsVisibleError: Bool) {
        guard !isLoading else { return }
        lastPythonBridge = pythonBridge

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
                let loadedVoices = try await pythonBridge.listVoices()
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
            if let lastPythonBridge {
                Task { [weak self] in
                    guard let self else { return }
                    await self.refresh(using: lastPythonBridge)
                }
            }
        }
    }
}

private enum SavedVoicesSessionCache {
    static var voices: [Voice] = []
}
