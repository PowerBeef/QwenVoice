import CryptoKit
@preconcurrency import Foundation

/// Downloads a HuggingFace model repository using native URLSession.
public final class HuggingFaceDownloader: NSObject, URLSessionDownloadDelegate {

    public enum DownloadPhase: String, Equatable, Sendable {
        case queued
        case waitingForConnectivity
        case downloading
        case retrying
        case verifying
        case installing
        case cancelling
    }

    public struct RepositoryProgress: Equatable, Sendable {
        public let downloadedBytes: Int64
        public let totalBytes: Int64
        public let completedFiles: Int
        public let totalFiles: Int
        public let bytesPerSecond: Int64?
        public let isStalled: Bool
        public let estimatedSecondsRemaining: Double?
        public let retryCount: Int
        public let statusMessage: String?
        public let phase: DownloadPhase
    }

    public struct TransferMetrics: Codable, Equatable, Sendable {
        public let relativePath: String?
        public let protocolName: String?
        public let redirectCount: Int
        public let reusedConnection: Bool
        public let cellular: Bool
        public let constrained: Bool
        public let expensive: Bool
        public let transferredBytes: Int64
        public let durationSeconds: Double
    }

    /// Tunable download-engine parameters. Defaults match the macOS/CLI profile: 6 parallel
    /// connections per host and `chunkLargeFiles = false`. iOS uses a memory-safer profile:
    /// fewer parallel files and `chunkLargeFiles = false` (background URLSession throttles many
    /// small range requests, and chunks multiply in-flight buffers). The foreground URLSession's
    /// `httpMaximumConnectionsPerHost` is capped at 4.
    public struct Configuration: Sendable {
        public var maxConcurrentFiles = 6
        public var chunkLargeFiles = false
        public var chunkedDownloadThreshold: Int64 = 96 * 1024 * 1024
        public var chunkTargetSize: Int64 = 64 * 1024 * 1024
        public var maxDownloadRetries = 3
        public init() {}
    }

    public enum DownloadError: LocalizedError {
        case cancelled
        case httpError(statusCode: Int, path: String, retryAfterSeconds: Double? = nil)
        case fileDownloadFailed(path: String, underlying: Error)
        case integrityCheckFailed(path: String, reason: String)
        case rangeUnsupported(path: String)
        case chunkAssemblyFailed(path: String, reason: String)
        case invalidRemotePath(String)
        case invalidLocalDestination(String)
        case apiError(String)

        public var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Download cancelled"
            case .httpError(let code, let path, _):
                return "HTTP \(code) downloading \(path)"
            case .fileDownloadFailed(let path, let underlying):
                return "Failed to download \(path): \(underlying.localizedDescription)"
            case .integrityCheckFailed(let path, let reason):
                return "Downloaded file failed integrity checks for \(path): \(reason)"
            case .rangeUnsupported(let path):
                return "Server did not honor the byte-range request for \(path); retrying as a single stream"
            case .chunkAssemblyFailed(let path, let reason):
                return "Failed to assemble byte-range chunk for \(path): \(reason)"
            case .invalidRemotePath(let path):
                return "Rejected unsafe remote path: \(path)"
            case .invalidLocalDestination(let path):
                return "Rejected unsafe local destination: \(path)"
            case .apiError(let message):
                return message
            }
        }
    }

    public struct RepoFile: Sendable, Hashable {
        public let path: String
        public let size: Int64
        public let sha256: String?
        /// If set, download this file from this absolute URL instead of resolving it from
        /// `{resolveBaseURL}/{repo}/resolve/{revision}/{path}`. iOS passes its catalog's validated
        /// per-file URLs here (host allowlist enforced by `IOSModelDeliverySupport.downloadURL`).
        public let absoluteURL: URL?

        public init(path: String, size: Int64, sha256: String?, absoluteURL: URL? = nil) {
            self.path = path
            self.size = size
            self.sha256 = sha256
            self.absoluteURL = absoluteURL
        }
    }

    struct DownloadStateManifest: Codable, Equatable {
        let schemaVersion: Int
        let repo: String
        let revision: String
        let targetFolder: String
        let updatedAtUTC: String
        let files: [FileEntry]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case repo
            case revision
            case targetFolder = "target_folder"
            case updatedAtUTC = "updated_at_utc"
            case files
        }

        struct FileEntry: Codable, Equatable {
            let path: String
            let size: Int64
            let sha256: String?
        }
    }

    struct DownloadedTemporaryFile: Sendable {
        let url: URL
        let statusCode: Int?
        let retryAfterSeconds: Double?
        let contentRange: String?
    }

    final class RepositoryProgressHandlerBox: Sendable {
        let handler: @Sendable (RepositoryProgress) -> Void

        init(_ handler: @escaping @Sendable (RepositoryProgress) -> Void) {
            self.handler = handler
        }
    }

    final class TransferMetricsHandlerBox: Sendable {
        let handler: @Sendable (TransferMetrics) -> Void

        init(_ handler: @escaping @Sendable (TransferMetrics) -> Void) {
            self.handler = handler
        }
    }

    final class VerifiedArtifactHandlerBox: Sendable {
        let handler: @Sendable (VerifiedArtifactReceipt) async -> Void

        init(_ handler: @escaping @Sendable (VerifiedArtifactReceipt) async -> Void) {
            self.handler = handler
        }
    }

    /// Foundation has not annotated FileManager as Sendable. Confine that compatibility gap to
    /// one immutable adapter instead of making the downloader broadly unchecked.
    final class FileManagerBox: @unchecked Sendable {
        let value: FileManager

        init(_ value: FileManager) {
            self.value = value
        }
    }

    final class TaskCancellationBox: @unchecked Sendable {
        private let task: URLSessionDownloadTask
        private let resumeDataURL: URL?

        init(task: URLSessionDownloadTask, resumeDataURL: URL?) {
            self.task = task
            self.resumeDataURL = resumeDataURL
        }

        func cancelAndWait() async {
            await withCheckedContinuation { continuation in
                task.cancel { [resumeDataURL] resumeData in
                    guard let resumeDataURL,
                          let resumeData,
                          !resumeData.isEmpty else {
                        continuation.resume()
                        return
                    }
                    try? FileManager.default.createDirectory(
                        at: resumeDataURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try? resumeData.write(to: resumeDataURL, options: .atomic)
                    continuation.resume()
                }
            }
        }
    }

    actor DownloadStateRegistry {
        private var isCancelled = false
        // Per-task handle so concurrent files can each be cancelled independently.
        private var activeCancellations: [Int: TaskCancellationBox] = [:]
        private var continuations: [Int: CheckedContinuation<DownloadedTemporaryFile, Error>] = [:]
        private var destinations: [Int: URL] = [:]
        // Maps a URLSession taskID -> the index of the file it is downloading, so the
        // delegate's per-task progress callbacks aggregate into per-file byte counters.
        private var taskFileIndex: [Int: Int] = [:]
        // Per-task bytes written (monotonic per URLSession task). A single-stream file has
        // one entry; a byte-range chunked file has one entry per in-flight chunk. The
        // repository total is the sum across all live tasks plus completed-file sizes, so
        // N chunks of one file aggregate correctly (a per-file monotonic max would not).
        private var taskBytes: [Int: Int64] = [:]
        private var completedFilesBytes: Int64 = 0
        private let repositoryProgressHandler: RepositoryProgressHandlerBox?
        private var repositoryTotalBytes: Int64 = 0
        private var repositoryTotalFiles = 0
        private var repositoryCompletedFiles = 0
        private var lastProgressAdvanceTime: TimeInterval?
        private var lastSpeedSampleTime: TimeInterval?
        private var lastSpeedSampleBytes: Int64 = 0
        private var lastMeasuredBytesPerSecond: Int64?
        private var lastProgressPublicationTime: TimeInterval?
        private var lastPublishedBytes: Int64 = -1
        private var lastPublishedPhase: DownloadPhase?
        private var phase: DownloadPhase = .downloading
        private var heartbeatTask: Task<Void, Never>?
        private var retryCount = 0
        private var statusMessage: String?
        // A download file callback precedes task metrics and the terminal task callback.
        // Keep the durable file staged until didCompleteWithError so callers cannot publish
        // a success summary before URLSession has delivered its final metrics.
        private var stagedSuccessfulDownloads: [Int: (ModelDownloadTaskIdentity?, DownloadedTemporaryFile)] = [:]
        private var unclaimedCompletionsByRelativePath: [String: DownloadedTemporaryFile] = [:]
        private var expectedTaskIdentityByURL: [URL: ModelDownloadTaskIdentity] = [:]
        private var adoptedTasksByRelativePath: [String: URLSessionDownloadTask] = [:]
        private var backgroundCompletionGate = ModelDownloadBackgroundCompletionGate()
        private var verifiedReceiptsByPath: [String: VerifiedArtifactReceipt] = [:]

        /// Bytes counted so far: completed files (at their exact size) plus the live sum of
        /// in-flight task bytes (single-stream or chunk). Recomputed so retries and chunks
        /// both stay exact without a separate accumulated counter.
        private var repositoryDownloadedBytes: Int64 {
            completedFilesBytes + taskBytes.values.reduce(0, +)
        }

        init(repositoryProgressHandler: RepositoryProgressHandlerBox?) {
            self.repositoryProgressHandler = repositoryProgressHandler
        }

        func resetForNewRepositoryDownload(preserveUnclaimedCompletions: Bool) {
            isCancelled = false
            activeCancellations.removeAll()
            continuations.removeAll()
            destinations.removeAll()
            taskFileIndex.removeAll()
            taskBytes.removeAll()
            completedFilesBytes = 0
            repositoryTotalBytes = 0
            repositoryTotalFiles = 0
            repositoryCompletedFiles = 0
            lastProgressAdvanceTime = nil
            lastSpeedSampleTime = nil
            lastSpeedSampleBytes = 0
            lastMeasuredBytesPerSecond = nil
            lastProgressPublicationTime = nil
            lastPublishedBytes = -1
            lastPublishedPhase = nil
            phase = .downloading
            retryCount = 0
            statusMessage = nil
            if !preserveUnclaimedCompletions {
                for (_, staged) in stagedSuccessfulDownloads.values {
                    try? FileManager.default.removeItem(at: staged.url)
                }
                stagedSuccessfulDownloads.removeAll()
                for completion in unclaimedCompletionsByRelativePath.values {
                    try? FileManager.default.removeItem(at: completion.url)
                }
                unclaimedCompletionsByRelativePath.removeAll()
            }
            expectedTaskIdentityByURL.removeAll()
            adoptedTasksByRelativePath.removeAll()
            backgroundCompletionGate.resetForRequest()
            verifiedReceiptsByPath.removeAll()
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }

        func beginRepositoryDownload(totalBytes: Int64, totalFiles: Int, phase: DownloadPhase = .downloading) {
            repositoryTotalBytes = max(0, totalBytes)
            repositoryTotalFiles = max(0, totalFiles)
            repositoryCompletedFiles = 0
            completedFilesBytes = 0
            taskFileIndex.removeAll()
            taskBytes.removeAll()
            self.phase = phase
            let now = ProcessInfo.processInfo.systemUptime
            lastProgressAdvanceTime = now
            lastSpeedSampleTime = now
            lastSpeedSampleBytes = 0
            lastMeasuredBytesPerSecond = nil
            emitRepositoryProgress(isStalled: false)
            startHeartbeatIfNeeded()
        }

        func register(
            task: URLSessionDownloadTask,
            destination: URL,
            continuation: CheckedContinuation<DownloadedTemporaryFile, Error>,
            resumeDataURL: URL?,
            fileIndex: Int,
            existingBytes: Int64 = 0
        ) -> Bool {
            let taskID = task.taskIdentifier
            if isCancelled {
                task.cancel()
                continuation.resume(throwing: DownloadError.cancelled)
                return false
            }
            if let identity = ModelDownloadTaskIdentity.decode(taskDescription: task.taskDescription),
               let completed = unclaimedCompletionsByRelativePath.removeValue(forKey: identity.relativePath) {
                task.cancel()
                continuation.resume(returning: completed)
                return false
            }
            activeCancellations[taskID] = TaskCancellationBox(task: task, resumeDataURL: resumeDataURL)
            continuations[taskID] = continuation
            destinations[taskID] = destination
            taskFileIndex[taskID] = fileIndex
            taskBytes[taskID] = existingBytes
            if existingBytes > 0 {
                let now = ProcessInfo.processInfo.systemUptime
                applySpeedMeasurement(
                    now: now,
                    totalDownloaded: repositoryDownloadedBytes,
                    advancedDelta: existingBytes
                )
                emitRepositoryProgress(isStalled: false)
            }
            return true
        }

        func requestCancellation() async {
            guard !isCancelled else { return }
            isCancelled = true
            phase = .cancelling
            statusMessage = nil
            emitRepositoryProgress(isStalled: false, force: true)
            let cancellations = Array(activeCancellations.values)
            await withTaskGroup(of: Void.self) { group in
                for cancellation in cancellations {
                    group.addTask {
                        await cancellation.cancelAndWait()
                    }
                }
            }
            let pendingContinuations = Array(continuations.values)
            continuations.removeAll()
            activeCancellations.removeAll()
            destinations.removeAll()
            for continuation in pendingContinuations {
                continuation.resume(throwing: DownloadError.cancelled)
            }
            for (_, staged) in stagedSuccessfulDownloads.values {
                try? FileManager.default.removeItem(at: staged.url)
            }
            stagedSuccessfulDownloads.removeAll()
            for completion in unclaimedCompletionsByRelativePath.values {
                try? FileManager.default.removeItem(at: completion.url)
            }
            unclaimedCompletionsByRelativePath.removeAll()
        }

        func cancellationRequested() -> Bool {
            isCancelled
        }

        func setPhase(_ phase: DownloadPhase) {
            self.phase = phase
            if phase != .retrying { statusMessage = nil }
            emitRepositoryProgress(isStalled: false, force: true)
        }

        func setRetry(number: Int, reason: String) {
            retryCount = number
            statusMessage = reason
            phase = .retrying
            emitRepositoryProgress(isStalled: false, force: true)
        }

        func setWaitingForConnectivity(_ waiting: Bool) {
            if waiting {
                phase = .waitingForConnectivity
                statusMessage = "Waiting for connectivity"
            } else if phase == .waitingForConnectivity {
                phase = .downloading
                statusMessage = nil
            }
            emitRepositoryProgress(isStalled: false, force: true)
        }

        func configureExpectedTasks(_ values: [(URL, ModelDownloadTaskIdentity)]) {
            expectedTaskIdentityByURL = Dictionary(uniqueKeysWithValues: values)
            adoptedTasksByRelativePath.removeAll()
        }

        func expectedIdentity(for url: URL) -> ModelDownloadTaskIdentity? {
            expectedTaskIdentityByURL[url]
        }

        func adopt(task: URLSessionDownloadTask, identity: ModelDownloadTaskIdentity) -> Bool {
            guard !isCancelled,
                  adoptedTasksByRelativePath[identity.relativePath] == nil else {
                return false
            }
            adoptedTasksByRelativePath[identity.relativePath] = task
            return true
        }

        func takeAdoptedTask(for url: URL) -> URLSessionDownloadTask? {
            guard let identity = expectedTaskIdentityByURL[url] else { return nil }
            return adoptedTasksByRelativePath.removeValue(forKey: identity.relativePath)
        }

        func markBackgroundEventsFinished() -> Bool {
            backgroundCompletionGate.markEventsFinished()
        }

        func markPostprocessingFinished() -> Bool {
            backgroundCompletionGate.markPostprocessingFinished()
        }

        func recordVerifiedReceipt(_ receipt: VerifiedArtifactReceipt) {
            verifiedReceiptsByPath[receipt.relativePath] = receipt
        }

        func verifiedReceipts() -> [String: VerifiedArtifactReceipt] {
            verifiedReceiptsByPath
        }

        /// Per-task progress from the URLSession delegate. Monotonic per task, so a
        /// resume->fresh fallback never moves a task's counter backward. Works for both a
        /// single-stream file (1 task) and a chunked file (N tasks) because the repository
        /// total is the sum of all task bytes.
        func reportProgress(taskID: Int, totalBytesWritten: Int64) {
            guard taskFileIndex[taskID] != nil else { return }
            let previous = taskBytes[taskID] ?? 0
            let updated = max(previous, totalBytesWritten)
            let delta = updated - previous
            guard delta != 0 else { return }
            taskBytes[taskID] = updated
            let now = ProcessInfo.processInfo.systemUptime
            applySpeedMeasurement(now: now, totalDownloaded: repositoryDownloadedBytes, advancedDelta: delta)
            emitRepositoryProgress(isStalled: false)
        }

        /// Drop any live task state for `fileIndex` (called at the start of each download
        /// attempt). Clears stale bytes from a prior failed attempt so they don't inflate
        /// the counter during a retry; the fresh attempt re-accumulates from zero.
        func resetFileProgress(fileIndex: Int) {
            let staleTaskIDs = taskFileIndex.keys.filter { taskFileIndex[$0] == fileIndex }
            for taskID in staleTaskIDs {
                taskBytes.removeValue(forKey: taskID)
                taskFileIndex.removeValue(forKey: taskID)
            }
        }

        /// A file finished (downloaded, or already-valid and skipped). Fold its live task
        /// bytes into the completed-files total at the exact expected size, then drop the
        /// file's task entries. Reconciliation is implicit: the live sum loses the file's
        /// task bytes and `completedFilesBytes` gains `expectedSize`.
        func reportFileCompleted(fileIndex: Int, expectedSize: Int64) {
            let fileTaskIDs = taskFileIndex.keys.filter { taskFileIndex[$0] == fileIndex }
            var liveForFile: Int64 = 0
            for taskID in fileTaskIDs {
                liveForFile += taskBytes.removeValue(forKey: taskID) ?? 0
                taskFileIndex.removeValue(forKey: taskID)
            }
            completedFilesBytes += expectedSize
            repositoryCompletedFiles += 1
            let now = ProcessInfo.processInfo.systemUptime
            applySpeedMeasurement(now: now, totalDownloaded: repositoryDownloadedBytes, advancedDelta: expectedSize - liveForFile)
            emitRepositoryProgress(isStalled: false, force: true)
        }

        func finishRepositoryDownload() {
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }

        func stageSuccess(
            taskID: Int,
            identity: ModelDownloadTaskIdentity?,
            temporaryFile: DownloadedTemporaryFile
        ) {
            if let (_, superseded) = stagedSuccessfulDownloads.updateValue(
                (identity, temporaryFile),
                forKey: taskID
            ) {
                try? FileManager.default.removeItem(at: superseded.url)
            }
        }

        func completeStagedSuccess(taskID: Int) {
            guard let (identity, temporaryFile) = stagedSuccessfulDownloads.removeValue(forKey: taskID) else {
                return
            }
            let continuation = continuations.removeValue(forKey: taskID)
            destinations.removeValue(forKey: taskID)
            activeCancellations.removeValue(forKey: taskID)
            // NOTE: taskFileIndex/taskBytes are intentionally left in place — the file's
            // live bytes stay counted until reportFileCompleted folds them in (success) or
            // resetFileProgress clears them (retry).
            if isCancelled {
                try? FileManager.default.removeItem(at: temporaryFile.url)
                continuation?.resume(throwing: DownloadError.cancelled)
            } else if let continuation {
                continuation.resume(returning: temporaryFile)
            } else if let identity {
                // Background callbacks may arrive before launch reconciliation has registered
                // the adopted task. Keep the durable temporary file until adoption completes.
                if let superseded = unclaimedCompletionsByRelativePath.updateValue(
                    temporaryFile,
                    forKey: identity.relativePath
                ) {
                    try? FileManager.default.removeItem(at: superseded.url)
                }
            } else {
                try? FileManager.default.removeItem(at: temporaryFile.url)
            }
        }

        func resumeFailure(taskID: Int, error: Error) {
            if let (_, staged) = stagedSuccessfulDownloads.removeValue(forKey: taskID) {
                try? FileManager.default.removeItem(at: staged.url)
            }
            let continuation = continuations.removeValue(forKey: taskID)
            destinations.removeValue(forKey: taskID)
            activeCancellations.removeValue(forKey: taskID)
            continuation?.resume(throwing: error)
        }

        func destinationPath(taskID: Int) -> String {
            destinations[taskID]?.lastPathComponent ?? "unknown"
        }

        private func applySpeedMeasurement(now: TimeInterval, totalDownloaded: Int64, advancedDelta: Int64) {
            guard advancedDelta > 0 else { return }
            if let previousSpeedSampleTime = lastSpeedSampleTime {
                let elapsed = now - previousSpeedSampleTime
                guard elapsed >= 0.5 else {
                    lastProgressAdvanceTime = now
                    return
                }
                let deltaBytes = totalDownloaded - lastSpeedSampleBytes
                if deltaBytes > 0 {
                    let instantaneous = Double(deltaBytes) / elapsed
                    if let previous = lastMeasuredBytesPerSecond {
                        lastMeasuredBytesPerSecond = Int64(
                            (Double(previous) * 0.75) + (instantaneous * 0.25)
                        )
                    } else {
                        lastMeasuredBytesPerSecond = Int64(instantaneous)
                    }
                    lastSpeedSampleTime = now
                    lastSpeedSampleBytes = totalDownloaded
                }
            } else {
                lastSpeedSampleTime = now
                lastSpeedSampleBytes = totalDownloaded
            }
            lastProgressAdvanceTime = now
        }

        private func startHeartbeatIfNeeded() {
            guard heartbeatTask == nil else { return }
            let registry = self
            heartbeatTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(750))
                    await registry.emitHeartbeatIfNeeded()
                }
            }
        }

        private func emitHeartbeatIfNeeded() {
            guard repositoryProgressHandler != nil else { return }
            guard !activeCancellations.isEmpty else { return }

            let now = ProcessInfo.processInfo.systemUptime
            guard phase == .downloading,
                  let lastProgressAdvanceTime,
                  now - lastProgressAdvanceTime >= 20 else {
                return
            }
            emitRepositoryProgress(isStalled: true, force: true)
        }

        private func emitRepositoryProgress(isStalled: Bool, force: Bool = false) {
            let downloaded = min(repositoryDownloadedBytes, repositoryTotalBytes)
            let now = ProcessInfo.processInfo.systemUptime
            let phaseChanged = lastPublishedPhase != phase
            let reachedCompletion = repositoryTotalBytes > 0
                && downloaded == repositoryTotalBytes
                && lastPublishedBytes != downloaded
            if !force, !isStalled, !phaseChanged, !reachedCompletion,
               let lastProgressPublicationTime,
               now - lastProgressPublicationTime < 0.25 {
                return
            }
            let remaining = max(repositoryTotalBytes - downloaded, 0)
            let eta = lastMeasuredBytesPerSecond.flatMap { speed -> Double? in
                guard speed > 0, phase == .downloading else { return nil }
                return Double(remaining) / Double(speed)
            }
            repositoryProgressHandler?.handler(
                RepositoryProgress(
                    downloadedBytes: downloaded,
                    totalBytes: repositoryTotalBytes,
                    completedFiles: min(repositoryCompletedFiles, repositoryTotalFiles),
                    totalFiles: repositoryTotalFiles,
                    bytesPerSecond: lastMeasuredBytesPerSecond,
                    isStalled: isStalled,
                    estimatedSecondsRemaining: eta,
                    retryCount: retryCount,
                    statusMessage: statusMessage,
                    phase: phase
                )
            )
            lastProgressPublicationTime = now
            lastPublishedBytes = downloaded
            lastPublishedPhase = phase
        }
    }

    /// Serializes writes from concurrently downloaded byte-range chunks into one partial
    /// file. `FileHandle` is not safe for concurrent seek+write on the same descriptor, so
    /// each chunk's bytes are written under actor isolation (the network — not the local
    /// disk — is the bottleneck, so serial writes are cheap). APFS fills sparse holes as
    /// out-of-order chunks land, so no pre-allocation is needed.
    actor ChunkAssemblyCoordinator {
        private let partialURL: URL
        private var writeHandle: FileHandle?

        init(partialURL: URL) {
            self.partialURL = partialURL
        }

        /// Open the partial for writing, creating it if necessary.
        func open() throws {
            if !FileManager.default.fileExists(atPath: partialURL.path) {
                FileManager.default.createFile(atPath: partialURL.path, contents: nil, attributes: nil)
            }
            writeHandle = try FileHandle(forWritingTo: partialURL)
        }

        /// Stream the contents of `tempURL` into the partial at absolute byte `offset`.
        /// Validates that the number of bytes written matches the temp file's size so a
        /// truncated or corrupted chunk doesn't silently leave a hole in the partial.
        func writeChunk(tempURL: URL, offset: Int64) throws {
            guard let writeHandle else { return }
            let attributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
            let expectedBytes = Int64(attributes[.size] as? Int64 ?? 0)
            try writeHandle.seek(toOffset: UInt64(offset))
            let readHandle = try FileHandle(forReadingFrom: tempURL)
            defer { try? readHandle.close() }
            var bytesWritten: Int64 = 0
            while autoreleasepool(invoking: {
                let data = readHandle.readData(ofLength: 1_048_576)
                guard !data.isEmpty else { return false }
                writeHandle.write(data)
                bytesWritten += Int64(data.count)
                return true
            }) {}
            guard bytesWritten == expectedBytes else {
                throw DownloadError.chunkAssemblyFailed(
                    path: tempURL.path,
                    reason: "expected \(expectedBytes) bytes, wrote \(bytesWritten)"
                )
            }
        }

        func close() {
            try? writeHandle?.synchronize()
            try? writeHandle?.close()
            writeHandle = nil
        }
    }

    // Foundation's delegate protocols are Sendable, while URLSession is initialized after
    // self so it can retain this delegate. The session reference is assigned once during init;
    // all mutable transfer state remains isolated by DownloadStateRegistry.
    private nonisolated(unsafe) var session: URLSession!
    private let state: DownloadStateRegistry
    private let apiBaseURL: URL
    private let resolveBaseURL: URL
    private let fileManagerBox: FileManagerBox
    private var fileManager: FileManager { fileManagerBox.value }
    private let engineConfiguration: Configuration
    private let isBackgroundSession: Bool
    private let durableTemporaryDirectory: URL
    private let verificationProcessGeneration = UUID().uuidString
    /// Invoked from `urlSessionDidFinishEvents(forBackgroundURLSession:)` (background sessions
    /// only) with the session's identifier so iOS can flush its app-delegate completion handler.
    /// macOS/CLI pass `nil` (foreground sessions never trigger this callback).
    private let backgroundSessionCompletionHandler: (@Sendable (String) -> Void)?
    private let transferMetricsHandler: TransferMetricsHandlerBox?
    private let verifiedArtifactHandler: VerifiedArtifactHandlerBox?
    private let artifactURLPolicy: ModelArtifactURLPolicy?

    static func validatedRelativeRepoPath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DownloadError.invalidRemotePath(path)
        }

        let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/") else {
            throw DownloadError.invalidRemotePath(path)
        }

        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else {
            throw DownloadError.invalidRemotePath(path)
        }

        var validatedComponents: [String] = []
        for rawComponent in components {
            let component = String(rawComponent)
            guard !component.isEmpty, component != ".", component != ".." else {
                throw DownloadError.invalidRemotePath(path)
            }
            guard !component.hasPrefix(".") else {
                throw DownloadError.invalidRemotePath(path)
            }
            validatedComponents.append(component)
        }

        return validatedComponents.joined(separator: "/")
    }

    static func validatedDestinationURL(for relativePath: String, in root: URL) throws -> URL {
        let validatedRelativePath = try validatedRelativeRepoPath(relativePath)
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let destination = normalizedRoot
            .appendingPathComponent(validatedRelativePath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPrefix = normalizedRoot.path.hasSuffix("/") ? normalizedRoot.path : normalizedRoot.path + "/"

        guard destination.path.hasPrefix(rootPrefix) else {
            throw DownloadError.invalidLocalDestination(relativePath)
        }

        return destination
    }

    static func repoFiles(fromAPIData data: Data) throws -> [RepoFile] {
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DownloadError.apiError("Unexpected API response format")
        }

        return items.compactMap { item -> RepoFile? in
            guard let type = item["type"] as? String, type == "file",
                  let path = item["path"] as? String,
                  path != ".gitattributes" else { return nil }

            let size: Int64
            let sha256: String?
            if let lfs = item["lfs"] as? [String: Any] {
                if let lfsSize = lfs["size"] as? Int64 {
                    size = lfsSize
                } else if let lfsSize = lfs["size"] as? Int {
                    size = Int64(lfsSize)
                } else {
                    size = 0
                }
                sha256 = normalizedSHA256(lfs["oid"] as? String)
            } else if let s = item["size"] as? Int64 {
                size = s
                sha256 = nil
            } else if let s = item["size"] as? Int {
                size = Int64(s)
                sha256 = nil
            } else {
                size = 0
                sha256 = nil
            }

            return RepoFile(path: path, size: size, sha256: sha256)
        }
    }

    static func downloadRequest(for url: URL, existingBytes: Int64) -> URLRequest {
        var request = URLRequest(url: url)
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }
        return request
    }

    static func validateDownloadedFile(
        at url: URL,
        expectedSize: Int64,
        sha256: String?
    ) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let actualSize = Int64(values.fileSize ?? 0)
        if expectedSize > 0, actualSize != expectedSize {
            throw DownloadError.integrityCheckFailed(
                path: url.path,
                reason: "expected \(expectedSize) bytes, found \(actualSize)"
            )
        }
        guard let expectedSHA256 = normalizedSHA256(sha256) else { return }
        let actualSHA256 = try sha256Hex(for: url)
        guard actualSHA256 == expectedSHA256 else {
            throw DownloadError.integrityCheckFailed(
                path: url.path,
                reason: "expected sha256 \(expectedSHA256), found \(actualSHA256)"
            )
        }
    }

    static func sha256Hex(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 1_048_576)
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedSHA256(_ value: String?) -> String? {
        guard var value else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("sha256:") {
            value.removeFirst("sha256:".count)
        }
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "0123456789abcdef").contains($0)
              }) else {
            return nil
        }
        return value
    }

    convenience override init() {
        self.init(progressHandler: nil)
    }

    public init(
        progressHandler: (@Sendable (RepositoryProgress) -> Void)?,
        sessionConfiguration: URLSessionConfiguration = .default,
        engineConfiguration: Configuration = Configuration(),
        apiBaseURL: URL = URL(string: "https://huggingface.co/api/models")!,
        resolveBaseURL: URL = URL(string: "https://huggingface.co")!,
        fileManager: FileManager = .default,
        durableTemporaryDirectory: URL? = nil,
        transferMetricsHandler: (@Sendable (TransferMetrics) -> Void)? = nil,
        verifiedArtifactHandler: (@Sendable (VerifiedArtifactReceipt) async -> Void)? = nil,
        backgroundSessionCompletionHandler: (@Sendable (String) -> Void)? = nil,
        artifactURLPolicy: ModelArtifactURLPolicy? = nil
    ) {
        let progressBox = progressHandler.map(RepositoryProgressHandlerBox.init)
        state = DownloadStateRegistry(repositoryProgressHandler: progressBox)
        self.apiBaseURL = apiBaseURL
        self.resolveBaseURL = resolveBaseURL
        self.fileManagerBox = FileManagerBox(fileManager)
        self.engineConfiguration = engineConfiguration
        self.backgroundSessionCompletionHandler = backgroundSessionCompletionHandler
        self.transferMetricsHandler = transferMetricsHandler.map(TransferMetricsHandlerBox.init)
        self.verifiedArtifactHandler = verifiedArtifactHandler.map(VerifiedArtifactHandlerBox.init)
        self.artifactURLPolicy = artifactURLPolicy
        self.isBackgroundSession = sessionConfiguration.identifier != nil
        self.durableTemporaryDirectory = durableTemporaryDirectory ?? fileManager.temporaryDirectory
        super.init()

        let isBackground = isBackgroundSession
        let config: URLSessionConfiguration
        if isBackground {
            // Background configs are effectively singletons-by-identifier; copying/mutating one
            // (e.g. httpMaximumConnectionsPerHost) is unreliable and the key is ignored anyway.
            // Concurrency is bounded by the task group's `maxConcurrentFiles` instead. Callers
            // (iOS) configure the background config fully before passing it in.
            config = sessionConfiguration
        } else {
            let copy = sessionConfiguration.copy() as? URLSessionConfiguration ?? .default
            copy.timeoutIntervalForResource = 3600
            copy.httpMaximumConnectionsPerHost = 4
            config = copy
        }
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Public API

    /// Download all files from a HuggingFace repo into `targetDir`.
    /// Resolve the file list from the live HuggingFace API, then download + verify + install.
    /// macOS + CLI path.
    public func downloadRepo(repo: String, revision: String = "main", to targetDir: URL) async throws {
        await state.resetForNewRepositoryDownload(preserveUnclaimedCompletions: isBackgroundSession)
        do {
            let files = try await listFiles(repo: repo, revision: revision)
            try await runDownload(
                files: files,
                repo: repo,
                revision: revision,
                targetDir: targetDir,
                persistStateManifest: true
            )
        } catch {
            if !isBackgroundSession { session.invalidateAndCancel() }
            throw error
        }
    }

    /// Download + verify + install a pre-resolved file list (no API call). iOS path — the caller
    /// supplies files from its catalog, each optionally carrying a validated `absoluteURL`
    /// (host-allowlist-enforced by the caller). `repo`/`revision` seed the integrity manifest and
    /// the fallback resolve URL for any file without an `absoluteURL`.
    public func downloadFiles(
        _ files: [RepoFile],
        repo: String,
        revision: String,
        to targetDir: URL,
        requestIdentity: ModelDownloadRequestIdentity? = nil,
        stagingRoot explicitStagingRoot: URL? = nil
    ) async throws {
        await state.resetForNewRepositoryDownload(preserveUnclaimedCompletions: isBackgroundSession)
        try await runDownload(
            files: files,
            repo: repo,
            revision: revision,
            targetDir: targetDir,
            persistStateManifest: false,
            requestIdentity: requestIdentity,
            explicitStagingRoot: explicitStagingRoot
        )
    }

    /// Shared staging → parallel download → SHA-256 verify → atomic install flow used by both
    /// `downloadRepo` (API path) and `downloadFiles` (catalog path).
    private func runDownload(
        files: [RepoFile],
        repo: String,
        revision: String,
        targetDir: URL,
        persistStateManifest: Bool,
        requestIdentity: ModelDownloadRequestIdentity? = nil,
        explicitStagingRoot: URL? = nil
    ) async throws {
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        await state.beginRepositoryDownload(totalBytes: totalBytes, totalFiles: files.count)

        let stagingRoot = explicitStagingRoot ?? Self.stagingRoot(forTargetDirectory: targetDir)
        let filesRoot = stagingRoot.appendingPathComponent("files", isDirectory: true)
        let partialRoot = stagingRoot.appendingPathComponent("partials", isDirectory: true)
        let resumeRoot = stagingRoot.appendingPathComponent("resume-data", isDirectory: true)
        try fileManager.createDirectory(at: filesRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: partialRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resumeRoot, withIntermediateDirectories: true)
        Self.markExcludedFromBackup(stagingRoot)
        Self.markExcludedFromBackup(filesRoot)
        Self.markExcludedFromBackup(partialRoot)
        Self.markExcludedFromBackup(resumeRoot)
        try fileManager.createDirectory(at: durableTemporaryDirectory, withIntermediateDirectories: true)
        Self.markExcludedFromBackup(durableTemporaryDirectory)

        if let requestIdentity {
            let expectedTasks = try files.map { file -> (URL, ModelDownloadTaskIdentity) in
                let relativePath = try Self.validatedRelativeRepoPath(file.path)
                let url = try file.absoluteURL ?? Self.fileResolveURL(
                    resolveBaseURL: resolveBaseURL,
                    repo: repo,
                    revision: revision,
                    relativePath: relativePath
                )
                return (
                    url,
                    ModelDownloadTaskIdentity(
                        logicalRequestID: requestIdentity.logicalRequestID,
                        modelID: requestIdentity.modelID,
                        artifactVersion: requestIdentity.artifactVersion,
                        relativePath: relativePath,
                        expectedSize: file.size,
                        expectedSHA256: file.sha256
                    )
                )
            }
            await state.configureExpectedTasks(expectedTasks)
            if isBackgroundSession {
                await reconcileBackgroundTasks(expected: Dictionary(uniqueKeysWithValues: expectedTasks.map { ($0.1.relativePath, $0.1) }))
            }
        }
        // The download-state manifest is the macOS resume-after-crash record; iOS keeps its own
        // lightweight in-flight list, so the catalog path skips this.
        if persistStateManifest {
            try persistDownloadState(
                repo: repo,
                revision: revision,
                targetDir: targetDir,
                files: files,
                stagingRoot: stagingRoot
            )
        }

        do {
            try await downloadAllFiles(
                files,
                repo: repo,
                revision: revision,
                artifactVersion: requestIdentity?.artifactVersion ?? revision,
                filesRoot: filesRoot,
                partialRoot: partialRoot,
                resumeRoot: resumeRoot
            )
            try await throwIfCancellationRequested()
            await state.setPhase(.verifying)
            try await throwIfCancellationRequested()
            try await verifyDownloadedFilesUsingReceipts(
                files,
                artifactVersion: requestIdentity?.artifactVersion ?? revision,
                in: filesRoot
            )
            try await throwIfCancellationRequested()
            try persistInstalledIntegrityManifest(
                repo: repo,
                revision: revision,
                targetDir: targetDir,
                files: files,
                filesRoot: filesRoot
            )
            try await throwIfCancellationRequested()
            await state.setPhase(.installing)
            try await throwIfCancellationRequested()
            try installStagedRepository(filesRoot: filesRoot, targetDir: targetDir)
            // Installation is synchronous, so check once more before publishing
            // success. The iOS coordinator rolls back a target created by this
            // narrow race before it durably records deletion.
            try await throwIfCancellationRequested()
            Self.markExcludedFromBackup(targetDir)
            try? fileManager.removeItem(at: stagingRoot)
            await state.finishRepositoryDownload()
            await completeBackgroundEventsAfterPostprocessing()
            if !isBackgroundSession { session.finishTasksAndInvalidate() }
        } catch {
            // A failure (or cancellation) mid-download: tear down any remaining
            // in-flight URLSession tasks so the caller doesn't wait for them.
            await state.requestCancellation()
            await state.finishRepositoryDownload()
            await completeBackgroundEventsAfterPostprocessing()
            if !isBackgroundSession { session.invalidateAndCancel() }
            throw error
        }
    }

    /// Cancel all in-flight downloads. Await before deleting staging so delegate callbacks
    /// don't race against a removed directory.
    public func cancel() async {
        await state.requestCancellation()
    }

    private func throwIfCancellationRequested() async throws {
        if Task.isCancelled {
            throw DownloadError.cancelled
        }
        if await state.cancellationRequested() {
            throw DownloadError.cancelled
        }
    }

    /// Remove orphan or stale tasks when no durable request is eligible for adoption.
    public func cancelAllSessionTasks() async {
        let tasks = await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
        await withTaskGroup(of: Void.self) { group in
            for case let task as URLSessionDownloadTask in tasks {
                group.addTask {
                    await withCheckedContinuation { continuation in
                        task.cancel { _ in continuation.resume() }
                    }
                }
            }
        }
        await state.requestCancellation()
    }

    private func completeBackgroundEventsAfterPostprocessing() async {
        guard isBackgroundSession,
              let identifier = session.configuration.identifier,
              await state.markPostprocessingFinished() else { return }
        backgroundSessionCompletionHandler?(identifier)
    }

    private func reconcileBackgroundTasks(expected: [String: ModelDownloadTaskIdentity]) async {
        let tasks = await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
        var existing: [ModelDownloadExistingTask] = []
        var validIdentityByTaskID: [Int: ModelDownloadTaskIdentity] = [:]
        for task in tasks {
            var validIdentity: ModelDownloadTaskIdentity?
            if let identity = ModelDownloadTaskIdentity.decode(taskDescription: task.taskDescription),
               let expectedIdentity = expected[identity.relativePath],
               identity == expectedIdentity,
               let taskURL = task.originalRequest?.url,
               await state.expectedIdentity(for: taskURL) == expectedIdentity {
                validIdentity = identity
                validIdentityByTaskID[task.taskIdentifier] = identity
            }
            existing.append(ModelDownloadExistingTask(
                taskID: task.taskIdentifier,
                identity: validIdentity
            ))
        }
        let plan = ModelDownloadTaskReconciler.plan(
            expected: Array(expected.values),
            existing: existing
        )
        let cancelled = Set(plan.cancelledTaskIDs)
        for task in tasks {
            guard !cancelled.contains(task.taskIdentifier),
                  let downloadTask = task as? URLSessionDownloadTask,
                  let identity = validIdentityByTaskID[task.taskIdentifier],
                  await state.adopt(task: downloadTask, identity: identity) else {
                task.cancel()
                continue
            }
        }
    }

    // MARK: - Private: List Files

    private func listFiles(repo: String, revision: String) async throws -> [RepoFile] {
        let url = Self.repositoryTreeURL(apiBaseURL: apiBaseURL, repo: repo, revision: revision)

        let (data, response) = try await session.data(from: url)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DownloadError.apiError("API returned HTTP \(http.statusCode)")
        }

        return try Self.repoFiles(fromAPIData: data)
    }

    static func repositoryTreeURL(apiBaseURL: URL, repo: String, revision: String) -> URL {
        apiBaseURL
            .appendingPathComponent(repo)
            .appendingPathComponent("tree")
            .appendingPathComponent(revision)
            .appending(queryItems: [URLQueryItem(name: "recursive", value: "true")])
    }

    static func fileResolveURL(
        resolveBaseURL: URL,
        repo: String,
        revision: String,
        relativePath: String
    ) throws -> URL {
        let validatedRelativePath = try validatedRelativeRepoPath(relativePath)
        return resolveBaseURL
            .appendingPathComponent(repo)
            .appendingPathComponent("resolve")
            .appendingPathComponent(revision)
            .appendingPathComponent(validatedRelativePath)
    }

    // MARK: - Private: Download Files

    /// Download every file concurrently (up to `maxConcurrentFileDownloads` at a time),
    /// staging each into `filesRoot`. Repository progress aggregates across all files
    /// that are in flight. A single file failure cancels the rest and throws.
    private func downloadAllFiles(
        _ files: [RepoFile],
        repo: String,
        revision: String,
        artifactVersion: String,
        filesRoot: URL,
        partialRoot: URL,
        resumeRoot: URL
    ) async throws {
        guard !files.isEmpty else { return }

        // The phase is already `.downloading` (from `beginRepositoryDownload`); any
        // partial files on disk are resumed silently, per-file, via Range requests in
        // `downloadTemporaryFile`. macOS has no pause/resume UI, so we never surface a
        // "Resuming" phase — that was a vestige of the discarded pause/resume feature.
        let maxConcurrent = min(max(1, engineConfiguration.maxConcurrentFiles), files.count)

        try await withThrowingTaskGroup(of: Void.self) { group in
            var fileIterator = files.enumerated().makeIterator()

            // Prime the group with up to `maxConcurrent` file downloads.
            for _ in 0..<maxConcurrent {
                guard let (index, file) = fileIterator.next() else { break }
                group.addTask { [self] in
                    try await self.downloadOneFileCancelingPeers(
                        file,
                        fileIndex: index,
                        repo: repo,
                        revision: revision,
                        artifactVersion: artifactVersion,
                        filesRoot: filesRoot,
                        partialRoot: partialRoot,
                        resumeRoot: resumeRoot
                    )
                }
            }

            // Drain: each time a file finishes, start the next (bounded concurrency).
            while try await group.next() != nil {
                if await state.cancellationRequested() {
                    throw DownloadError.cancelled
                }
                guard let (index, file) = fileIterator.next() else { continue }
                group.addTask { [self] in
                    try await self.downloadOneFileCancelingPeers(
                        file,
                        fileIndex: index,
                        repo: repo,
                        revision: revision,
                        artifactVersion: artifactVersion,
                        filesRoot: filesRoot,
                        partialRoot: partialRoot,
                        resumeRoot: resumeRoot
                    )
                }
            }
        }
    }

    /// Stage a single file (skip if already valid, else download + validate into the
    /// staging tree), then report completion so the shared progress counter reconciles.
    private func downloadOneFile(
        _ file: RepoFile,
        fileIndex: Int,
        repo: String,
        revision: String,
        artifactVersion: String,
        filesRoot: URL,
        partialRoot: URL,
        resumeRoot: URL
    ) async throws {
        if await state.cancellationRequested() {
            throw DownloadError.cancelled
        }

        let relativePath = try Self.validatedRelativeRepoPath(file.path)
        let destURL = try Self.validatedDestinationURL(for: relativePath, in: filesRoot)
        let partialURL = try Self.partialURL(for: relativePath, in: partialRoot)
        let resumeDataURL = Self.resumeDataURL(for: relativePath, in: resumeRoot)
        try fileManager.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: partialURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fileIsValid(at: destURL, expectedSize: file.size, sha256: file.sha256) {
            try await recordVerifiedReceipt(
                relativePath: relativePath,
                artifactVersion: artifactVersion,
                expectedSize: file.size,
                expectedSHA256: file.sha256,
                fileURL: destURL
            )
            await state.reportFileCompleted(fileIndex: fileIndex, expectedSize: file.size)
            return
        }

        if fileManager.fileExists(atPath: destURL.path) {
            try? fileManager.removeItem(at: destURL)
        }

        let downloadURL = try file.absoluteURL ?? Self.fileResolveURL(
            resolveBaseURL: resolveBaseURL,
            repo: repo,
            revision: revision,
            relativePath: relativePath
        )
        if let artifactURLPolicy, !artifactURLPolicy.allowsInitialRequest(downloadURL) {
            throw DownloadError.apiError("Rejected untrusted artifact URL for \(relativePath)")
        }

        try await downloadFile(
            from: downloadURL,
            to: destURL,
            partialURL: partialURL,
            resumeDataURL: resumeDataURL,
            expectedSize: file.size,
            sha256: file.sha256,
            fileIndex: fileIndex
        )

        try await recordVerifiedReceipt(
            relativePath: relativePath,
            artifactVersion: artifactVersion,
            expectedSize: file.size,
            expectedSHA256: file.sha256,
            fileURL: destURL
        )

        await state.reportFileCompleted(fileIndex: fileIndex, expectedSize: file.size)
    }

    /// Wraps `downloadOneFile` so that when any file fails it immediately cancels every
    /// other in-flight download. Without this, a `ThrowingTaskGroup` failure would leave
    /// sibling URLSession tasks running until they complete naturally, stalling teardown.
    private func downloadOneFileCancelingPeers(
        _ file: RepoFile,
        fileIndex: Int,
        repo: String,
        revision: String,
        artifactVersion: String,
        filesRoot: URL,
        partialRoot: URL,
        resumeRoot: URL
    ) async throws {
        do {
            try await downloadOneFile(
                file,
                fileIndex: fileIndex,
                repo: repo,
                revision: revision,
                artifactVersion: artifactVersion,
                filesRoot: filesRoot,
                partialRoot: partialRoot,
                resumeRoot: resumeRoot
            )
        } catch {
            await state.requestCancellation()
            throw error
        }
    }

    private func downloadFile(
        from url: URL,
        to destination: URL,
        partialURL: URL,
        resumeDataURL: URL,
        expectedSize: Int64,
        sha256: String?,
        fileIndex: Int
    ) async throws {
        if fileIsValid(at: partialURL, expectedSize: expectedSize, sha256: sha256) {
            try publishDownloadedFile(partialURL, to: destination)
            return
        }

        // Retry transient failures (network drops, HTTP 5xx/429, integrity mismatches)
        // so a single hiccup no longer fails the whole repo download. The partial
        // already on disk lets each attempt resume via a Range request.
        var retryNumber = 0
        var integrityRetryUsed = false
        var avoidChunking = false
        while true {
            do {
                // Clear any stale task state for this file from a prior failed attempt so
                // its bytes don't inflate the progress counter during the retry.
                await state.resetFileProgress(fileIndex: fileIndex)
                try await attemptFileDownload(
                    from: url,
                    to: destination,
                    partialURL: partialURL,
                    resumeDataURL: resumeDataURL,
                    expectedSize: expectedSize,
                    sha256: sha256,
                    fileIndex: fileIndex,
                    avoidChunking: avoidChunking
                )
                return
            } catch {
                if let dlError = error as? DownloadError {
                    // The server ignored a byte-range request — fall back to single-stream
                    // for the remaining attempts instead of thrashing on chunks. The chunked
                    // attempt may have left a sparse/holey partial, so clear it too.
                    if case .rangeUnsupported = dlError {
                        avoidChunking = true
                        try? fileManager.removeItem(at: partialURL)
                    }
                    // Any chunk-related failure (integrity mismatch or assembly error) is not
                    // a simple transient network error; retry as a single stream instead.
                    if case .integrityCheckFailed = dlError {
                        avoidChunking = true
                    }
                    if case .chunkAssemblyFailed = dlError {
                        avoidChunking = true
                        try? fileManager.removeItem(at: partialURL)
                    }
                }

                retryNumber += 1
                let disposition = ModelDownloadRetryPolicy.disposition(
                    error: error,
                    retryNumber: retryNumber,
                    integrityRetryAlreadyUsed: integrityRetryUsed
                )
                let delay: Double
                switch disposition {
                case .cancelled, .fail:
                    throw error
                case .retry(let afterSeconds):
                    delay = afterSeconds
                case .retryClean(let afterSeconds):
                    delay = afterSeconds
                    try? fileManager.removeItem(at: partialURL)
                    try? fileManager.removeItem(at: resumeDataURL)
                    if let dlError = error as? DownloadError,
                       case .integrityCheckFailed = dlError {
                        integrityRetryUsed = true
                    }
                }

                guard retryNumber <= engineConfiguration.maxDownloadRetries else { throw error }
                guard !Task.isCancelled,
                      !(await state.cancellationRequested()) else {
                    throw DownloadError.cancelled
                }
                await state.setRetry(number: retryNumber, reason: retryReason(for: error))
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    throw DownloadError.cancelled
                }
                guard !Task.isCancelled,
                      !(await state.cancellationRequested()) else {
                    throw DownloadError.cancelled
                }
                await state.setPhase(.downloading)
            }
        }
    }

    /// A single (un-retried) attempt to stage one file.
    private func attemptFileDownload(
        from url: URL,
        to destination: URL,
        partialURL: URL,
        resumeDataURL: URL,
        expectedSize: Int64,
        sha256: String?,
        fileIndex: Int,
        avoidChunking: Bool
    ) async throws {
        // Large LFS files (known size + sha256) download as parallel byte-range chunks so
        // the biggest file is no longer a single-connection long pole. Smaller / non-LFS
        // files — or chunked attempts that already saw the server ignore Range — use the
        // single-stream path below.
        if !avoidChunking, engineConfiguration.chunkLargeFiles,
           expectedSize >= engineConfiguration.chunkedDownloadThreshold, sha256 != nil {
            try? fileManager.removeItem(at: resumeDataURL)
            try await downloadChunkedFile(
                from: url,
                to: destination,
                partialURL: partialURL,
                expectedSize: expectedSize,
                sha256: sha256,
                fileIndex: fileIndex
            )
            return
        }

        let completedBytes = Self.fileSizeIfPresent(at: partialURL)
        let downloaded = try await downloadTemporaryFile(
            from: url,
            existingBytes: completedBytes,
            resumeDataURL: resumeDataURL,
            fileIndex: fileIndex
        )

        if await state.cancellationRequested() {
            try? fileManager.removeItem(at: downloaded.url)
            throw DownloadError.cancelled
        }

        if completedBytes > 0, downloaded.statusCode == 206,
           !Self.contentRange(downloaded.contentRange, startsAt: completedBytes) {
            try? fileManager.removeItem(at: downloaded.url)
            try? fileManager.removeItem(at: partialURL)
            throw DownloadError.rangeUnsupported(path: url.path)
        }

        try applyDownloadedTemporaryFile(
            downloaded,
            partialURL: partialURL,
            existingBytes: completedBytes
        )
        try Self.validateDownloadedFile(
            at: partialURL,
            expectedSize: expectedSize,
            sha256: sha256
        )
        try? fileManager.removeItem(at: resumeDataURL)
        try publishDownloadedFile(partialURL, to: destination)
    }

    private func retryReason(for error: Error) -> String {
        if let downloadError = error as? DownloadError {
            switch downloadError {
            case .httpError(let statusCode, _, _): return "HTTP \(statusCode)"
            case .integrityCheckFailed: return "Integrity verification"
            case .rangeUnsupported: return "Range response"
            case .chunkAssemblyFailed: return "Chunk assembly"
            case .fileDownloadFailed: return "Network transfer"
            case .cancelled: return "Cancelled"
            case .invalidRemotePath, .invalidLocalDestination, .apiError: return "Configuration"
            }
        }
        return "Network transfer"
    }

    /// Download a large file as parallel byte-range chunks, assembling them into the
    /// partial, then validating size + SHA-256 (same gate as the single-stream path).
    /// Each chunk is its own `URLSessionDownloadTask` registered under the same
    /// `fileIndex`, so progress aggregates via the per-task counters. A single chunk
    /// failure cancels its siblings and bubbles to the file-level retry.
    private func downloadChunkedFile(
        from url: URL,
        to destination: URL,
        partialURL: URL,
        expectedSize: Int64,
        sha256: String?,
        fileIndex: Int
    ) async throws {
        // A partial from a prior single-stream or chunked attempt that isn't the expected
        // size would leave holes; drop it so chunks write a clean file.
        if Self.fileSizeIfPresent(at: partialURL) != expectedSize {
            try? fileManager.removeItem(at: partialURL)
        }

        let chunkSize = max(engineConfiguration.chunkTargetSize, expectedSize / Int64(engineConfiguration.maxConcurrentFiles))
        let ranges = Self.byteRanges(total: expectedSize, chunkSize: chunkSize)

        let assembly = ChunkAssemblyCoordinator(partialURL: partialURL)
        try await assembly.open()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (chunkIndex, range) in ranges.enumerated() {
                    group.addTask { [self] in
                        try await self.downloadOneChunk(
                            url: url,
                            start: range.start,
                            end: range.end,
                            chunkIndex: chunkIndex,
                            fileIndex: fileIndex,
                            assembly: assembly
                        )
                    }
                }
                try await group.waitForAll()
            }
            await assembly.close()
            try Self.validateDownloadedFile(at: partialURL, expectedSize: expectedSize, sha256: sha256)
            try publishDownloadedFile(partialURL, to: destination)
        } catch {
            await assembly.close()
            throw error
        }
    }

    /// Download one byte-range `[start, end]` (inclusive) of `url` and write it into the
    /// partial at offset `start`. Throws if the server ignores the Range request (200).
    private func downloadOneChunk(
        url: URL,
        start: Int64,
        end: Int64,
        chunkIndex: Int,
        fileIndex: Int,
        assembly: ChunkAssemblyCoordinator
    ) async throws {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        let downloaded = try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: request)
            Task {
                let shouldResume = await state.register(
                    task: task,
                    destination: url,
                    continuation: continuation,
                    resumeDataURL: nil,
                    fileIndex: fileIndex
                )
                if shouldResume { task.resume() }
            }
        }

        // The delegate treats 200 and 206 as success; for a range request 200 means the
        // server ignored Range and returned the whole file — throw a dedicated error so the
        // file-level retry falls back to a single stream instead of thrashing on chunks.
        guard downloaded.statusCode == 206,
              Self.contentRange(downloaded.contentRange, matchesStart: start, end: end) else {
            try? fileManager.removeItem(at: downloaded.url)
            throw DownloadError.rangeUnsupported(path: url.path)
        }

        if await state.cancellationRequested() {
            try? fileManager.removeItem(at: downloaded.url)
            throw DownloadError.cancelled
        }

        try await assembly.writeChunk(tempURL: downloaded.url, offset: start)
        try? fileManager.removeItem(at: downloaded.url)
    }

    /// Partition `[0, total)` into inclusive `[start, end]` byte ranges of `chunkSize`.
    private static func byteRanges(total: Int64, chunkSize: Int64) -> [(start: Int64, end: Int64)] {
        guard total > 0, chunkSize > 0 else { return [] }
        var ranges: [(start: Int64, end: Int64)] = []
        var start: Int64 = 0
        while start < total {
            let end = min(start + chunkSize - 1, total - 1)
            ranges.append((start, end))
            start = end + 1
        }
        return ranges
    }

    static func contentRange(_ value: String?, startsAt expectedStart: Int64) -> Bool {
        guard let value,
              let match = value.range(
                of: #"^bytes\s+([0-9]+)-([0-9]+)/(?:[0-9]+|\*)$"#,
                options: [.regularExpression, .caseInsensitive]
              ) else { return false }
        let matched = String(value[match])
        guard let rangePart = matched.split(separator: " ").last?.split(separator: "/").first,
              let start = rangePart.split(separator: "-").first.flatMap({ Int64($0) }) else {
            return false
        }
        return start == expectedStart
    }

    static func contentRange(_ value: String?, matchesStart expectedStart: Int64, end expectedEnd: Int64) -> Bool {
        guard contentRange(value, startsAt: expectedStart),
              let value,
              let rangePart = value.split(separator: " ").last?.split(separator: "/").first else {
            return false
        }
        let bounds = rangePart.split(separator: "-")
        guard bounds.count == 2, let end = Int64(bounds[1]) else { return false }
        return end == expectedEnd
    }

    private func downloadTemporaryFile(
        from url: URL,
        existingBytes: Int64,
        resumeDataURL: URL,
        fileIndex: Int
    ) async throws -> DownloadedTemporaryFile {
        if Task.isCancelled {
            throw DownloadError.cancelled
        }
        if await state.cancellationRequested() {
            throw DownloadError.cancelled
        }

        if let adoptedTask = await state.takeAdoptedTask(for: url) {
            return try await withCheckedThrowingContinuation { continuation in
                Task {
                    let receivedBytes = max(existingBytes, adoptedTask.countOfBytesReceived)
                    let shouldResume = await state.register(
                        task: adoptedTask,
                        destination: url,
                        continuation: continuation,
                        resumeDataURL: resumeDataURL,
                        fileIndex: fileIndex,
                        existingBytes: receivedBytes
                    )
                    if shouldResume, adoptedTask.state == .suspended {
                        adoptedTask.resume()
                    }
                }
            }
        }

        if fileManager.fileExists(atPath: resumeDataURL.path),
           let resumeData = try? Data(contentsOf: resumeDataURL) {
            do {
                return try await withCheckedThrowingContinuation { continuation in
                    let task = session.downloadTask(withResumeData: resumeData)
                    Task {
                        task.taskDescription = await state.expectedIdentity(for: url)?.encodedTaskDescription
                        let shouldResume = await state.register(
                            task: task,
                            destination: url,
                            continuation: continuation,
                            resumeDataURL: resumeDataURL,
                            fileIndex: fileIndex,
                            existingBytes: existingBytes
                        )
                        if shouldResume { task.resume() }
                    }
                }
            } catch {
                try? fileManager.removeItem(at: resumeDataURL)
                if Task.isCancelled {
                    throw DownloadError.cancelled
                }
                if await state.cancellationRequested() {
                    throw DownloadError.cancelled
                }
            }
        }

        if Task.isCancelled {
            throw DownloadError.cancelled
        }
        if await state.cancellationRequested() {
            throw DownloadError.cancelled
        }
        let request = Self.downloadRequest(for: url, existingBytes: existingBytes)
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: request)
            Task {
                task.taskDescription = await state.expectedIdentity(for: url)?.encodedTaskDescription
                let shouldResume = await state.register(
                    task: task,
                    destination: url,
                    continuation: continuation,
                    resumeDataURL: resumeDataURL,
                    fileIndex: fileIndex,
                    existingBytes: existingBytes
                )
                if shouldResume { task.resume() }
            }
        }
    }

    private func applyDownloadedTemporaryFile(
        _ downloaded: DownloadedTemporaryFile,
        partialURL: URL,
        existingBytes: Int64
    ) throws {
        defer { try? fileManager.removeItem(at: downloaded.url) }

        if existingBytes > 0, downloaded.statusCode == 206 {
            let readHandle = try FileHandle(forReadingFrom: downloaded.url)
            defer { try? readHandle.close() }
            let writeHandle = try FileHandle(forWritingTo: partialURL)
            defer { try? writeHandle.close() }
            try writeHandle.seekToEnd()
            while autoreleasepool(invoking: {
                let data = readHandle.readData(ofLength: 1_048_576)
                guard !data.isEmpty else { return false }
                writeHandle.write(data)
                return true
            }) {}
            try? writeHandle.synchronize()
            return
        }

        if fileManager.fileExists(atPath: partialURL.path) {
            try fileManager.removeItem(at: partialURL)
        }
        try fileManager.moveItem(at: downloaded.url, to: partialURL)
    }

    private func publishDownloadedFile(_ fileURL: URL, to destination: URL) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: fileURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: fileURL, to: destination)
        }
    }

    private func recordVerifiedReceipt(
        relativePath: String,
        artifactVersion: String,
        expectedSize: Int64,
        expectedSHA256: String?,
        fileURL: URL
    ) async throws {
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modificationDate = attributes[.modificationDate] as? Date ?? .distantPast
        let fileIdentifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let receipt = VerifiedArtifactReceipt(
            relativePath: relativePath,
            artifactVersion: artifactVersion,
            expectedSize: expectedSize,
            expectedSHA256: Self.normalizedSHA256(expectedSHA256),
            fileSize: fileSize,
            modificationTimeNanoseconds: Int64(modificationDate.timeIntervalSince1970 * 1_000_000_000),
            fileIdentifier: fileIdentifier,
            verificationProcessGeneration: verificationProcessGeneration
        )
        await state.recordVerifiedReceipt(receipt)
        await verifiedArtifactHandler?.handler(receipt)
    }

    private func verifyDownloadedFilesUsingReceipts(
        _ files: [RepoFile],
        artifactVersion: String,
        in root: URL
    ) async throws {
        let receipts = await state.verifiedReceipts()
        for file in files {
            let relativePath = try Self.validatedRelativeRepoPath(file.path)
            let destination = try Self.validatedDestinationURL(for: relativePath, in: root)
            let attributes = try fileManager.attributesOfItem(atPath: destination.path)
            let currentSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let currentModificationDate = attributes[.modificationDate] as? Date ?? .distantPast
            let currentModificationNanoseconds = Int64(
                currentModificationDate.timeIntervalSince1970 * 1_000_000_000
            )
            let currentFileIdentifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            guard let receipt = receipts[relativePath],
                  receipt.matches(
                    relativePath: relativePath,
                    artifactVersion: artifactVersion,
                    expectedSize: file.size,
                    expectedSHA256: Self.normalizedSHA256(file.sha256),
                    fileSize: currentSize,
                    modificationTimeNanoseconds: currentModificationNanoseconds,
                    fileIdentifier: currentFileIdentifier,
                    processGeneration: verificationProcessGeneration
                  ) else {
                throw DownloadError.integrityCheckFailed(
                    path: relativePath,
                    reason: "missing or changed same-process verification receipt"
                )
            }
        }
    }

    private func installStagedRepository(filesRoot: URL, targetDir: URL) throws {
        let installParent = targetDir.deletingLastPathComponent()
        try fileManager.createDirectory(at: installParent, withIntermediateDirectories: true)

        let installingURL = installParent
            .appendingPathComponent(".\(targetDir.lastPathComponent).installing.\(UUID().uuidString)", isDirectory: true)
        if fileManager.fileExists(atPath: installingURL.path) {
            try fileManager.removeItem(at: installingURL)
        }
        try fileManager.moveItem(at: filesRoot, to: installingURL)

        if fileManager.fileExists(atPath: targetDir.path) {
            _ = try fileManager.replaceItemAt(
                targetDir,
                withItemAt: installingURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: installingURL, to: targetDir)
        }
    }

    private func persistInstalledIntegrityManifest(
        repo: String,
        revision: String,
        targetDir: URL,
        files: [RepoFile],
        filesRoot: URL
    ) throws {
        let manifest = ModelAssetIntegrityManifest(
            repo: repo,
            revision: revision,
            targetFolder: targetDir.lastPathComponent,
            createdAtUTC: ISO8601DateFormatter().string(from: Date()),
            files: files.map {
                ModelAssetIntegrityManifest.FileEntry(
                    path: $0.path,
                    size: $0.size,
                    sha256: $0.sha256
                )
            }
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(
            to: filesRoot.appendingPathComponent(ModelAssetIntegrityManifest.filename, isDirectory: false),
            options: .atomic
        )
    }

    private func persistDownloadState(
        repo: String,
        revision: String,
        targetDir: URL,
        files: [RepoFile],
        stagingRoot: URL
    ) throws {
        let manifest = DownloadStateManifest(
            schemaVersion: 1,
            repo: repo,
            revision: revision,
            targetFolder: targetDir.lastPathComponent,
            updatedAtUTC: ISO8601DateFormatter().string(from: Date()),
            files: files.map {
                DownloadStateManifest.FileEntry(
                    path: $0.path,
                    size: $0.size,
                    sha256: $0.sha256
                )
            }
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(
            to: stagingRoot.appendingPathComponent("download-state.json"),
            options: .atomic
        )
    }

    private func fileIsValid(at url: URL, expectedSize: Int64, sha256: String?) -> Bool {
        do {
            try Self.validateDownloadedFile(at: url, expectedSize: expectedSize, sha256: sha256)
            return true
        } catch {
            return false
        }
    }

    private static func stagingRoot(forTargetDirectory targetDir: URL) -> URL {
        targetDir
            .deletingLastPathComponent()
            .appendingPathComponent(".qwenvoice-downloads", isDirectory: true)
            .appendingPathComponent(targetDir.lastPathComponent, isDirectory: true)
    }

    /// Remove the staging tree (partials, resume data, staged files) for a target
    /// directory. Call when a model is permanently deleted so failed/partial downloads
    /// don't orphan multi-GB under `.qwenvoice-downloads/`. Best-effort.
    public static func discardStaging(forTargetDirectory targetDir: URL) {
        try? FileManager.default.removeItem(at: stagingRoot(forTargetDirectory: targetDir))
    }

    /// Mark `url` excluded from Time Machine/backup (best-effort). Inlined here so the
    /// downloader has no app-target dependency and can live in the shared QwenVoiceCore
    /// module (used by the macOS app, the iOS app, and the `vocello` CLI alike).
    private static func markExcludedFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    private static func partialURL(for relativePath: String, in root: URL) throws -> URL {
        try validatedDestinationURL(for: relativePath, in: root)
            .appendingPathExtension("partial")
    }

    private static func resumeDataURL(for relativePath: String, in root: URL) -> URL {
        let safeName = relativePath
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: ":", with: "_")
        return root.appendingPathComponent("\(safeName).resume")
    }

    private static func fileSizeIfPresent(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return 0 }
        return Int64(values.fileSize ?? 0)
    }

    // MARK: - URLSessionDownloadDelegate

    /// Background sessions only: the system calls this when the session has finished delivering
    /// all enqueued events (e.g. after it relaunched the app to complete a background download).
    /// Forward the session's identifier so iOS can flush its app-delegate completion handler.
    /// Foreground sessions (macOS/CLI) never trigger this, so they're unaffected.
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task {
            if await state.markBackgroundEventsFinished() {
                backgroundSessionCompletionHandler?(identifier)
            }
        }
    }

    public func urlSession(
        _ session: URLSession,
        taskIsWaitingForConnectivity task: URLSessionTask
    ) {
        Task { await state.setWaitingForConnectivity(true) }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let artifactURLPolicy else {
            completionHandler(request)
            return
        }
        let sourceURL = response.url ?? task.currentRequest?.url ?? task.originalRequest?.url
        guard let destinationURL = request.url,
              artifactURLPolicy.allowsRedirect(from: sourceURL, to: destinationURL) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskID = downloadTask.taskIdentifier
        Task {
            await state.setWaitingForConnectivity(false)
            await state.reportProgress(taskID: taskID, totalBytesWritten: totalBytesWritten)
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskID = downloadTask.taskIdentifier

        let response = downloadTask.response as? HTTPURLResponse
        let statusCode = response?.statusCode
        let retryAfterSeconds = Self.retryAfterSeconds(from: response)
        let contentRange = response?.value(forHTTPHeaderField: "Content-Range")
        if let statusCode, ![200, 206].contains(statusCode) {
            Task {
                let path = await state.destinationPath(taskID: taskID)
                await state.resumeFailure(
                    taskID: taskID,
                    error: DownloadError.httpError(
                        statusCode: statusCode,
                        path: path,
                        retryAfterSeconds: retryAfterSeconds
                    )
                )
            }
            return
        }

        let safeTmp = durableTemporaryDirectory
            .appendingPathComponent("task-\(taskID)-\(UUID().uuidString)")

        do {
            try fileManager.createDirectory(at: durableTemporaryDirectory, withIntermediateDirectories: true)
            try fileManager.moveItem(at: location, to: safeTmp)
            Task {
                await state.stageSuccess(
                    taskID: taskID,
                    identity: ModelDownloadTaskIdentity.decode(taskDescription: downloadTask.taskDescription),
                    temporaryFile: DownloadedTemporaryFile(
                        url: safeTmp,
                        statusCode: statusCode,
                        retryAfterSeconds: retryAfterSeconds,
                        contentRange: contentRange
                    )
                )
            }
        } catch {
            Task {
                await state.resumeFailure(taskID: taskID, error: error)
            }
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard let transferMetricsHandler else { return }
        let transactions = metrics.transactionMetrics
        let last = transactions.last
        let identity = ModelDownloadTaskIdentity.decode(taskDescription: task.taskDescription)
        transferMetricsHandler.handler(
            TransferMetrics(
                relativePath: identity?.relativePath,
                protocolName: last?.networkProtocolName,
                redirectCount: metrics.redirectCount,
                reusedConnection: transactions.contains(where: { $0.isReusedConnection }),
                cellular: transactions.contains(where: { $0.isCellular }),
                constrained: transactions.contains(where: { $0.isConstrained }),
                expensive: transactions.contains(where: { $0.isExpensive }),
                transferredBytes: task.countOfBytesReceived,
                durationSeconds: metrics.taskInterval.duration
            )
        )
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskID = task.taskIdentifier
        Task {
            await state.setWaitingForConnectivity(false)
            guard let error else {
                await state.completeStagedSuccess(taskID: taskID)
                return
            }
            let path = await state.destinationPath(taskID: taskID)
            if (error as NSError).code == NSURLErrorCancelled {
                await state.resumeFailure(taskID: taskID, error: DownloadError.cancelled)
            } else {
                await state.resumeFailure(
                    taskID: taskID,
                    error: DownloadError.fileDownloadFailed(path: path, underlying: error)
                )
            }
        }
    }

    private static func retryAfterSeconds(from response: HTTPURLResponse?) -> Double? {
        guard let value = response?.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return min(max(seconds, 0), 300)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return min(max(date.timeIntervalSinceNow, 0), 300)
    }
}
