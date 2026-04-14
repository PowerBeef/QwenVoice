import Foundation

/// Manages model install state, repairability, download, and delete flows.
@MainActor
final class ModelManagerViewModel: ObservableObject {

    enum ModelStatus: Equatable {
        case checking
        case notDownloaded(message: String?)
        case downloading(downloadedBytes: Int64, totalBytes: Int64?)
        case repairAvailable(sizeBytes: Int, missingRequiredPaths: [String], message: String?)
        case downloaded(sizeBytes: Int)
    }

    @Published private(set) var statuses: [String: ModelStatus] = [:]
    @Published private(set) var modelInfoByID: [String: ModelInfo] = [:]

    private let fileManager: FileManager
    private let modelsDirectory: URL
    private weak var bridge: PythonBridge?
    private var downloaders: [String: HuggingFaceDownloader] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var stateEpochs: [String: Int] = [:]
    private var lastProgressPublishTimes: [String: ContinuousClock.Instant] = [:]
    private var refreshTask: Task<Void, Never>?
    private var lastFailureMessages: [String: String] = [:]
    private var stubDownloadTasks: [String: Task<Void, Never>] = [:]

    init(
        fileManager: FileManager = .default,
        modelsDirectory: URL = QwenVoiceApp.modelsDir
    ) {
        self.fileManager = fileManager
        self.modelsDirectory = modelsDirectory

        for model in TTSModel.all {
            let info = localModelInfo(for: model)
            modelInfoByID[model.id] = info
            statuses[model.id] = status(for: info, failureMessage: nil)
        }
    }

    func refresh(using bridge: PythonBridge? = nil) async {
        if let bridge {
            self.bridge = bridge
        }

        if let refreshTask {
            await refreshTask.value
            return
        }

        let currentBridge = self.bridge
        let task = Task { @MainActor in
            let interval = AppPerformanceSignposts.begin("Model Status Refresh")
            let wallStart = DispatchTime.now().uptimeNanoseconds
            await performRefresh(using: currentBridge)
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

    func info(for model: TTSModel) -> ModelInfo {
        modelInfoByID[model.id] ?? localModelInfo(for: model)
    }

    func isAvailable(_ model: TTSModel) -> Bool {
        info(for: model).isAvailable
    }

    func isLikelyInstalled(_ model: TTSModel) -> Bool {
        let snapshot = info(for: model)
        return snapshot.downloaded
    }

    func primaryActionTitle(for model: TTSModel) -> String? {
        guard !isAvailable(model) else { return nil }
        return info(for: model).requiresRepair ? "Repair Model" : "Download Model"
    }

    func recoveryDetail(for model: TTSModel) -> String {
        let snapshot = info(for: model)
        if snapshot.requiresRepair {
            if !snapshot.missingRequiredPaths.isEmpty {
                return "Some required files are missing. Repair \(model.name) to finish installing it."
            }
            return "The local model files are incomplete. Repair \(model.name) to keep using \(model.mode.displayName)."
        }
        return "Install \(model.name) to enable \(model.mode.displayName)."
    }

    func download(_ model: TTSModel, using bridge: PythonBridge? = nil) async {
        if let bridge {
            self.bridge = bridge
        }

        if case .downloading = statuses[model.id] { return }

        if UITestAutomationSupport.isStubBackendMode {
            await downloadStub(model)
            return
        }

        let epoch = beginEpoch(for: model.id)
        lastFailureMessages.removeValue(forKey: model.id)
        statuses[model.id] = .downloading(downloadedBytes: 0, totalBytes: nil)

        let targetDir = model.installDirectory(in: modelsDirectory)
        let modelsDirectory = self.modelsDirectory

        downloaders[model.id]?.cancel()
        downloaders.removeValue(forKey: model.id)
        downloadTasks[model.id]?.cancel()
        downloadTasks.removeValue(forKey: model.id)

        // Repair and re-download always start from a clean directory.
        try? fileManager.removeItem(at: targetDir)
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let downloader = HuggingFaceDownloader(progressHandler: { [weak self] bytesDownloaded, bytesTotal in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.publishDownloadProgressIfCurrent(
                    epoch: epoch,
                    modelID: model.id,
                    downloadedBytes: bytesDownloaded,
                    totalBytes: bytesTotal
                )
            }
        })
        downloaders[model.id] = downloader

        let task = Task {
            do {
                try await downloader.downloadRepo(repo: model.huggingFaceRepo, to: targetDir)
                guard isCurrentEpoch(epoch, for: model.id) else { return }
                let postDownloadSnapshot = localModelInfo(for: model)
                if !postDownloadSnapshot.complete {
                    lastFailureMessages[model.id] = "Download finished, but required model files are still missing."
                }
                await handleMutationCompletion(for: model.id)
            } catch is CancellationError {
                guard isCurrentEpoch(epoch, for: model.id) else { return }
                await handleMutationCompletion(for: model.id)
            } catch let dlError as HuggingFaceDownloader.DownloadError {
                guard isCurrentEpoch(epoch, for: model.id) else { return }
                switch dlError {
                case .cancelled:
                    lastFailureMessages.removeValue(forKey: model.id)
                default:
                    lastFailureMessages[model.id] = dlError.localizedDescription
                }
                await handleMutationCompletion(for: model.id)
            } catch {
                guard isCurrentEpoch(epoch, for: model.id) else { return }
                lastFailureMessages[model.id] = error.localizedDescription
                await handleMutationCompletion(for: model.id)
            }
        }
        downloadTasks[model.id] = task
    }

    func cancelDownload(_ model: TTSModel) {
        _ = beginEpoch(for: model.id)

        if UITestAutomationSupport.isStubBackendMode {
            stubDownloadTasks[model.id]?.cancel()
            stubDownloadTasks.removeValue(forKey: model.id)
            Task {
                await handleMutationCompletion(for: model.id)
            }
            return
        }

        downloaders[model.id]?.cancel()
        downloaders.removeValue(forKey: model.id)
        downloadTasks[model.id]?.cancel()
        downloadTasks.removeValue(forKey: model.id)

        Task {
            await handleMutationCompletion(for: model.id)
        }
    }

    func delete(_ model: TTSModel) {
        _ = beginEpoch(for: model.id)

        if UITestAutomationSupport.isStubBackendMode {
            stubDownloadTasks[model.id]?.cancel()
            stubDownloadTasks.removeValue(forKey: model.id)
            let modelDir = model.installDirectory(in: modelsDirectory)
            try? fileManager.removeItem(at: modelDir)
            lastFailureMessages.removeValue(forKey: model.id)
            modelInfoByID[model.id] = localModelInfo(for: model)
            statuses[model.id] = .notDownloaded(message: nil)
            return
        }

        downloaders[model.id]?.cancel()
        downloaders.removeValue(forKey: model.id)
        downloadTasks[model.id]?.cancel()
        downloadTasks.removeValue(forKey: model.id)

        let modelDir = model.installDirectory(in: modelsDirectory)
        try? fileManager.removeItem(at: modelDir)
        lastFailureMessages.removeValue(forKey: model.id)

        Task {
            await handleMutationCompletion(for: model.id)
        }
    }

    private func performRefresh(using bridge: PythonBridge?) async {
        let snapshots = await fetchSnapshots(using: bridge)
        applySnapshots(snapshots)
    }

    private func fetchSnapshots(using bridge: PythonBridge?) async -> [ModelInfo] {
        if let bridge, bridge.isStubBackendMode || bridge.isReady {
            do {
                return try await bridge.getModelInfo()
            } catch {
                #if DEBUG
                print("[ModelManagerViewModel] backend refresh fallback: \(error.localizedDescription)")
                #endif
            }
        }

        return TTSModel.all.map(localModelInfo)
    }

    private func applySnapshots(_ snapshots: [ModelInfo]) {
        let snapshotByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        modelInfoByID = snapshotByID

        for model in TTSModel.all {
            let id = model.id
            guard case .downloading = statuses[id] else {
                let snapshot = snapshotByID[id] ?? localModelInfo(for: model)
                let failureMessage = lastFailureMessages[id]
                if snapshot.complete {
                    lastFailureMessages.removeValue(forKey: id)
                }
                statuses[id] = status(for: snapshot, failureMessage: failureMessage)
                continue
            }
        }
    }

    private func status(for info: ModelInfo, failureMessage: String?) -> ModelStatus {
        if info.complete {
            return .downloaded(sizeBytes: info.sizeBytes)
        }
        if info.requiresRepair {
            return .repairAvailable(
                sizeBytes: info.sizeBytes,
                missingRequiredPaths: info.missingRequiredPaths,
                message: failureMessage
            )
        }
        return .notDownloaded(message: failureMessage)
    }

    private func handleMutationCompletion(for modelID: String) async {
        downloaders.removeValue(forKey: modelID)
        downloadTasks.removeValue(forKey: modelID)
        stubDownloadTasks.removeValue(forKey: modelID)
        lastProgressPublishTimes.removeValue(forKey: modelID)
        statuses[modelID] = .checking
        await refresh()
    }

    private func localModelInfo(for model: TTSModel) -> ModelInfo {
        let modelDirectory = model.installDirectory(in: modelsDirectory)
        let rootExists = fileManager.fileExists(atPath: modelDirectory.path)
        let missingRequiredPaths = rootExists
            ? model.requiredRelativePaths.filter {
                !fileManager.fileExists(atPath: modelDirectory.appendingPathComponent($0).path)
            }
            : []
        let complete = rootExists && missingRequiredPaths.isEmpty
        let sizeBytes = rootExists ? Self.directorySize(url: modelDirectory) : 0

        return ModelInfo(
            id: model.id,
            name: model.name,
            folder: model.folder,
            mode: model.mode,
            tier: model.tier,
            outputSubfolder: model.outputSubfolder,
            huggingFaceRepo: model.huggingFaceRepo,
            requiredRelativePaths: model.requiredRelativePaths,
            resolvedPath: rootExists ? modelDirectory.path : nil,
            downloaded: rootExists,
            complete: complete,
            repairable: rootExists && !complete,
            missingRequiredPaths: missingRequiredPaths,
            sizeBytes: sizeBytes,
            mlxAudioVersion: nil,
            supportsStreaming: true,
            supportsPreparedClone: model.mode == .clone,
            supportsCloneStreaming: model.mode == .clone,
            supportsBatch: true
        )
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

    private func downloadStub(_ model: TTSModel) async {
        let epoch = beginEpoch(for: model.id)
        let targetDir = model.installDirectory(in: modelsDirectory)

        stubDownloadTasks[model.id]?.cancel()
        stubDownloadTasks.removeValue(forKey: model.id)
        try? fileManager.removeItem(at: targetDir)
        lastFailureMessages.removeValue(forKey: model.id)
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
                let partialPath = targetDir.appendingPathComponent(model.requiredRelativePaths.first ?? "partial.bin")
                try? self.fileManager.createDirectory(
                    at: partialPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                self.fileManager.createFile(atPath: partialPath.path, contents: Data())
                guard !Task.isCancelled, self.isCurrentEpoch(epoch, for: model.id) else { return }
                self.lastFailureMessages[model.id] = "Simulated model download failure."
                await self.handleMutationCompletion(for: model.id)
                return
            }

            for relativePath in model.requiredRelativePaths {
                let fileURL = targetDir.appendingPathComponent(relativePath)
                try? self.fileManager.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                self.fileManager.createFile(atPath: fileURL.path, contents: Data())
            }

            guard !Task.isCancelled, self.isCurrentEpoch(epoch, for: model.id) else { return }
            await self.handleMutationCompletion(for: model.id)
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
