import Foundation

/// Manages model download/delete state for ModelsView.
@MainActor
final class ModelManagerViewModel: ObservableObject {

    enum ModelStatus: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded(sizeBytes: Int)
        case error(message: String)
    }

    @Published var statuses: [String: ModelStatus] = [:]
    @Published var hasRefreshed = false

    private var downloaders: [String: HuggingFaceDownloader] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    func refresh() async {
        let modelsDir = QwenVoiceApp.modelsDir
        let models = TTSModel.all

        // Phase 1: Quick existence check (synchronous — instant)
        var existingModelIDs: [String] = []
        for model in models {
            if case .downloading = statuses[model.id] { continue }
            let modelDir = modelsDir.appendingPathComponent(model.folder)
            if FileManager.default.fileExists(atPath: modelDir.path) {
                existingModelIDs.append(model.id)
                statuses[model.id] = .downloaded(sizeBytes: model.estimatedSizeBytes)
            } else {
                statuses[model.id] = .notDownloaded
            }
        }
        hasRefreshed = true  // UI unblocks here — cards appear instantly

        // Phase 2: Compute real sizes in background, apply threshold
        guard !existingModelIDs.isEmpty else { return }
        let ids = existingModelIDs
        let sizes: [(String, Int, Int)] = await Task.detached {
            ids.compactMap { id in
                guard let model = models.first(where: { $0.id == id }) else { return nil }
                let modelDir = modelsDir.appendingPathComponent(model.folder)
                let size = Self.directorySize(url: modelDir)
                return (id, size, model.estimatedSizeBytes / 2)
            }
        }.value

        for (id, size, threshold) in sizes {
            if case .downloaded = statuses[id] {
                if size >= threshold {
                    statuses[id] = .downloaded(sizeBytes: size)
                } else {
                    statuses[id] = .notDownloaded
                }
            }
        }
    }

    func download(_ model: TTSModel) async {
        // Prevent double-downloads
        if case .downloading = statuses[model.id] { return }

        statuses[model.id] = .downloading(progress: 0)

        let modelsDir = QwenVoiceApp.modelsDir
        let targetDir = modelsDir.appendingPathComponent(model.folder)

        // Remove any partial directory from a previous failed attempt
        try? FileManager.default.removeItem(at: targetDir)

        // Ensure models directory exists (first-ever download)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let downloader = HuggingFaceDownloader()
        downloaders[model.id] = downloader

        downloader.onProgress = { [weak self] bytesDownloaded, bytesTotal in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard case .downloading = self.statuses[model.id] else { return }
                let progress = bytesTotal > 0 ? Double(bytesDownloaded) / Double(bytesTotal) : 0
                self.statuses[model.id] = .downloading(progress: progress)
            }
        }

        let task = Task {
            do {
                try await downloader.downloadRepo(repo: model.huggingFaceRepo, to: targetDir)
                let size = Self.directorySize(url: targetDir)
                statuses[model.id] = .downloaded(sizeBytes: size)
            } catch is CancellationError {
                // cancelDownload() already set status — no-op
            } catch let dlError as HuggingFaceDownloader.DownloadError {
                if case .cancelled = dlError {
                    // cancelDownload() already set status — no-op
                } else {
                    statuses[model.id] = .error(message: dlError.localizedDescription)
                    try? FileManager.default.removeItem(at: targetDir)
                }
            } catch {
                statuses[model.id] = .error(message: error.localizedDescription)
                try? FileManager.default.removeItem(at: targetDir)
            }
            downloaders.removeValue(forKey: model.id)
            downloadTasks.removeValue(forKey: model.id)
        }
        downloadTasks[model.id] = task
    }

    func cancelDownload(_ model: TTSModel) {
        // Stop URLSession tasks
        downloaders[model.id]?.cancel()
        downloaders.removeValue(forKey: model.id)

        // Cancel the Swift task
        downloadTasks[model.id]?.cancel()
        downloadTasks.removeValue(forKey: model.id)

        statuses[model.id] = .notDownloaded

        // Clean up partial download directory
        let targetDir = QwenVoiceApp.modelsDir.appendingPathComponent(model.folder)
        try? FileManager.default.removeItem(at: targetDir)
    }

    func delete(_ model: TTSModel) {
        let modelDir = QwenVoiceApp.modelsDir.appendingPathComponent(model.folder)
        try? FileManager.default.removeItem(at: modelDir)
        statuses[model.id] = .notDownloaded
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
