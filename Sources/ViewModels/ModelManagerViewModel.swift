import Foundation
import QwenVoiceCore

/// Manages model install state, repairability, download, and delete flows.
@MainActor
final class ModelManagerViewModel: ObservableObject {

    struct DownloadProgress: Equatable, Sendable {
        enum Phase: String, Equatable, Sendable {
            case downloading
            case interrupted
            case resuming
            case verifying
            case installing
        }

        let downloadedBytes: Int64
        let totalBytes: Int64?
        let completedFiles: Int
        let totalFiles: Int?
        let bytesPerSecond: Int64?
        let isStalled: Bool
        let phase: Phase

        static let initial = DownloadProgress(
            downloadedBytes: 0,
            totalBytes: nil,
            completedFiles: 0,
            totalFiles: nil,
            bytesPerSecond: nil,
            isStalled: false,
            phase: .downloading
        )
    }

    enum ModelStatus: Equatable {
        case checking
        case notDownloaded(message: String?)
        case downloading(progress: DownloadProgress)
        case repairAvailable(sizeBytes: Int, missingRequiredPaths: [String], message: String?)
        case downloaded(sizeBytes: Int)
    }

    private struct InstallMetadata: Codable, Equatable {
        let schemaVersion: Int
        let modelID: String
        let huggingFaceRepo: String
        let huggingFaceRevision: String?
        let completedAtUTC: String
        let resolvedPath: String
        let sizeBytes: Int
        let requiredRelativePaths: [String]
        let downloadedRelativePaths: [String]
        let missingRequiredPaths: [String]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case modelID = "model_id"
            case huggingFaceRepo = "hugging_face_repo"
            case huggingFaceRevision = "hugging_face_revision"
            case completedAtUTC = "completed_at_utc"
            case resolvedPath = "resolved_path"
            case sizeBytes = "size_bytes"
            case requiredRelativePaths = "required_relative_paths"
            case downloadedRelativePaths = "downloaded_relative_paths"
            case missingRequiredPaths = "missing_required_paths"
        }
    }

    private nonisolated static let installMetadataFilename = ".qwenvoice-install-metadata.json"

    @Published private(set) var statuses: [String: ModelStatus] = [:]
    @Published private(set) var modelInfoByID: [String: ModelInfo] = [:]
    @Published private(set) var activeVariantRevision = 0

    private let fileManager: FileManager
    private let modelsDirectory: URL
    /// The user's Mac memory tier, computed once at init and
    /// surfaced for UI surfaces that frame variant choice
    /// (e.g. the Models panel's intro line and per-row caption).
    let deviceClass: NativeDeviceMemoryClass
    private var downloaders: [String: HuggingFaceDownloader] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var stateEpochs: [String: Int] = [:]
    private var lastProgressPublishTimes: [String: ContinuousClock.Instant] = [:]
    private var refreshTask: Task<Void, Never>?
    private var lastFailureMessages: [String: String] = [:]

    init(
        fileManager: FileManager = .default,
        modelsDirectory: URL = QwenVoiceApp.modelsDir,
        deviceClass: NativeDeviceMemoryClass = NativeMemoryPolicyResolver.deviceClass()
    ) {
        self.fileManager = fileManager
        self.modelsDirectory = modelsDirectory
        self.deviceClass = deviceClass

        for model in TTSModel.all {
            let info = localModelInfo(for: model)
            modelInfoByID[model.id] = info
            statuses[model.id] = status(for: info, failureMessage: nil)
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

    func isActive(_ model: TTSModel) -> Bool {
        TTSModel.model(for: model.mode)?.id == model.id
    }

    /// Returns the Speed and Quality variants for a generation
    /// mode in display order. Either side can be `nil` if the
    /// manifest doesn't include that variant kind for the mode
    /// (today every mode has both; this stays defensive in case
    /// future contract changes drop one). Used by the Models tab
    /// to render both variants on a single row.
    func pairedVariants(
        for mode: GenerationMode
    ) -> (speed: TTSModel?, quality: TTSModel?) {
        let modelsForMode = TTSModel.all.filter { $0.mode == mode }
        let speed = modelsForMode.first { $0.variantKind == .speed }
        let quality = modelsForMode.first { $0.variantKind == .quality }
        return (speed, quality)
    }

    /// `true` when running this variant on the current Mac is
    /// likely to overrun memory and either fail or thrash badly.
    /// Today the only risky combination is the Quality (8-bit)
    /// variant on `.floor8GBMac`. The cached `deviceClass` is
    /// computed once at init from `ProcessInfo.physicalMemory`,
    /// so this lookup stays cheap. If we add a
    /// `recommendedMemoryGB` field to the manifest later, this
    /// is the single seam to extend.
    func isHardwareRisky(_ model: TTSModel) -> Bool {
        guard model.variantKind == .quality else { return false }
        return deviceClass == .floor8GBMac
    }

    /// Localized "1.6 GB" / "3.2 GB" string for the Models row's
    /// size column. Source of truth depends on install state:
    ///   * `.downloaded` / `.repairAvailable` use the resolved
    ///     `info.sizeBytes` (real on-disk size).
    ///   * `.notDownloaded` falls back to
    ///     `model.estimatedDownloadBytes` from the manifest.
    ///   * `.downloading` is handled by the row's progress
    ///     subview, not this column; returns `nil`.
    ///   * `.checking` returns `nil` (we don't yet know).
    /// Returns `nil` when no source has a value, so the UI can
    /// elide the column instead of rendering an em-dash.
    func sizeText(for model: TTSModel) -> String? {
        switch statuses[model.id] {
        case .downloaded(let sizeBytes), .repairAvailable(let sizeBytes, _, _):
            guard sizeBytes > 0 else { return nil }
            return Self.formattedFileSize(Int64(sizeBytes))
        case .notDownloaded:
            guard let estimated = model.estimatedDownloadBytes, estimated > 0 else {
                return nil
            }
            return Self.formattedFileSize(estimated)
        case .downloading, .checking, .none:
            return nil
        }
    }

    private nonisolated static func formattedFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    func use(_ model: TTSModel) {
        guard let variantID = model.variantID else { return }
        MacModelVariantPreferences.setSelectedVariantID(variantID, for: model.mode)
        activeVariantRevision += 1
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

    func download(_ model: TTSModel) async {
        if let existingTask = downloadTasks[model.id] {
            await existingTask.value
            return
        }

        let epoch = beginEpoch(for: model.id)
        lastFailureMessages.removeValue(forKey: model.id)
        statuses[model.id] = .downloading(progress: .initial)

        let targetDir = model.installDirectory(in: modelsDirectory)
        let modelsDirectory = self.modelsDirectory

        downloaders[model.id]?.cancel()
        downloaders.removeValue(forKey: model.id)
        downloadTasks[model.id]?.cancel()
        downloadTasks.removeValue(forKey: model.id)

        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        removeInstallMetadata(for: model)

        let downloader = HuggingFaceDownloader(progressHandler: { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.publishDownloadProgressIfCurrent(
                    epoch: epoch,
                    modelID: model.id,
                    progress: progress
                )
            }
        })
        downloaders[model.id] = downloader

        let task = Task {
            do {
                try await downloader.downloadRepo(
                    repo: model.huggingFaceRepo,
                    revision: model.huggingFaceRevision ?? "main",
                    to: targetDir
                )
                guard isCurrentEpoch(epoch, for: model.id) else { return }
                let postDownloadSnapshot = localModelInfo(for: model)
                if !postDownloadSnapshot.complete {
                    lastFailureMessages[model.id] = "Download finished, but required model files are still missing."
                } else {
                    persistInstallMetadata(for: model, snapshot: postDownloadSnapshot)
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

        downloaders[model.id]?.cancel()
        downloaders.removeValue(forKey: model.id)
        downloadTasks[model.id]?.cancel()
        downloadTasks.removeValue(forKey: model.id)

        let modelDir = model.installDirectory(in: modelsDirectory)
        try? fileManager.removeItem(at: modelDir)
        lastFailureMessages.removeValue(forKey: model.id)
        removeInstallMetadata(for: model)

        // Audit Finding B (May 2026 dual-variant cleanup): if the
        // user just deleted their currently-active variant, the
        // variant preference is now stale. Without this fixup, the
        // generate flow would compute `activeModel = <deleted variant>`,
        // `isModelAvailable = false`, and silently disable the
        // Generate button — the user has no obvious way to recover
        // short of clicking Use on the surviving variant.
        //
        // Recovery policy:
        //   1. If another variant of the same mode is still on
        //      disk, reassign the preference to it (smoothest UX —
        //      Generate stays enabled).
        //   2. Otherwise clear the preference so the
        //      hardware-recommended variant becomes Active again
        //      (its row will show as not-yet-installed but the
        //      readiness banner now points the user at a sensible
        //      next step).
        reconcileActiveVariantAfterDeletion(of: model)

        Task {
            await handleMutationCompletion(for: model.id)
        }
    }

    private func reconcileActiveVariantAfterDeletion(of model: TTSModel) {
        guard let deletedVariantID = model.variantID else { return }

        let preferenceVariantID = MacModelVariantPreferences.selectedVariantID(
            for: model.mode,
            defaultVariantID: nil
        )
        guard preferenceVariantID == deletedVariantID else { return }

        // Find a sibling variant of the same mode that is still
        // installed (folder exists AND required files complete).
        let siblingInstalled = TTSModel.all.first { candidate in
            candidate.mode == model.mode
                && candidate.id != model.id
                && candidate.variantID != nil
                && candidate.isAvailable(in: modelsDirectory, fileManager: fileManager)
        }

        if let siblingInstalled, let siblingVariantID = siblingInstalled.variantID {
            MacModelVariantPreferences.setSelectedVariantID(siblingVariantID, for: model.mode)
        } else {
            MacModelVariantPreferences.clearSelectedVariantID(for: model.mode)
        }
        activeVariantRevision += 1
    }

    private func performRefresh() async {
        let snapshots = fetchSnapshots()
        applySnapshots(snapshots)
    }

    private func fetchSnapshots() -> [ModelInfo] {
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
                    persistInstallMetadata(for: model, snapshot: snapshot)
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
        lastProgressPublishTimes.removeValue(forKey: modelID)
        if let model = TTSModel.model(id: modelID) {
            applyLocalSnapshot(for: model)
        } else {
            statuses[modelID] = .checking
        }
        scheduleRefreshIfPossible()
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

    private func applyLocalSnapshot(for model: TTSModel) {
        let snapshot = localModelInfo(for: model)
        modelInfoByID[model.id] = snapshot
        if snapshot.complete {
            lastFailureMessages.removeValue(forKey: model.id)
            persistInstallMetadata(for: model, snapshot: snapshot)
        } else if !snapshot.downloaded {
            removeInstallMetadata(for: model)
        }
        statuses[model.id] = status(
            for: snapshot,
            failureMessage: lastFailureMessages[model.id]
        )
    }

    private func scheduleRefreshIfPossible() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refresh()
        }
    }

    private func installMetadataURL(for model: TTSModel) -> URL {
        model.installDirectory(in: modelsDirectory)
            .appendingPathComponent(Self.installMetadataFilename, isDirectory: false)
    }

    private func persistInstallMetadata(for model: TTSModel, snapshot: ModelInfo) {
        guard snapshot.complete, let resolvedPath = snapshot.resolvedPath else { return }

        let metadata = InstallMetadata(
            schemaVersion: 1,
            modelID: model.id,
            huggingFaceRepo: model.huggingFaceRepo,
            huggingFaceRevision: model.huggingFaceRevision,
            completedAtUTC: ISO8601DateFormatter().string(from: Date()),
            resolvedPath: resolvedPath,
            sizeBytes: snapshot.sizeBytes,
            requiredRelativePaths: model.requiredRelativePaths,
            downloadedRelativePaths: downloadedRelativePaths(in: model.installDirectory(in: modelsDirectory)),
            missingRequiredPaths: snapshot.missingRequiredPaths
        )

        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: installMetadataURL(for: model), options: .atomic)
    }

    private func removeInstallMetadata(for model: TTSModel) {
        try? fileManager.removeItem(at: installMetadataURL(for: model))
    }

    private func downloadedRelativePaths(in directory: URL) -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var paths: [String] = []
        for case let fileURL as URL in enumerator {
            guard let isRegularFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                  isRegularFile == true else {
                continue
            }
            let relativePath = fileURL.path.replacingOccurrences(of: directory.path + "/", with: "")
            paths.append(relativePath)
        }
        return paths.sorted()
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
            if fileURL.lastPathComponent == installMetadataFilename {
                continue
            }
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += size
            }
        }
        return total
    }

    private func publishDownloadProgressIfCurrent(
        epoch: Int,
        modelID: String,
        progress: HuggingFaceDownloader.RepositoryProgress
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
            progress: DownloadProgress(
                downloadedBytes: progress.downloadedBytes,
                totalBytes: progress.totalBytes > 0 ? progress.totalBytes : nil,
                completedFiles: progress.completedFiles,
                totalFiles: progress.totalFiles > 0 ? progress.totalFiles : nil,
                bytesPerSecond: progress.bytesPerSecond,
                isStalled: progress.isStalled,
                phase: DownloadProgress.Phase(progress.phase)
            )
        )
    }
}

private extension ModelManagerViewModel.DownloadProgress.Phase {
    init(_ phase: HuggingFaceDownloader.DownloadPhase) {
        switch phase {
        case .downloading:
            self = .downloading
        case .interrupted:
            self = .interrupted
        case .resuming:
            self = .resuming
        case .verifying:
            self = .verifying
        case .installing:
            self = .installing
        }
    }
}
