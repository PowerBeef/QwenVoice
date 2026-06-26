import CryptoKit
import Foundation
import QwenVoiceCore

/// Downloads a HuggingFace model repository using native URLSession.
final class HuggingFaceDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    enum DownloadPhase: String, Equatable, Sendable {
        case downloading
        case verifying
        case installing
    }

    struct RepositoryProgress: Equatable, Sendable {
        let downloadedBytes: Int64
        let totalBytes: Int64
        let completedFiles: Int
        let totalFiles: Int
        let bytesPerSecond: Int64?
        let isStalled: Bool
        let phase: DownloadPhase
    }

    enum DownloadError: LocalizedError {
        case cancelled
        case httpError(statusCode: Int, path: String)
        case fileDownloadFailed(path: String, underlying: Error)
        case integrityCheckFailed(path: String, reason: String)
        case invalidRemotePath(String)
        case invalidLocalDestination(String)
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Download cancelled"
            case .httpError(let code, let path):
                return "HTTP \(code) downloading \(path)"
            case .fileDownloadFailed(let path, let underlying):
                return "Failed to download \(path): \(underlying.localizedDescription)"
            case .integrityCheckFailed(let path, let reason):
                return "Downloaded file failed integrity checks for \(path): \(reason)"
            case .invalidRemotePath(let path):
                return "Rejected unsafe remote path: \(path)"
            case .invalidLocalDestination(let path):
                return "Rejected unsafe local destination: \(path)"
            case .apiError(let message):
                return message
            }
        }
    }

    struct RepoFile {
        let path: String
        let size: Int64
        let sha256: String?
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
    }

    final class RepositoryProgressHandlerBox: @unchecked Sendable {
        let handler: (RepositoryProgress) -> Void

        init(_ handler: @escaping (RepositoryProgress) -> Void) {
            self.handler = handler
        }
    }

    final class TaskCancellationBox: @unchecked Sendable {
        private let cancellation: () -> Void

        init(task: URLSessionDownloadTask, resumeDataURL: URL?) {
            self.cancellation = {
                task.cancel { resumeData in
                    guard let resumeDataURL,
                          let resumeData,
                          !resumeData.isEmpty else {
                        return
                    }
                    try? FileManager.default.createDirectory(
                        at: resumeDataURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try? resumeData.write(to: resumeDataURL, options: .atomic)
                }
            }
        }

        func cancel() {
            cancellation()
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
        // Per-file bytes written so far. Monotonic per file: a resume->fresh fallback
        // never moves a file's counter backward; the final value is reconciled to the
        // file's exact size when it completes.
        private var fileProgress: [Int: Int64] = [:]
        private let repositoryProgressHandler: RepositoryProgressHandlerBox?
        private var repositoryTotalBytes: Int64 = 0
        private var repositoryDownloadedBytes: Int64 = 0
        private var repositoryTotalFiles = 0
        private var repositoryCompletedFiles = 0
        private var lastProgressAdvanceTime: TimeInterval?
        private var lastSpeedSampleTime: TimeInterval?
        private var lastSpeedSampleBytes: Int64 = 0
        private var lastMeasuredBytesPerSecond: Int64?
        private var phase: DownloadPhase = .downloading
        private var heartbeatTask: Task<Void, Never>?

        init(repositoryProgressHandler: RepositoryProgressHandlerBox?) {
            self.repositoryProgressHandler = repositoryProgressHandler
        }

        func resetForNewRepositoryDownload() {
            isCancelled = false
            activeCancellations.removeAll()
            continuations.removeAll()
            destinations.removeAll()
            taskFileIndex.removeAll()
            fileProgress.removeAll()
            repositoryTotalBytes = 0
            repositoryDownloadedBytes = 0
            repositoryTotalFiles = 0
            repositoryCompletedFiles = 0
            lastProgressAdvanceTime = nil
            lastSpeedSampleTime = nil
            lastSpeedSampleBytes = 0
            lastMeasuredBytesPerSecond = nil
            phase = .downloading
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }

        func beginRepositoryDownload(totalBytes: Int64, totalFiles: Int, phase: DownloadPhase = .downloading) {
            repositoryTotalBytes = max(0, totalBytes)
            repositoryDownloadedBytes = 0
            repositoryTotalFiles = max(0, totalFiles)
            repositoryCompletedFiles = 0
            taskFileIndex.removeAll()
            fileProgress.removeAll()
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
            fileIndex: Int
        ) {
            let taskID = task.taskIdentifier
            activeCancellations[taskID] = TaskCancellationBox(task: task, resumeDataURL: resumeDataURL)
            continuations[taskID] = continuation
            destinations[taskID] = destination
            taskFileIndex[taskID] = fileIndex
        }

        func requestCancellation() {
            isCancelled = true
            for cancellation in activeCancellations.values {
                cancellation.cancel()
            }
        }

        func cancellationRequested() -> Bool {
            isCancelled
        }

        func setPhase(_ phase: DownloadPhase) {
            self.phase = phase
            emitRepositoryProgress(isStalled: false)
        }

        /// Per-file progress from the URLSession delegate. Computes a delta against the
        /// file's last-reported bytes so several files downloading concurrently aggregate
        /// correctly into the shared repository counter. Each file's contribution is
        /// monotonic, so a resume->fresh fallback never moves the counter backward.
        func reportProgress(taskID: Int, totalBytesWritten: Int64) {
            guard let fileIndex = taskFileIndex[taskID] else { return }
            let previous = fileProgress[fileIndex] ?? 0
            let updated = max(previous, totalBytesWritten)
            let delta = updated - previous
            guard delta != 0 else { return }
            fileProgress[fileIndex] = updated
            let now = ProcessInfo.processInfo.systemUptime
            let newTotal = repositoryDownloadedBytes + delta
            applySpeedMeasurement(now: now, totalDownloaded: newTotal, advancedDelta: delta)
            repositoryDownloadedBytes = newTotal
            emitRepositoryProgress(isStalled: false)
        }

        /// A file finished (downloaded, or already-valid and skipped). Reconcile its byte
        /// contribution to the exact expected size so the final counter is precise even if
        /// the last delegate callback undershot (resume data, partial bytes, etc.).
        func reportFileCompleted(fileIndex: Int, expectedSize: Int64) {
            let counted = fileProgress.removeValue(forKey: fileIndex) ?? 0
            let reconciliation = expectedSize - counted
            if reconciliation != 0 {
                repositoryDownloadedBytes += reconciliation
            }
            repositoryCompletedFiles += 1
            emitRepositoryProgress(isStalled: false)
        }

        func finishRepositoryDownload() {
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }

        func resumeSuccess(taskID: Int, temporaryFile: DownloadedTemporaryFile) {
            let continuation = continuations.removeValue(forKey: taskID)
            destinations.removeValue(forKey: taskID)
            taskFileIndex.removeValue(forKey: taskID)
            activeCancellations.removeValue(forKey: taskID)
            continuation?.resume(returning: temporaryFile)
        }

        func resumeFailure(taskID: Int, error: Error) {
            let continuation = continuations.removeValue(forKey: taskID)
            destinations.removeValue(forKey: taskID)
            taskFileIndex.removeValue(forKey: taskID)
            activeCancellations.removeValue(forKey: taskID)
            continuation?.resume(throwing: error)
        }

        func destinationPath(taskID: Int) -> String {
            destinations[taskID]?.lastPathComponent ?? "unknown"
        }

        private func applySpeedMeasurement(now: TimeInterval, totalDownloaded: Int64, advancedDelta: Int64) {
            guard advancedDelta > 0 else { return }
            if let previousSpeedSampleTime = lastSpeedSampleTime {
                let elapsed = max(now - previousSpeedSampleTime, 0.001)
                let deltaBytes = totalDownloaded - lastSpeedSampleBytes
                if deltaBytes > 0 {
                    lastMeasuredBytesPerSecond = Int64(Double(deltaBytes) / elapsed)
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
            guard let lastProgressAdvanceTime, now - lastProgressAdvanceTime >= 1.5 else {
                return
            }
            emitRepositoryProgress(isStalled: true)
        }

        private func emitRepositoryProgress(isStalled: Bool) {
            repositoryProgressHandler?.handler(
                RepositoryProgress(
                    downloadedBytes: min(repositoryDownloadedBytes, repositoryTotalBytes),
                    totalBytes: repositoryTotalBytes,
                    completedFiles: min(repositoryCompletedFiles, repositoryTotalFiles),
                    totalFiles: repositoryTotalFiles,
                    bytesPerSecond: lastMeasuredBytesPerSecond,
                    isStalled: isStalled,
                    phase: phase
                )
            )
        }
    }

    private var session: URLSession!
    private let state: DownloadStateRegistry
    private let apiBaseURL: URL
    private let resolveBaseURL: URL
    private let fileManager: FileManager

    /// Maximum number of files downloaded concurrently within a single repo. The shared
    /// URLSession's `httpMaximumConnectionsPerHost` is set to the same value, so this
    /// bounds both the in-flight file count and the open HTTP connections to the Hub.
    static let maxConcurrentFileDownloads = 6

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

    init(
        progressHandler: ((RepositoryProgress) -> Void)?,
        sessionConfiguration: URLSessionConfiguration = .default,
        apiBaseURL: URL = URL(string: "https://huggingface.co/api/models")!,
        resolveBaseURL: URL = URL(string: "https://huggingface.co")!,
        fileManager: FileManager = .default
    ) {
        let progressBox = progressHandler.map(RepositoryProgressHandlerBox.init)
        state = DownloadStateRegistry(repositoryProgressHandler: progressBox)
        self.apiBaseURL = apiBaseURL
        self.resolveBaseURL = resolveBaseURL
        self.fileManager = fileManager
        super.init()
        let config = sessionConfiguration.copy() as? URLSessionConfiguration ?? .default
        config.timeoutIntervalForResource = 3600
        config.httpMaximumConnectionsPerHost = Self.maxConcurrentFileDownloads
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Public API

    /// Download all files from a HuggingFace repo into `targetDir`.
    func downloadRepo(repo: String, revision: String = "main", to targetDir: URL) async throws {
        await state.resetForNewRepositoryDownload()

        let files = try await listFiles(repo: repo, revision: revision)
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        await state.beginRepositoryDownload(totalBytes: totalBytes, totalFiles: files.count)

        let stagingRoot = Self.stagingRoot(forTargetDirectory: targetDir)
        let filesRoot = stagingRoot.appendingPathComponent("files", isDirectory: true)
        let partialRoot = stagingRoot.appendingPathComponent("partials", isDirectory: true)
        let resumeRoot = stagingRoot.appendingPathComponent("resume-data", isDirectory: true)
        try fileManager.createDirectory(at: filesRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: partialRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resumeRoot, withIntermediateDirectories: true)
        AppPaths.excludeFromBackup(stagingRoot)
        AppPaths.excludeFromBackup(filesRoot)
        AppPaths.excludeFromBackup(partialRoot)
        AppPaths.excludeFromBackup(resumeRoot)
        try persistDownloadState(
                repo: repo,
                revision: revision,
                targetDir: targetDir,
                files: files,
                stagingRoot: stagingRoot
        )

        do {
            try await downloadAllFiles(
                files,
                repo: repo,
                revision: revision,
                filesRoot: filesRoot,
                partialRoot: partialRoot,
                resumeRoot: resumeRoot
            )
            await state.setPhase(.verifying)
            try verifyDownloadedFiles(files, in: filesRoot)
            try persistInstalledIntegrityManifest(
                repo: repo,
                revision: revision,
                targetDir: targetDir,
                files: files,
                filesRoot: filesRoot
            )
            await state.setPhase(.installing)
            try installStagedRepository(filesRoot: filesRoot, targetDir: targetDir)
            AppPaths.excludeFromBackup(targetDir)
            try? fileManager.removeItem(at: stagingRoot)
            await state.finishRepositoryDownload()
        } catch {
            // A failure (or cancellation) mid-download: tear down any remaining
            // in-flight URLSession tasks so the caller doesn't wait for them.
            await state.requestCancellation()
            await state.finishRepositoryDownload()
            throw error
        }
    }

    /// Cancel all in-flight downloads.
    func cancel() {
        Task {
            await state.requestCancellation()
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
        filesRoot: URL,
        partialRoot: URL,
        resumeRoot: URL
    ) async throws {
        guard !files.isEmpty else { return }

        // The phase is already `.downloading` (from `beginRepositoryDownload`); any
        // partial files on disk are resumed silently, per-file, via Range requests in
        // `downloadTemporaryFile`. macOS has no pause/resume UI, so we never surface a
        // "Resuming" phase — that was a vestige of the discarded pause/resume feature.
        let maxConcurrent = min(max(1, Self.maxConcurrentFileDownloads), files.count)

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
            await state.reportFileCompleted(fileIndex: fileIndex, expectedSize: file.size)
            return
        }

        if fileManager.fileExists(atPath: destURL.path) {
            try? fileManager.removeItem(at: destURL)
        }

        let downloadURL = try Self.fileResolveURL(
            resolveBaseURL: resolveBaseURL,
            repo: repo,
            revision: revision,
            relativePath: relativePath
        )

        try await downloadFile(
            from: downloadURL,
            to: destURL,
            partialURL: partialURL,
            resumeDataURL: resumeDataURL,
            expectedSize: file.size,
            sha256: file.sha256,
            fileIndex: fileIndex
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
                filesRoot: filesRoot,
                partialRoot: partialRoot,
                resumeRoot: resumeRoot
            )
        } catch {
            await state.requestCancellation()
            throw error
        }
    }

    /// Maximum number of times a single file download is retried after a transient
    /// failure (network error, HTTP 5xx/429, integrity mismatch). Cancellation and HTTP
    /// 4xx client errors are never retried.
    private static let maxDownloadRetries = 3

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
        var attempt = 0
        while true {
            do {
                try await attemptFileDownload(
                    from: url,
                    to: destination,
                    partialURL: partialURL,
                    resumeDataURL: resumeDataURL,
                    expectedSize: expectedSize,
                    sha256: sha256,
                    fileIndex: fileIndex
                )
                return
            } catch {
                // Cancellation and non-retryable HTTP 4xx client errors fail fast.
                if let dlError = error as? DownloadError {
                    if case .cancelled = dlError { throw error }
                    if case .httpError(let code, _) = dlError,
                       (400..<500).contains(code), code != 429 {
                        throw error
                    }
                }

                attempt += 1
                guard attempt <= Self.maxDownloadRetries else { throw error }

                // A partial that failed integrity can't be resumed into a correct file;
                // clear it (and any resume blob) so the next attempt downloads fresh.
                if let dlError = error as? DownloadError, case .integrityCheckFailed = dlError {
                    try? fileManager.removeItem(at: partialURL)
                    try? fileManager.removeItem(at: resumeDataURL)
                }

                let backoff = Self.retryBackoffSeconds(for: attempt)
                try? await Task.sleep(for: .seconds(backoff))
                if Task.isCancelled {
                    throw DownloadError.cancelled
                }
                if await state.cancellationRequested() {
                    throw DownloadError.cancelled
                }
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
        fileIndex: Int
    ) async throws {
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

    /// Exponential backoff (with jitter) between retry attempts: ~1s, ~2s, ~4s, capped.
    private static func retryBackoffSeconds(for attempt: Int) -> Double {
        let base = pow(2.0, Double(attempt - 1))
        let jitter = Double.random(in: 0...0.5)
        return min(base + jitter, 10)
    }

    private func downloadTemporaryFile(
        from url: URL,
        existingBytes: Int64,
        resumeDataURL: URL,
        fileIndex: Int
    ) async throws -> DownloadedTemporaryFile {
        if fileManager.fileExists(atPath: resumeDataURL.path),
           let resumeData = try? Data(contentsOf: resumeDataURL) {
            do {
                return try await withCheckedThrowingContinuation { continuation in
                    let task = session.downloadTask(withResumeData: resumeData)
                    Task {
                        await state.register(
                            task: task,
                            destination: url,
                            continuation: continuation,
                            resumeDataURL: resumeDataURL,
                            fileIndex: fileIndex
                        )
                        task.resume()
                    }
                }
            } catch {
                try? fileManager.removeItem(at: resumeDataURL)
            }
        }

        let request = Self.downloadRequest(for: url, existingBytes: existingBytes)
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: request)
            Task {
                await state.register(
                    task: task,
                    destination: url,
                    continuation: continuation,
                    resumeDataURL: resumeDataURL,
                    fileIndex: fileIndex
                )
                task.resume()
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

    private func verifyDownloadedFiles(_ files: [RepoFile], in root: URL) throws {
        for file in files {
            let relativePath = try Self.validatedRelativeRepoPath(file.path)
            let destination = try Self.validatedDestinationURL(for: relativePath, in: root)
            try Self.validateDownloadedFile(
                at: destination,
                expectedSize: file.size,
                sha256: file.sha256
            )
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
    static func discardStaging(forTargetDirectory targetDir: URL) {
        try? FileManager.default.removeItem(at: stagingRoot(forTargetDirectory: targetDir))
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

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskID = downloadTask.taskIdentifier
        Task {
            await state.reportProgress(taskID: taskID, totalBytesWritten: totalBytesWritten)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskID = downloadTask.taskIdentifier

        let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode
        if let statusCode, ![200, 206].contains(statusCode) {
            Task {
                let path = await state.destinationPath(taskID: taskID)
                await state.resumeFailure(
                    taskID: taskID,
                    error: DownloadError.httpError(statusCode: statusCode, path: path)
                )
            }
            return
        }

        let safeTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        do {
            try FileManager.default.moveItem(at: location, to: safeTmp)
            Task {
                await state.resumeSuccess(
                    taskID: taskID,
                    temporaryFile: DownloadedTemporaryFile(url: safeTmp, statusCode: statusCode)
                )
            }
        } catch {
            Task {
                await state.resumeFailure(taskID: taskID, error: error)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskID = task.taskIdentifier
        guard let error else { return }

        Task {
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
}
