import Foundation
import QwenVoiceCore

struct IOSModelDeliverySnapshot: Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case downloading
        case interrupted
        case resuming
        case restarting
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
        self.currentFileRetryCount = try container.decodeIfPresent(Int.self, forKey: .currentFileRetryCount) ?? 0
        self.currentResumeDataPath = try container.decodeIfPresent(String.self, forKey: .currentResumeDataPath)
        self.currentPhase = try container.decodeIfPresent(IOSModelDeliverySnapshot.Phase.self, forKey: .currentPhase) ?? .downloading
    }
}

private struct IOSModelDownloadTaskDescription: Codable, Sendable {
    let modelID: String
    let relativePath: String
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
        return IOSPersistedModelInstallState(
            modelID: install.modelID,
            artifactVersion: install.artifactVersion,
            stagingDirectoryPath: install.stagingDirectoryPath,
            catalogEntry: install.catalogEntry,
            pendingRelativePaths: install.pendingRelativePaths,
            currentRelativePath: currentRelativePath,
            completedBytes: install.completedBytes,
            totalBytes: install.totalBytes,
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
            currentFileRetryCount: 0,
            currentResumeDataPath: nil,
            currentPhase: .downloading
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
            currentFileRetryCount: retryCount,
            currentResumeDataPath: resumeDataPath,
            currentPhase: activeDownloadPhase(
                hasResumeData: resumeDataPath != nil,
                isRetry: true
            )
        )
    }
}

// Closures are set once after URLSession init and never mutated afterwards.
// Do not add mutation paths — if callbacks need changing, recreate the delegate.
private final class IOSModelDeliveryDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var onProgress: (@Sendable (Int, String?, Int64, Int64) -> Void)?
    var onFinished: (@Sendable (Int, String?, URL) -> Void)?
    var onCompleted: (@Sendable (Int, String?, Error?) -> Void)?

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress?(
            downloadTask.taskIdentifier,
            downloadTask.taskDescription,
            totalBytesWritten,
            totalBytesExpectedToWrite
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let safeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        do {
            if FileManager.default.fileExists(atPath: safeURL.path) {
                try FileManager.default.removeItem(at: safeURL)
            }
            try FileManager.default.moveItem(at: location, to: safeURL)
            onFinished?(downloadTask.taskIdentifier, downloadTask.taskDescription, safeURL)
        } catch {
            onCompleted?(downloadTask.taskIdentifier, downloadTask.taskDescription, error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        onCompleted?(task.taskIdentifier, task.taskDescription, error)
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
    private let downloadSession: URLSession
    private let delegate: IOSModelDeliveryDownloadDelegate

    private var activeInstall: IOSPersistedModelInstallState?

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

        let catalogConfig = URLSessionConfiguration.ephemeral
        catalogConfig.waitsForConnectivity = true
        catalogConfig.timeoutIntervalForRequest = 60
        catalogConfig.timeoutIntervalForResource = 300
        self.catalogSession = URLSession(configuration: catalogConfig)

        let backgroundConfig = URLSessionConfiguration.background(withIdentifier: configuration.backgroundSessionIdentifier)
        backgroundConfig.waitsForConnectivity = true
        backgroundConfig.sessionSendsLaunchEvents = true
        backgroundConfig.isDiscretionary = false
        backgroundConfig.allowsExpensiveNetworkAccess = true
        backgroundConfig.allowsConstrainedNetworkAccess = true
        backgroundConfig.timeoutIntervalForRequest = 300
        self.downloadSession = URLSession(configuration: backgroundConfig, delegate: delegate, delegateQueue: nil)

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
        await publishSnapshot(
            IOSModelDeliverySnapshot(
                modelID: persisted.modelID,
                phase: persisted.currentPhase,
                downloadedBytes: persisted.completedBytes,
                totalBytes: persisted.totalBytes,
                estimatedBytes: descriptor.estimatedDownloadBytes,
                message: statusMessage(for: persisted.currentPhase)
            )
        )

        let tasks = await allDownloadTasks()
        let matchingTask = tasks.first { task in
            guard let description = decodeTaskDescription(task.taskDescription) else { return false }
            return description.modelID == persisted.modelID &&
                description.relativePath == persisted.currentRelativePath
        }

        if matchingTask == nil {
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
        savePersistedState(persisted)
        try await startNextDownloadIfNeeded()
    }

    func cancel(modelID: String) async {
        guard let activeInstall, activeInstall.modelID == modelID else { return }
        let tasks = await allDownloadTasks()
        for task in tasks {
            if decodeTaskDescription(task.taskDescription)?.modelID == modelID {
                task.cancel()
            }
        }

        cleanupDirectory(at: URL(fileURLWithPath: activeInstall.stagingDirectoryPath, isDirectory: true))
        cleanupPersistedState()
        self.activeInstall = nil
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
                message: nil
            )
        )

        let finalRoot = modelAssetStore.localRoot(
            for: try requireDescriptor(id: model.id)
        )
        if fileManager.fileExists(atPath: finalRoot.path) {
            try fileManager.removeItem(at: finalRoot)
        }

        await publishSnapshot(
            IOSModelDeliverySnapshot(
                modelID: model.id,
                phase: .deleted,
                downloadedBytes: 0,
                totalBytes: nil,
                estimatedBytes: model.estimatedDownloadBytes,
                message: nil
            )
        )
    }

    private func fetchCatalog() async throws -> IOSModelCatalogDocument {
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
        var task: URLSessionDownloadTask

        let loadedResumeData: Data?
        if let currentResumeDataPath = activeInstall.currentResumeDataPath {
            loadedResumeData = try? Data(contentsOf: URL(fileURLWithPath: currentResumeDataPath))
        } else {
            loadedResumeData = nil
        }
        let didLoadResumeData = loadedResumeData != nil

        if let currentResumeDataPath = activeInstall.currentResumeDataPath,
           let resumeData = loadedResumeData {
            task = downloadSession.downloadTask(withResumeData: resumeData)
            cleanupResumeData(atPath: currentResumeDataPath)
        } else {
            if let currentResumeDataPath = activeInstall.currentResumeDataPath {
                cleanupResumeData(atPath: currentResumeDataPath)
            }
            let downloadURL = try IOSModelDeliverySupport.downloadURL(
                for: nextFile,
                entry: activeInstall.catalogEntry,
                configuration: configuration
            )
            task = downloadSession.downloadTask(with: downloadURL)
        }
        task.taskDescription = encodeTaskDescription(taskDescription)

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
        task.resume()

        await publishSnapshot(
            IOSModelDeliverySnapshot(
                modelID: activeInstall.modelID,
                phase: phase,
                downloadedBytes: activeInstall.completedBytes,
                totalBytes: activeInstall.totalBytes,
                estimatedBytes: descriptor.estimatedDownloadBytes,
                message: statusMessage(for: phase)
            )
        )
    }

    private func verifyAndInstallActiveModel() async throws {
        guard let activeInstall else { return }
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
                message: nil
            )
        )
        try IOSModelDeliverySupport.verifyDownloadedModel(
            descriptor: descriptor,
            entry: activeInstall.catalogEntry,
            stagedRoot: stagingRoot,
            fileManager: fileManager
        )

        await publishSnapshot(
            IOSModelDeliverySnapshot(
                modelID: activeInstall.modelID,
                phase: .installing,
                downloadedBytes: activeInstall.totalBytes,
                totalBytes: activeInstall.totalBytes,
                estimatedBytes: descriptor.estimatedDownloadBytes,
                message: nil
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
        await publishSnapshot(
            IOSModelDeliverySnapshot(
                modelID: descriptor.id,
                phase: .installed,
                downloadedBytes: activeInstall.totalBytes,
                totalBytes: activeInstall.totalBytes,
                estimatedBytes: descriptor.estimatedDownloadBytes,
                message: nil
            )
        )
    }

    private func handleProgress(
        taskIdentifier: Int,
        rawTaskDescription: String?,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) async {
        let taskDescription = decodeTaskDescription(rawTaskDescription)
        guard let activeInstall,
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
        let downloadedBytes = activeInstall.completedBytes + totalBytesWritten
        await publishSnapshot(
            IOSModelDeliverySnapshot(
                modelID: activeInstall.modelID,
                phase: activeInstall.currentPhase,
                downloadedBytes: downloadedBytes,
                totalBytes: activeInstall.totalBytes > 0 ? activeInstall.totalBytes : expectedBytes,
                estimatedBytes: descriptor.estimatedDownloadBytes,
                message: statusMessage(for: activeInstall.currentPhase)
            )
        )
    }

    private func handleFinishedDownload(taskIdentifier: Int, rawTaskDescription: String?, safeURL: URL) async {
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
        _ = rawTaskDescription
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
            await publishSnapshot(
                IOSModelDeliverySnapshot(
                    modelID: activeInstall.modelID,
                    phase: .interrupted,
                    downloadedBytes: activeInstall.completedBytes,
                    totalBytes: activeInstall.totalBytes,
                    estimatedBytes: descriptor?.estimatedDownloadBytes,
                    message: resumeDataPath == nil
                        ? "Connection interrupted. Restarting the current file."
                        : "Connection interrupted. Resuming the current file."
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
        // Retry common transient network errors
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
                message: error.localizedDescription
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

    private func allDownloadTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            downloadSession.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }

    private func completeBackgroundEventsIfIdle() async {
        // Only acknowledge the background session once the actor has fully
        // cleared install state and URLSession no longer has pending work.
        guard activeInstall == nil else { return }
        guard (await allDownloadTasks()).isEmpty else { return }
        await MainActor.run {
            IOSModelDeliveryBackgroundEventRelay.completeIfPending()
        }
    }

    private func encodeTaskDescription(_ description: IOSModelDownloadTaskDescription) -> String? {
        guard let data = try? JSONEncoder().encode(description) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeTaskDescription(_ rawValue: String?) -> IOSModelDownloadTaskDescription? {
        guard let rawValue, let data = rawValue.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(IOSModelDownloadTaskDescription.self, from: data)
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
        case .downloading, .verifying, .installing, .installed, .deleting, .deleted, .failed:
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
