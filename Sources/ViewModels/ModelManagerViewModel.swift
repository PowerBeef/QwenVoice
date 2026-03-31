import Foundation

/// Manages model download/delete state for ModelsView.
@MainActor
final class ModelManagerViewModel: ObservableObject {

    enum ModelStatus: Equatable {
        case checking
        case notDownloaded
        case downloading(downloadedBytes: Int64, totalBytes: Int64?)
        case downloaded(sizeBytes: Int)
        case error(message: String)
    }

    @Published var statuses: [String: ModelStatus] = [:]
    private let fileManager: FileManager
    private let modelsDirectory: URL
    private var downloaders: [String: HuggingFaceDownloader] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var stateEpochs: [String: Int] = [:]
    private var lastProgressPublishTimes: [String: ContinuousClock.Instant] = [:]
    private var stubDownloadTasks: [String: Task<Void, Never>] = [:]
    private var refreshTask: Task<Void, Never>?

    init(
        fileManager: FileManager = .default,
        modelsDirectory: URL = QwenVoiceApp.modelsDir
    ) {
        self.fileManager = fileManager
        self.modelsDirectory = modelsDirectory

        for model in TTSModel.all {
            statuses[model.id] = initialStatus(for: model)
        }
    }

    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }

        let task = Task { @MainActor in
            let interval = AppPerformanceSignposts.begin("Model Status Refresh")
            let wallStart = DispatchTime.now().uptimeNanoseconds
            await performRefresh()
            AppPerformanceSignposts.end(interval)
            #if DEBUG
            let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000)
            print("[Performance][ModelManagerViewModel] refresh_wall_ms=\(elapsedMs)")
            #endif
        }

        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        var candidates: [(model: TTSModel, epoch: Int)] = []

        for model in TTSModel.all {
            if case .downloading = statuses[model.id] { continue }

            let epoch = beginEpoch(for: model.id)

            if isLikelyInstalled(model) {
                statuses[model.id] = .checking
                candidates.append((model: model, epoch: epoch))
            } else {
                statuses[model.id] = .notDownloaded
            }
        }

        guard !candidates.isEmpty else { return }
        let modelsDirectory = self.modelsDirectory

        let results: [(String, Int, Bool, Int)] = await Task.detached(priority: .utility) {
            candidates.map { candidate in
                let modelDir = candidate.model.installDirectory(in: modelsDirectory)
                let isComplete = candidate.model.isAvailable(in: modelsDirectory)
                let size = isComplete ? Self.directorySize(url: modelDir) : 0
                return (candidate.model.id, candidate.epoch, isComplete, size)
            }
        }.value

        for (id, epoch, isComplete, size) in results {
            guard isCurrentEpoch(epoch, for: id) else { continue }
            statuses[id] = isComplete ? .downloaded(sizeBytes: size) : .notDownloaded
        }
    }

    func isAvailable(_ model: TTSModel) -> Bool {
        switch statuses[model.id] {
        case .downloaded:
            return true
        case .downloading, .notDownloaded:
            return false
        case .checking, .error, .none:
            return model.isAvailable(in: modelsDirectory)
        }
    }

    func isLikelyInstalled(_ model: TTSModel) -> Bool {
        model.isAvailable(in: modelsDirectory, fileManager: fileManager)
    }

    func download(_ model: TTSModel) async {
        // Prevent double-downloads
        if case .downloading = statuses[model.id] { return }

        if UITestAutomationSupport.isStubBackendMode {
            await downloadStub(model)
            return
        }

        let epoch = beginEpoch(for: model.id)
        statuses[model.id] = .downloading(downloadedBytes: 0, totalBytes: nil)

        let targetDir = model.installDirectory(in: modelsDirectory)
        let modelsDirectory = self.modelsDirectory

        downloaders[model.id]?.cancel()
        downloaders.removeValue(forKey: model.id)
        downloadTasks[model.id]?.cancel()
        downloadTasks.removeValue(forKey: model.id)

        // Remove any partial directory from a previous failed attempt
        try? fileManager.removeItem(at: targetDir)

        // Ensure models directory exists (first-ever download)
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let downloader = HuggingFaceDownloader()
        downloaders[model.id] = downloader

        downloader.onProgress = { [weak self] bytesDownloaded, bytesTotal in
            Task { [weak self] in
                guard let self = self else { return }
                await self.publishDownloadProgressIfCurrent(
                    epoch: epoch,
                    modelID: model.id,
                    downloadedBytes: bytesDownloaded,
                    totalBytes: bytesTotal
                )
            }
        }

        let task = Task {
            do {
                try await downloader.downloadRepo(repo: model.huggingFaceRepo, to: targetDir)
                guard isCurrentEpoch(epoch, for: model.id) else { return }
                let finalizedDownload = await Task.detached(priority: .utility) { () -> (isComplete: Bool, size: Int) in
                    let isComplete = model.isAvailable(in: modelsDirectory)
                    let size = isComplete ? Self.directorySize(url: targetDir) : 0
                    return (isComplete, size)
                }.value
                guard finalizedDownload.isComplete else {
                    statuses[model.id] = .error(message: "Download incomplete")
                    try? fileManager.removeItem(at: targetDir)
                    return
                }
                statuses[model.id] = .downloaded(sizeBytes: finalizedDownload.size)
            } catch is CancellationError {
                // cancelDownload() already set status — no-op
            } catch let dlError as HuggingFaceDownloader.DownloadError {
                guard isCurrentEpoch(epoch, for: model.id) else { return }
                if case .cancelled = dlError {
                    // cancelDownload() already set status — no-op
                } else {
                    statuses[model.id] = .error(message: dlError.localizedDescription)
                    try? fileManager.removeItem(at: targetDir)
                }
            } catch {
                guard isCurrentEpoch(epoch, for: model.id) else { return }
                statuses[model.id] = .error(message: error.localizedDescription)
                try? fileManager.removeItem(at: targetDir)
            }
            guard isCurrentEpoch(epoch, for: model.id) else { return }
            downloaders.removeValue(forKey: model.id)
            downloadTasks.removeValue(forKey: model.id)
            lastProgressPublishTimes.removeValue(forKey: model.id)
        }
        downloadTasks[model.id] = task
    }

    func cancelDownload(_ model: TTSModel) {
        _ = beginEpoch(for: model.id)

        if UITestAutomationSupport.isStubBackendMode {
            stubDownloadTasks[model.id]?.cancel()
            stubDownloadTasks.removeValue(forKey: model.id)
            let targetDir = model.installDirectory(in: modelsDirectory)
            try? fileManager.removeItem(at: targetDir)
            statuses[model.id] = .notDownloaded
            return
        }

        // Stop URLSession tasks
        downloaders[model.id]?.cancel()
        downloaders.removeValue(forKey: model.id)

        // Cancel the Swift task
        downloadTasks[model.id]?.cancel()
        downloadTasks.removeValue(forKey: model.id)

        statuses[model.id] = .notDownloaded

        // Clean up partial download directory
        let targetDir = model.installDirectory(in: modelsDirectory)
        try? fileManager.removeItem(at: targetDir)
    }

    func delete(_ model: TTSModel) {
        _ = beginEpoch(for: model.id)

        if UITestAutomationSupport.isStubBackendMode {
            stubDownloadTasks[model.id]?.cancel()
            stubDownloadTasks.removeValue(forKey: model.id)
            let modelDir = model.installDirectory(in: modelsDirectory)
            try? fileManager.removeItem(at: modelDir)
            statuses[model.id] = .notDownloaded
            return
        }

        downloaders[model.id]?.cancel()
        downloaders.removeValue(forKey: model.id)
        downloadTasks[model.id]?.cancel()
        downloadTasks.removeValue(forKey: model.id)

        let modelDir = model.installDirectory(in: modelsDirectory)
        try? fileManager.removeItem(at: modelDir)
        statuses[model.id] = .notDownloaded
    }

    private func beginEpoch(for modelID: String) -> Int {
        let nextEpoch = (stateEpochs[modelID] ?? 0) + 1
        stateEpochs[modelID] = nextEpoch
        return nextEpoch
    }

    private func initialStatus(for model: TTSModel) -> ModelStatus {
        isLikelyInstalled(model) ? .checking : .notDownloaded
    }

    private func isCurrentEpoch(_ epoch: Int, for modelID: String) -> Bool {
        stateEpochs[modelID] == epoch
    }

    private nonisolated static func directorySize(url: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += size
            }
        }
        return total
    }

    private func downloadStub(_ model: TTSModel) async {
        let epoch = beginEpoch(for: model.id)
        let targetDir = model.installDirectory(in: modelsDirectory)

        stubDownloadTasks[model.id]?.cancel()
        stubDownloadTasks.removeValue(forKey: model.id)
        try? fileManager.removeItem(at: targetDir)
        statuses[model.id] = .downloading(downloadedBytes: 0, totalBytes: 3)

        let shouldFailOnce = UITestAutomationSupport.modelDownloadFailOnceIDs.contains(model.id)
        let task = Task { [weak self] in
            guard let self else { return }

            for step in 1...3 {
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled, self.isCurrentEpoch(epoch, for: model.id) else { return }
                self.statuses[model.id] = .downloading(downloadedBytes: Int64(step), totalBytes: 3)
            }

            if shouldFailOnce,
               UITestAutomationSupport.consumeFailOnceFlag(
                    namespace: "model-download-fail",
                    identifier: model.id,
                    appSupportDir: QwenVoiceApp.appSupportDir
               ) {
                guard !Task.isCancelled, self.isCurrentEpoch(epoch, for: model.id) else { return }
                self.statuses[model.id] = .error(message: "Simulated model download failure.")
                self.stubDownloadTasks.removeValue(forKey: model.id)
                return
            }

            for relativePath in model.requiredRelativePaths {
                let fileURL = targetDir.appendingPathComponent(relativePath)
                try? fileManager.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                fileManager.createFile(atPath: fileURL.path, contents: Data())
            }

            guard !Task.isCancelled, self.isCurrentEpoch(epoch, for: model.id) else { return }
            self.statuses[model.id] = .downloaded(sizeBytes: Self.directorySize(url: targetDir))
            self.stubDownloadTasks.removeValue(forKey: model.id)
        }
        stubDownloadTasks[model.id] = task
    }

    private func publishDownloadProgressIfCurrent(
        epoch: Int,
        modelID: String,
        downloadedBytes: Int64,
        totalBytes: Int64
    ) {
        guard isCurrentEpoch(epoch, for: modelID) else { return }
        guard case .downloading = statuses[modelID] else { return }

        // Throttle UI updates to ~10Hz to avoid excessive re-renders.
        let now = ContinuousClock.now
        if let lastPublish = lastProgressPublishTimes[modelID],
           now - lastPublish < .milliseconds(100) {
            return
        }
        lastProgressPublishTimes[modelID] = now

        statuses[modelID] = .downloading(
            downloadedBytes: downloadedBytes,
            totalBytes: totalBytes > 0 ? totalBytes : nil
        )
    }
}
