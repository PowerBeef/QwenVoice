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
    private var downloaders: [String: HuggingFaceDownloader] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var stateEpochs: [String: Int] = [:]

    func refresh() async {
        let modelsDir = QwenVoiceApp.modelsDir
        let fileManager = FileManager.default
        var candidates: [(model: TTSModel, epoch: Int)] = []

        for model in TTSModel.all {
            if case .downloading = statuses[model.id] { continue }
            if case .error = statuses[model.id] { continue }

            let epoch = beginEpoch(for: model.id)
            let modelDir = model.installDirectory(in: modelsDir)

            if fileManager.fileExists(atPath: modelDir.path) {
                statuses[model.id] = .checking
                candidates.append((model: model, epoch: epoch))
            } else {
                statuses[model.id] = .notDownloaded
            }
        }

        guard !candidates.isEmpty else { return }

        let results: [(String, Int, Bool, Int)] = await Task.detached(priority: .utility) {
            candidates.map { candidate in
                let modelDir = candidate.model.installDirectory(in: modelsDir)
                let isComplete = candidate.model.isAvailable(in: modelsDir)
                let size = isComplete ? Self.directorySize(url: modelDir) : 0
                return (candidate.model.id, candidate.epoch, isComplete, size)
            }
        }.value

        for (id, epoch, isComplete, size) in results {
            guard isCurrentEpoch(epoch, for: id) else { continue }
            statuses[id] = isComplete ? .downloaded(sizeBytes: size) : .notDownloaded
        }
    }

    func download(_ model: TTSModel) async {
        // Prevent double-downloads
        if case .downloading = statuses[model.id] { return }

        let epoch = beginEpoch(for: model.id)
        statuses[model.id] = .downloading(downloadedBytes: 0, totalBytes: nil)

        let modelsDir = QwenVoiceApp.modelsDir
        let targetDir = model.installDirectory(in: modelsDir)

        downloaders[model.id]?.cancel()
        downloaders.removeValue(forKey: model.id)
        downloadTasks[model.id]?.cancel()
        downloadTasks.removeValue(forKey: model.id)

        // Remove any partial directory from a previous failed attempt
        try? FileManager.default.removeItem(at: targetDir)

        // Ensure models directory exists (first-ever download)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let downloader = HuggingFaceDownloader()
        downloaders[model.id] = downloader

        downloader.onProgress = { [weak self] bytesDownloaded, bytesTotal in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.isCurrentEpoch(epoch, for: model.id) else { return }
                guard case .downloading = self.statuses[model.id] else { return }
                self.statuses[model.id] = .downloading(
                    downloadedBytes: bytesDownloaded,
                    totalBytes: bytesTotal > 0 ? bytesTotal : nil
                )
            }
        }

        let task = Task {
            do {
                try await downloader.downloadRepo(repo: model.huggingFaceRepo, to: targetDir)
                guard isCurrentEpoch(epoch, for: model.id) else { return }
                guard model.isAvailable(in: modelsDir) else {
                    statuses[model.id] = .error(message: "Download incomplete")
                    try? FileManager.default.removeItem(at: targetDir)
                    return
                }
                let size = Self.directorySize(url: targetDir)
                statuses[model.id] = .downloaded(sizeBytes: size)
            } catch is CancellationError {
                // cancelDownload() already set status — no-op
            } catch let dlError as HuggingFaceDownloader.DownloadError {
                guard isCurrentEpoch(epoch, for: model.id) else { return }
                if case .cancelled = dlError {
                    // cancelDownload() already set status — no-op
                } else {
                    statuses[model.id] = .error(message: dlError.localizedDescription)
                    try? FileManager.default.removeItem(at: targetDir)
                }
            } catch {
                guard isCurrentEpoch(epoch, for: model.id) else { return }
                statuses[model.id] = .error(message: error.localizedDescription)
                try? FileManager.default.removeItem(at: targetDir)
            }
            guard isCurrentEpoch(epoch, for: model.id) else { return }
            downloaders.removeValue(forKey: model.id)
            downloadTasks.removeValue(forKey: model.id)
        }
        downloadTasks[model.id] = task
    }

    func cancelDownload(_ model: TTSModel) {
        _ = beginEpoch(for: model.id)

        // Stop URLSession tasks
        downloaders[model.id]?.cancel()
        downloaders.removeValue(forKey: model.id)

        // Cancel the Swift task
        downloadTasks[model.id]?.cancel()
        downloadTasks.removeValue(forKey: model.id)

        statuses[model.id] = .notDownloaded

        // Clean up partial download directory
        let targetDir = model.installDirectory(in: QwenVoiceApp.modelsDir)
        try? FileManager.default.removeItem(at: targetDir)
    }

    func delete(_ model: TTSModel) {
        _ = beginEpoch(for: model.id)
        downloaders[model.id]?.cancel()
        downloaders.removeValue(forKey: model.id)
        downloadTasks[model.id]?.cancel()
        downloadTasks.removeValue(forKey: model.id)

        let modelDir = model.installDirectory(in: QwenVoiceApp.modelsDir)
        try? FileManager.default.removeItem(at: modelDir)
        statuses[model.id] = .notDownloaded
    }

    private func beginEpoch(for modelID: String) -> Int {
        let nextEpoch = (stateEpochs[modelID] ?? 0) + 1
        stateEpochs[modelID] = nextEpoch
        return nextEpoch
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
}
