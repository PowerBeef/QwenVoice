import Foundation
import QwenVoiceCore

struct IOSModelDeliverySnapshot: Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case downloading
        case interrupted
        case resuming
        case restarting
        case paused
        case verifying
        case installing
        case installed
        case deleting
        case deleted
        case failed
    }

    let modelID: String
    let phase: Phase
    let downloadedBytes: Int64
    let totalBytes: Int64?
    let estimatedBytes: Int64?
    let message: String?
    /// Monotonic token so the view model can ignore stale progress after cancel/fail.
    let operationGeneration: UInt64
}

private struct IOSPersistedModelInstallState: Codable, Sendable {
    let modelID: String
    let artifactVersion: String
    let stagingDirectoryPath: String
    let catalogEntry: IOSModelCatalogEntry
    let pendingRelativePaths: [String]
    let currentRelativePath: String?
    let completedBytes: Int64
    let totalBytes: Int64
    let currentFilePartialBytes: Int64
    let currentFileLiveBytes: Int64
    let currentFileRetryCount: Int
    let currentResumeDataPath: String?
    let currentPhase: IOSModelDeliverySnapshot.Phase

    private enum CodingKeys: String, CodingKey {
        case modelID
        case artifactVersion
        case stagingDirectoryPath
        case catalogEntry
        case pendingRelativePaths
        case currentRelativePath
        case completedBytes
        case totalBytes
        case currentFilePartialBytes
        case currentFileLiveBytes
        case currentFileRetryCount
        case currentResumeDataPath
        case currentPhase
    }

    init(
        modelID: String,
        artifactVersion: String,
        stagingDirectoryPath: String,
        catalogEntry: IOSModelCatalogEntry,
        pendingRelativePaths: [String],
        currentRelativePath: String?,
        completedBytes: Int64,
        totalBytes: Int64,
        currentFilePartialBytes: Int64 = 0,
        currentFileLiveBytes: Int64 = 0,
        currentFileRetryCount: Int,
        currentResumeDataPath: String?,
        currentPhase: IOSModelDeliverySnapshot.Phase
    ) {
        self.modelID = modelID
        self.artifactVersion = artifactVersion
        self.stagingDirectoryPath = stagingDirectoryPath
        self.catalogEntry = catalogEntry
        self.pendingRelativePaths = pendingRelativePaths
        self.currentRelativePath = currentRelativePath
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.currentFilePartialBytes = currentFilePartialBytes
        self.currentFileLiveBytes = currentFileLiveBytes
        self.currentFileRetryCount = currentFileRetryCount
        self.currentResumeDataPath = currentResumeDataPath
        self.currentPhase = currentPhase
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modelID = try container.decode(String.self, forKey: .modelID)
        self.artifactVersion = try container.decode(String.self, forKey: .artifactVersion)
        self.stagingDirectoryPath = try container.decode(String.self, forKey: .stagingDirectoryPath)
        self.catalogEntry = try container.decode(IOSModelCatalogEntry.self, forKey: .catalogEntry)
        self.pendingRelativePaths = try container.decode([String].self, forKey: .pendingRelativePaths)
        self.currentRelativePath = try container.decodeIfPresent(String.self, forKey: .currentRelativePath)
        self.completedBytes = try container.decode(Int64.self, forKey: .completedBytes)
        self.totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
        self.currentFilePartialBytes = try container.decodeIfPresent(Int64.self, forKey: .currentFilePartialBytes) ?? 0
        self.currentFileLiveBytes = try container.decodeIfPresent(Int64.self, forKey: .currentFileLiveBytes) ?? 0
        self.currentFileRetryCount = try container.decodeIfPresent(Int.self, forKey: .currentFileRetryCount) ?? 0
        self.currentResumeDataPath = try container.decodeIfPresent(String.self, forKey: .currentResumeDataPath)
        self.currentPhase = try container.decodeIfPresent(IOSModelDeliverySnapshot.Phase.self, forKey: .currentPhase) ?? .downloading
    }
}

private struct IOSModelDeliveryStateMachine {
    static func initialInstall(
        model: ModelDescriptor,
        entry: IOSModelCatalogEntry,
        stagingRoot: URL,
        totalBytes: Int64
    ) -> IOSPersistedModelInstallState {
        IOSPersistedModelInstallState(
            modelID: model.id,
            artifactVersion: model.artifactVersion,
            stagingDirectoryPath: stagingRoot.path,
            catalogEntry: entry,
            pendingRelativePaths: entry.files.map(\.relativePath),
            currentRelativePath: nil,
            completedBytes: 0,
            totalBytes: totalBytes,
            currentFilePartialBytes: 0,
            currentFileLiveBytes: 0,
            currentFileRetryCount: 0,
            currentResumeDataPath: nil,
            currentPhase: .downloading
        )
    }

    static func activeDownloadPhase(
        hasResumeData: Bool,
        isRetry: Bool
    ) -> IOSModelDeliverySnapshot.Phase {
        if hasResumeData {
            return .resuming
        }
        return isRetry ? .restarting : .downloading
    }

    static func startingCurrentDownload(
        from install: IOSPersistedModelInstallState,
        currentRelativePath: String,
        phase: IOSModelDeliverySnapshot.Phase
    ) -> IOSPersistedModelInstallState {
        let retryCount = install.currentRelativePath == nil ? 0 : install.currentFileRetryCount
        // Preserve bytes already accumulated for this file (e.g. after a pause)
        // but reset the live counter because a new backend task reports from zero
        // for the remaining portion.
        let partialBytes = install.currentRelativePath == currentRelativePath
            ? install.currentFilePartialBytes
            : 0
        return IOSPersistedModelInstallState(
            modelID: install.modelID,
            artifactVersion: install.artifactVersion,
            stagingDirectoryPath: install.stagingDirectoryPath,
            catalogEntry: install.catalogEntry,
            pendingRelativePaths: install.pendingRelativePaths,
            currentRelativePath: currentRelativePath,
            completedBytes: install.completedBytes,
            totalBytes: install.totalBytes,
            currentFilePartialBytes: partialBytes,
            currentFileLiveBytes: 0,
            currentFileRetryCount: retryCount,
            currentResumeDataPath: nil,
            currentPhase: phase
        )
    }

    static func completedCurrentDownload(
        from install: IOSPersistedModelInstallState,
        currentRelativePath: String,
        currentFile: IOSModelCatalogFile
    ) -> IOSPersistedModelInstallState {
        IOSPersistedModelInstallState(
            modelID: install.modelID,
            artifactVersion: install.artifactVersion,
            stagingDirectoryPath: install.stagingDirectoryPath,
            catalogEntry: install.catalogEntry,
            pendingRelativePaths: install.pendingRelativePaths.filter { $0 != currentRelativePath },
            currentRelativePath: nil,
            completedBytes: install.completedBytes + currentFile.sizeBytes,
            totalBytes: install.totalBytes,
            currentFilePartialBytes: 0,
            currentFileLiveBytes: 0,
            currentFileRetryCount: 0,
            currentResumeDataPath: nil,
            currentPhase: .downloading
        )
    }

    static func updatingCurrentFileProgress(
        from install: IOSPersistedModelInstallState,
        liveBytes: Int64
    ) -> IOSPersistedModelInstallState {
        IOSPersistedModelInstallState(
            modelID: install.modelID,
            artifactVersion: install.artifactVersion,
            stagingDirectoryPath: install.stagingDirectoryPath,
            catalogEntry: install.catalogEntry,
            pendingRelativePaths: install.pendingRelativePaths,
            currentRelativePath: install.currentRelativePath,
            completedBytes: install.completedBytes,
            totalBytes: install.totalBytes,
            currentFilePartialBytes: install.currentFilePartialBytes,
            currentFileLiveBytes: liveBytes,
            currentFileRetryCount: install.currentFileRetryCount,
            currentResumeDataPath: install.currentResumeDataPath,
            currentPhase: install.currentPhase
        )
    }

    static func pausedCurrentDownload(
        from install: IOSPersistedModelInstallState,
        resumeDataPath: String?
    ) -> IOSPersistedModelInstallState {
        IOSPersistedModelInstallState(
            modelID: install.modelID,
            artifactVersion: install.artifactVersion,
            stagingDirectoryPath: install.stagingDirectoryPath,
            catalogEntry: install.catalogEntry,
            pendingRelativePaths: install.pendingRelativePaths,
            currentRelativePath: install.currentRelativePath,
            completedBytes: install.completedBytes,
            totalBytes: install.totalBytes,
            currentFilePartialBytes: install.currentFilePartialBytes + install.currentFileLiveBytes,
            currentFileLiveBytes: 0,
            currentFileRetryCount: install.currentFileRetryCount,
            currentResumeDataPath: resumeDataPath,
            currentPhase: .paused
        )
    }

    static func scheduledRetry(
        from install: IOSPersistedModelInstallState,
        retryCount: Int,
        resumeDataPath: String?
    ) -> IOSPersistedModelInstallState {
        IOSPersistedModelInstallState(
            modelID: install.modelID,
            artifactVersion: install.artifactVersion,
            stagingDirectoryPath: install.stagingDirectoryPath,
            catalogEntry: install.catalogEntry,
            pendingRelativePaths: install.pendingRelativePaths,
            currentRelativePath: install.currentRelativePath,
            completedBytes: install.completedBytes,
            totalBytes: install.totalBytes,
            currentFilePartialBytes: install.currentFilePartialBytes,
            currentFileLiveBytes: 0,
            currentFileRetryCount: retryCount,
            currentResumeDataPath: resumeDataPath,
            currentPhase: activeDownloadPhase(
                hasResumeData: resumeDataPath != nil,
                isRetry: true
            )
        )
    }
}

actor IOSModelDeliveryActor {
    typealias SnapshotSink = @MainActor @Sendable (IOSModelDeliverySnapshot) -> Void

    private let modelAssetStore: LocalModelAssetStore
    private let configuration: IOSModelDeliveryConfiguration
    private let stateFileURL: URL
    private let snapshotSink: SnapshotSink
    private let fileManager: FileManager
    private let catalogSession: URLSession
    private let backend: IOSModelDownloadBackend
    private let delegate: IOSModelDeliveryDownloadDelegate

    private var activeInstall: IOSPersistedModelInstallState?
    private var operationGeneration: UInt64 = 0
    private var activeOperationGeneration: UInt64?

    init(
        modelAssetStore: LocalModelAssetStore,
        configuration: IOSModelDeliveryConfiguration = .default(),
        stateFileURL: URL = AppPaths.modelDeliveryStateFile,
        fileManager: FileManager = .default,
        snapshotSink: @escaping SnapshotSink
    ) {
        self.modelAssetStore = modelAssetStore
        self.configuration = configuration
        self.fileManager = fileManager
        self.snapshotSink = snapshotSink
        self.stateFileURL = stateFileURL

        let delegate = IOSModelDeliveryDownloadDelegate()
        self.delegate = delegate

        if IOSSimulatorRuntimeSupport.isSimulator {
            self.backend = IOSSimulatedModelDownloadBackend(delegate: delegate)
        } else {
            self.backend = IOSURLSessionModelDownloadBackend(
                configuration: configuration,
                delegate: delegate
            )
        }

        let catalogConfig = URLSessionConfiguration.ephemeral
        catalogConfig.waitsForConnectivity = true
        catalogConfig.timeoutIntervalForRequest = 60
        catalogConfig.timeoutIntervalForResource = 300
        self.catalogSession = URLSession(configuration: catalogConfig)

        delegate.onProgress = { [weak self] taskIdentifier, taskDescription, totalBytesWritten, totalBytesExpectedToWrite in
            guard let self else { return }
            Task {
                await self.handleProgress(
                    taskIdentifier: taskIdentifier,
                    rawTaskDescription: taskDescription,
                    totalBytesWritten: totalBytesWritten,
                    totalBytesExpectedToWrite: totalBytesExpectedToWrite
                )
            }
        }
        delegate.onFinished = { [weak self] taskIdentifier, taskDescription, safeURL in
            guard let self else { return }
            Task {
                await self.handleFinishedDownload(
                    taskIdentifier: taskIdentifier,
                    rawTaskDescription: taskDescription,
                    safeURL: safeURL
                )
            }
        }
        delegate.onCompleted = { [weak self] taskIdentifier, taskDescription, error in
            guard let self else { return }
            Task {
                await self.handleTaskCompletion(
                    taskIdentifier: taskIdentifier,
                    rawTaskDescription: taskDescription,
                    error: error
                )
            }
        }
    }

    func resumeBackgroundEventsIfNeeded() async {
        await restoreInFlightInstallIfNeeded()
        await completeBackgroundEventsIfIdle()
    }

    func restoreInFlightInstallIfNeeded() async {
        guard let persisted = loadPersistedState() else { return }
        guard let descriptor = modelAssetStore.descriptor(id: persisted.modelID)?.model,
              descriptor.artifactVersion == persisted.artifactVersion else {
            cleanupPersistedState()
            cleanupDirectory(at: URL(fileURLWithPath: persisted.stagingDirectoryPath, isDirectory: true))
            return
        }

        activeInstall = persisted
        let generation = beginActiveOperation()
        await publishSnapshot(
            IOSModelDeliverySnapshot(
                modelID: persisted.modelID,
                phase: persisted.currentPhase,
                downloadedBytes: persisted.completedBytes + persisted.currentFilePartialBytes,
                totalBytes: persisted.totalBytes,
                estimatedBytes: descriptor.estimatedDownloadBytes,
                message: statusMessage(for: persisted.currentPhase),
                operationGeneration: generation
            )
        )

        // A paused install waits for the user to tap Resume; do not auto-start.
        guard persisted.currentPhase != .paused else { return }

        let matchingTaskExists: Bool
        if let currentRelativePath = persisted.currentRelativePath {
            let taskDescription = IOSModelDownloadTaskDescription(
                modelID: persisted.modelID,
                relativePath: currentRelativePath
            )
            matchingTaskExists = await backend.hasTask(for: taskDescription)
        } else {
            matchingTaskExists = false
        }

        if !matchingTaskExists {
            do {
                try await startNextDownloadIfNeeded()
            } catch {
                await failActiveInstall(error)
            }
        }
    }

    func install(model: ModelDescriptor) async throws {
        if let activeInstall, activeInstall.modelID != model.id {
            throw IOSModelDeliveryError.invalidConfiguration("Another model operation is already running.")
        }
        guard model.iosDownloadEligible else {
            throw IOSModelDeliveryError.notEligibleForIOS(modelID: model.id)
        }

        if let activeInstall, activeInstall.modelID == model.id {
            // Resume a paused install; otherwise ignore duplicate install requests.
            if activeInstall.currentPhase == .paused {
                if activeOperationGeneration == nil {
                    _ = beginActiveOperation()
                }
                try await startNextDownloadIfNeeded()
            }
            return
        }

        try fileManager.createDirectory(at: AppPaths.modelsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: AppPaths.modelDownloadStagingDir, withIntermediateDirectories: true)
        try IOSModelDeliverySupport.excludeFromBackup(AppPaths.modelsDir)
        try IOSModelDeliverySupport.excludeFromBackup(AppPaths.modelDownloadStagingDir)

        let catalog = try await fetchCatalog()
        let entry = try IOSModelDeliverySupport.matchingCatalogEntry(
            for: model,
            in: catalog,
            configuration: configuration
        )
        let totalBytes = entry.totalBytes > 0 ? entry.totalBytes : entry.files.reduce(0) { $0 + $1.sizeBytes }
        try IOSModelDeliverySupport.ensureSufficientDiskSpace(
            requiredBytes: totalBytes,
            at: AppPaths.appSupportDir,
            fileManager: fileManager
        )

        let stagingRoot = AppPaths.modelDownloadStagingDir
            .appendingPathComponent("\(model.id)-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.removeItem(at: stagingRoot)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try IOSModelDeliverySupport.excludeFromBackup(stagingRoot)

        let persisted = IOSModelDeliveryStateMachine.initialInstall(
            model: model,
            entry: entry,
            stagingRoot: stagingRoot,
            totalBytes: totalBytes
        )
        activeInstall = persisted
        _ = beginActiveOperation()
        savePersistedState(persisted)
        try await startNextDownloadIfNeeded()
    }

    func pause(modelID: String) async {
        guard let activeInstall,
              activeInstall.modelID == modelID,
              let currentRelativePath = activeInstall.currentRelativePath else { return }

        let taskDescription = IOSModelDownloadTaskDescription(
            modelID: modelID,
            relativePath: currentRelativePath
        )
        let resumeData = await backend.pause(taskDescription: taskDescription)
        let resumeDataPath = resumeData.flatMap { saveResumeData($0, for: activeInstall) }
        let pausedInstall = IOSModelDeliveryStateMachine.pausedCurrentDownload(
            from: activeInstall,
            resumeDataPath: resumeDataPath
        )
        self.activeInstall = pausedInstall
        savePersistedState(pausedInstall)

        let descriptor = modelAssetStore.descriptor(id: modelID)?.model
        guard let generation = activeOperationGeneration else { return }
        await publishSnapshot(
            IOSModelDeliverySnapshot(
                modelID: modelID,
                phase: .paused,
                downloadedBytes: pausedInstall.completedBytes + pausedInstall.currentFilePartialBytes,
                totalBytes: pausedInstall.totalBytes,
                estimatedBytes: descriptor?.estimatedDownloadBytes,
                message: nil,
                operationGeneration: generation
            )
        )
    }

    func cancel(modelID: String) async {
        guard let activeInstall, activeInstall.modelID == modelID else { return }
        let terminalGeneration = endActiveOperation()
        await backend.cancelAllTasks(for: modelID)

        cleanupDirectory(at: URL(fileURLWithPath: activeInstall.stagingDirectoryPath, isDirectory: true))
        cleanupPersistedState()
        self.activeInstall = nil

        let descriptor = modelAssetStore.descriptor(id: modelID)?.model
        await publishSnapshot(
            IOSModelDeliverySnapshot(
                modelID: modelID,
                phase: .deleted,
                downloadedBytes: 0,
                totalBytes: nil,
                estimatedBytes: descriptor?.estimatedDownloadBytes,
                message: nil,
                operationGeneration: terminalGeneration
            )
        )

        Task { @MainActor in
            IOSModelDeliveryBackgroundEventRelay.completeIfPending()
        }
    }

    func delete(model: ModelDescriptor) async throws {
        if let activeInstall, activeInstall.modelID == model.id {
            await cancel(modelID: model.id)
        } else if activeInstall != nil {
            throw IOSModelDeliveryError.invalidConfiguration("Another model operation is already running.")
        }

        await publishSnapshot(
            IOSModelDeliverySnapshot(
                modelID: model.id,
                phase: .deleting,
                downloadedBytes: 0,
                totalBytes: nil,
                estimatedBytes: model.estimatedDownloadBytes,
                message: nil,
                operationGeneration: beginActiveOperation()
            )
        )

        let finalRoot = modelAssetStore.localRoot(
            for: try requireDescriptor(id: model.id)
        )
        if fileManager.fileExists(atPath: finalRoot.path) {
            try fileManager.removeItem(at: finalRoot)
        }

        let terminalGeneration = endActiveOperation()
        await publishSnapshot(
            IOSModelDeliverySnapshot(
                modelID: model.id,
                phase: .deleted,
                downloadedBytes: 0,
                totalBytes: nil,
                estimatedBytes: model.estimatedDownloadBytes,
                message: nil,
                operationGeneration: terminalGeneration
            )
        )
    }

    private func beginActiveOperation() -> UInt64 {
        operationGeneration += 1
        activeOperationGeneration = operationGeneration
        return operationGeneration
    }

    @discardableResult
    private func endActiveOperation() -> UInt64 {
        operationGeneration += 1
        activeOperationGeneration = nil
        return operationGeneration
    }

    private func fetchCatalog() async throws -> IOSModelCatalogDocument {
        if configuration.catalogURL.isBundledModelCatalog {
            guard let catalogURL = Bundle.main.url(
                forResource: IOSModelDeliveryConfiguration.bundledCatalogResourceName,
                withExtension: IOSModelDeliveryConfiguration.bundledCatalogResourceExtension
            ) else {
                throw IOSModelDeliveryError.invalidCatalog("Bundled iPhone model catalog is missing.")
            }
            let data = try Data(contentsOf: catalogURL)
            return try JSONDecoder().decode(IOSModelCatalogDocument.self, from: data)
        }

        let (data, response) = try await catalogSession.data(from: configuration.catalogURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw IOSModelDeliveryError.invalidCatalog("Catalog endpoint returned an unexpected response.")
        }
        let document = try JSONDecoder().decode(IOSModelCatalogDocument.self, from: data)
        return document
    }

    private func startNextDownloadIfNeeded() async throws {
        guard var activeInstall else { return }

        if activeInstall.pendingRelativePaths.isEmpty {
            try await verifyAndInstallActiveModel()
            return
        }

        let nextRelativePath = activeInstall.currentRelativePath ?? activeInstall.pendingRelativePaths[0]
        let nextFile = try requireFile(relativePath: nextRelativePath, in: activeInstall.catalogEntry)
        let descriptor = try requireDescriptor(id: activeInstall.modelID).model
        let taskDescription = IOSModelDownloadTaskDescription(
            modelID: activeInstall.modelID,
            relativePath: nextRelativePath
        )
        let isRetry = activeInstall.currentRelativePath != nil || activeInstall.currentFileRetryCount > 0

        let loadedResumeData: Data?
        if let currentResumeDataPath = activeInstall.currentResumeDataPath {
            loadedResumeData = try? Data(contentsOf: URL(fileURLWithPath: currentResumeDataPath))
        } else {
            loadedResumeData = nil
        }
        let didLoadResumeData = loadedResumeData != nil

        if let currentResumeDataPath = activeInstall.currentResumeDataPath {
            cleanupResumeData(atPath: currentResumeDataPath)
        }

        try await backend.startDownload(
            taskDescription: taskDescription,
            entry: activeInstall.catalogEntry,
            file: nextFile,
            resumeData: loadedResumeData
        )

        let phase = IOSModelDeliveryStateMachine.activeDownloadPhase(
            hasResumeData: didLoadResumeData,
            isRetry: isRetry
        )
        activeInstall = IOSModelDeliveryStateMachine.startingCurrentDownload(
            from: activeInstall,
            currentRelativePath: nextRelativePath,
            phase: phase
        )
        self.activeInstall = activeInstall
        savePersistedState(activeInstall)

        guard let generation = activeOperationGeneration else { return }
        await publishSnapshot(
            IOSModelDeliverySnapshot(
                modelID: activeInstall.modelID,
                phase: phase,
                downloadedBytes: activeInstall.completedBytes + activeInstall.currentFilePartialBytes,
                totalBytes: activeInstall.totalBytes,
                estimatedBytes: descriptor.estimatedDownloadBytes,
                message: statusMessage(for: phase),
                operationGeneration: generation
            )
        )
    }

    private func verifyAndInstallActiveModel() async throws {
        guard let activeInstall else { return }
        guard let generation = activeOperationGeneration else { return }
        let descriptor = try requireDescriptor(id: activeInstall.modelID).model
        let stagingRoot = URL(fileURLWithPath: activeInstall.stagingDirectoryPath, isDirectory: true)
        cleanupTransientInstallArtifacts(at: stagingRoot)

        await publishSnapshot(
            IOSModelDeliverySnapshot(
                modelID: activeInstall.modelID,
                phase: .verifying,
                downloadedBytes: activeInstall.totalBytes,
                totalBytes: activeInstall.totalBytes,
                estimatedBytes: descriptor.estimatedDownloadBytes,
                message: nil,
                operationGeneration: generation
            )
        )

        if backend.requiresDownloadVerification {
            try IOSModelDeliverySupport.verifyDownloadedModel(
                descriptor: descriptor,
                entry: activeInstall.catalogEntry,
                stagedRoot: stagingRoot,
                fileManager: fileManager
            )
        }

        await publishSnapshot(
            IOSModelDeliverySnapshot(
                modelID: activeInstall.modelID,
                phase: .installing,
                downloadedBytes: activeInstall.totalBytes,
                totalBytes: activeInstall.totalBytes,
                estimatedBytes: descriptor.estimatedDownloadBytes,
                message: nil,
                operationGeneration: generation
            )
        )

        let assetDescriptor = try requireDescriptor(id: activeInstall.modelID)
        let finalRoot = modelAssetStore.localRoot(for: assetDescriptor)
        let backupRoot = finalRoot
            .deletingLastPathComponent()
            .appendingPathComponent(".backup-\(descriptor.id)-\(UUID().uuidString)", isDirectory: true)

        if fileManager.fileExists(atPath: backupRoot.path) {
            try? fileManager.removeItem(at: backupRoot)
        }

        do {
            if fileManager.fileExists(atPath: finalRoot.path) {
                try fileManager.moveItem(at: finalRoot, to: backupRoot)
            }
            try fileManager.moveItem(at: stagingRoot, to: finalRoot)
            try IOSModelDeliverySupport.excludeFromBackup(finalRoot)
            if fileManager.fileExists(atPath: backupRoot.path) {
                try fileManager.removeItem(at: backupRoot)
            }
        } catch {
            if !fileManager.fileExists(atPath: finalRoot.path),
               fileManager.fileExists(atPath: backupRoot.path) {
                try? fileManager.moveItem(at: backupRoot, to: finalRoot)
            }
            throw error
        }

        cleanupPersistedState()
        self.activeInstall = nil
        let terminalGeneration = endActiveOperation()
        await publishSnapshot(
            IOSModelDeliverySnapshot(
                modelID: descriptor.id,
                phase: .installed,
                downloadedBytes: activeInstall.totalBytes,
                totalBytes: activeInstall.totalBytes,
                estimatedBytes: descriptor.estimatedDownloadBytes,
                message: nil,
                operationGeneration: terminalGeneration
            )
        )
    }

    private func handleProgress(
        taskIdentifier: Int,
        rawTaskDescription: String?,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) async {
        _ = taskIdentifier
        let taskDescription = decodeTaskDescription(rawTaskDescription)
        guard let activeInstall,
              let generation = activeOperationGeneration,
              let currentRelativePath = activeInstall.currentRelativePath,
              let taskDescription,
              taskDescription.modelID == activeInstall.modelID,
              taskDescription.relativePath == currentRelativePath,
              let descriptor = modelAssetStore.descriptor(id: activeInstall.modelID)?.model else {
            #if DEBUG
            print("[IOSModelDeliveryActor] Dropped progress callback — taskDescription=\(taskDescription?.modelID ?? "nil") currentFile=\(activeInstall?.currentRelativePath ?? "nil")")
            #endif
            return
        }

        let expectedBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
        let trackedInstall = IOSModelDeliveryStateMachine.updatingCurrentFileProgress(
            from: activeInstall,
            liveBytes: totalBytesWritten
        )
        self.activeInstall = trackedInstall
        let downloadedBytes = trackedInstall.completedBytes + trackedInstall.currentFilePartialBytes + totalBytesWritten
        guard activeOperationGeneration == generation else { return }
        await publishSnapshot(
            IOSModelDeliverySnapshot(
                modelID: trackedInstall.modelID,
                phase: trackedInstall.currentPhase,
                downloadedBytes: downloadedBytes,
                totalBytes: trackedInstall.totalBytes > 0 ? trackedInstall.totalBytes : expectedBytes,
                estimatedBytes: descriptor.estimatedDownloadBytes,
                message: statusMessage(for: trackedInstall.currentPhase),
                operationGeneration: generation
            )
        )
    }

    private func handleFinishedDownload(taskIdentifier: Int, rawTaskDescription: String?, safeURL: URL) async {
        _ = taskIdentifier
        do {
            let taskDescription = decodeTaskDescription(rawTaskDescription)
            guard var activeInstall,
                  let currentRelativePath = activeInstall.currentRelativePath,
                  let taskDescription,
                  taskDescription.modelID == activeInstall.modelID,
                  taskDescription.relativePath == currentRelativePath else {
                cleanupDirectory(at: safeURL)
                return
            }

            let currentFile = try requireFile(relativePath: currentRelativePath, in: activeInstall.catalogEntry)
            let stagingRoot = URL(fileURLWithPath: activeInstall.stagingDirectoryPath, isDirectory: true)
            let destinationURL = stagingRoot.appendingPathComponent(currentRelativePath)
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: safeURL, to: destinationURL)

            activeInstall = IOSModelDeliveryStateMachine.completedCurrentDownload(
                from: activeInstall,
                currentRelativePath: currentRelativePath,
                currentFile: currentFile
            )
            self.activeInstall = activeInstall
            savePersistedState(activeInstall)
            try await startNextDownloadIfNeeded()
            await completeBackgroundEventsIfIdle()
        } catch {
            await failActiveInstall(error)
        }
    }

    private func handleTaskCompletion(taskIdentifier: Int, rawTaskDescription: String?, error: Error?) async {
        _ = taskIdentifier
        guard let error else {
            await completeBackgroundEventsIfIdle()
            return
        }

        if let nsError = error as NSError?, nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }

        guard let activeInstall else {
            await failActiveInstall(error)
            return
        }

        let taskDescription = decodeTaskDescription(rawTaskDescription)
        guard let taskDescription else {
            #if DEBUG
            print("[IOSModelDeliveryActor] Dropped task error callback — missing or unparseable taskDescription error=\(error.localizedDescription)")
            #endif
            return
        }
        guard taskDescription.modelID == activeInstall.modelID,
              taskDescription.relativePath == activeInstall.currentRelativePath else {
            #if DEBUG
            print("[IOSModelDeliveryActor] Dropped stale task error callback — taskDescription modelID=\(taskDescription.modelID) path=\(taskDescription.relativePath) activeModelID=\(activeInstall.modelID) activePath=\(activeInstall.currentRelativePath ?? "nil") error=\(error.localizedDescription)")
            #endif
            return
        }

        if shouldRetry(error), activeInstall.currentFileRetryCount < maxRetriesPerFile {
            let newRetryCount = activeInstall.currentFileRetryCount + 1
            let resumeDataPath = extractResumeData(from: error).flatMap { saveResumeData($0, for: activeInstall) }
            #if DEBUG
            print("[IOSModelDeliveryActor] Retrying file download (attempt \(newRetryCount)/\(maxRetriesPerFile)) modelID=\(activeInstall.modelID) path=\(activeInstall.currentRelativePath ?? "unknown") error=\(error.localizedDescription)")
            #endif
            let updatedInstall = IOSModelDeliveryStateMachine.scheduledRetry(
                from: activeInstall,
                retryCount: newRetryCount,
                resumeDataPath: resumeDataPath
            )
            self.activeInstall = updatedInstall
            savePersistedState(updatedInstall)
            let descriptor = modelAssetStore.descriptor(id: activeInstall.modelID)?.model
            guard let generation = activeOperationGeneration else { return }
            await publishSnapshot(
                IOSModelDeliverySnapshot(
                    modelID: activeInstall.modelID,
                    phase: .interrupted,
                    downloadedBytes: activeInstall.completedBytes + activeInstall.currentFilePartialBytes,
                    totalBytes: activeInstall.totalBytes,
                    estimatedBytes: descriptor?.estimatedDownloadBytes,
                    message: resumeDataPath == nil
                        ? "Connection interrupted. Restarting the current file."
                        : "Connection interrupted. Resuming the current file.",
                    operationGeneration: generation
                )
            )
            do {
                try await startNextDownloadIfNeeded()
            } catch {
                await failActiveInstall(error)
            }
        } else {
            await failActiveInstall(error)
        }
    }

    private let maxRetriesPerFile = 3

    private func shouldRetry(_ error: Error) -> Bool {
        guard let nsError = error as NSError? else { return false }
        let retryableCodes = [
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorDataNotAllowed,
            NSURLErrorCannotLoadFromNetwork,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorCallIsActive,
        ]
        if nsError.domain == NSURLErrorDomain && retryableCodes.contains(nsError.code) {
            return true
        }
        return false
    }

    private func failActiveInstall(_ error: Error) async {
        guard let activeInstall else { return }
        let descriptor = modelAssetStore.descriptor(id: activeInstall.modelID)?.model
        let terminalGeneration = endActiveOperation()
        cleanupDirectory(at: URL(fileURLWithPath: activeInstall.stagingDirectoryPath, isDirectory: true))
        cleanupPersistedState()
        self.activeInstall = nil
        await publishSnapshot(
            IOSModelDeliverySnapshot(
                modelID: activeInstall.modelID,
                phase: .failed,
                downloadedBytes: 0,
                totalBytes: activeInstall.totalBytes,
                estimatedBytes: descriptor?.estimatedDownloadBytes,
                message: error.localizedDescription,
                operationGeneration: terminalGeneration
            )
        )
        Task { @MainActor in
            IOSModelDeliveryBackgroundEventRelay.completeIfPending()
        }
    }

    private func publishSnapshot(_ snapshot: IOSModelDeliverySnapshot) async {
        await snapshotSink(snapshot)
    }

    private func requireDescriptor(id: String) throws -> ModelAssetDescriptor {
        guard let descriptor = modelAssetStore.descriptor(id: id) else {
            throw IOSModelDeliveryError.invalidConfiguration("Missing model descriptor for \(id).")
        }
        return descriptor
    }

    private func requireFile(relativePath: String, in entry: IOSModelCatalogEntry) throws -> IOSModelCatalogFile {
        guard let file = entry.files.first(where: { $0.relativePath == relativePath }) else {
            throw IOSModelDeliveryError.invalidCatalog("Catalog entry for \(entry.modelID) is missing file \(relativePath).")
        }
        return file
    }

    private func completeBackgroundEventsIfIdle() async {
        guard activeInstall == nil else { return }
        guard await backend.activeTaskCount() == 0 else { return }
        await MainActor.run {
            IOSModelDeliveryBackgroundEventRelay.completeIfPending()
        }
    }

    private func deliveryTransientDirectory(for install: IOSPersistedModelInstallState) -> URL {
        URL(fileURLWithPath: install.stagingDirectoryPath, isDirectory: true)
            .appendingPathComponent(".delivery", isDirectory: true)
    }

    private func resumeDataURL(for install: IOSPersistedModelInstallState) -> URL {
        let fileKey = (install.currentRelativePath ?? "current").replacingOccurrences(of: "/", with: "__")
        return deliveryTransientDirectory(for: install).appendingPathComponent("\(fileKey).resume", isDirectory: false)
    }

    private func saveResumeData(_ data: Data, for install: IOSPersistedModelInstallState) -> String? {
        let url = resumeDataURL(for: install)
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            #if DEBUG
            print("[IOSModelDeliveryActor] Failed to persist resume data: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    private func cleanupResumeData(atPath path: String?) {
        guard let path else { return }
        try? fileManager.removeItem(at: URL(fileURLWithPath: path))
    }

    private func cleanupTransientInstallArtifacts(at stagingRoot: URL) {
        try? fileManager.removeItem(at: stagingRoot.appendingPathComponent(".delivery", isDirectory: true))
    }

    private func extractResumeData(from error: Error) -> Data? {
        let nsError = error as NSError
        return nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    }

    private func statusMessage(for phase: IOSModelDeliverySnapshot.Phase) -> String? {
        switch phase {
        case .interrupted:
            return "Download interrupted."
        case .resuming:
            return "Resuming interrupted file…"
        case .restarting:
            return "Restarting current file…"
        case .downloading, .paused, .verifying, .installing, .installed, .deleting, .deleted, .failed:
            return nil
        }
    }

    private func savePersistedState(_ state: IOSPersistedModelInstallState) {
        do {
            try fileManager.createDirectory(at: stateFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateFileURL, options: .atomic)
        } catch {
            #if DEBUG
            print("[IOSModelDeliveryActor] Failed to persist state: \(error.localizedDescription)")
            #endif
        }
    }

    private func loadPersistedState() -> IOSPersistedModelInstallState? {
        guard let data = try? Data(contentsOf: stateFileURL) else { return nil }
        return try? JSONDecoder().decode(IOSPersistedModelInstallState.self, from: data)
    }

    private func cleanupPersistedState() {
        try? fileManager.removeItem(at: stateFileURL)
    }

    private func cleanupDirectory(at url: URL) {
        try? fileManager.removeItem(at: url)
    }
}
