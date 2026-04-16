import Foundation

/// Downloads a HuggingFace model repository using native URLSession.
final class HuggingFaceDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    struct RepositoryProgress: Equatable, Sendable {
        let downloadedBytes: Int64
        let totalBytes: Int64
        let completedFiles: Int
        let totalFiles: Int
        let bytesPerSecond: Int64?
        let isStalled: Bool
    }

    enum DownloadError: LocalizedError {
        case cancelled
        case httpError(statusCode: Int, path: String)
        case fileDownloadFailed(path: String, underlying: Error)
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
    }

    final class ProgressHandlerBox: @unchecked Sendable {
        let handler: (Int64) -> Void

        init(_ handler: @escaping (Int64) -> Void) {
            self.handler = handler
        }
    }

    final class RepositoryProgressHandlerBox: @unchecked Sendable {
        let handler: (RepositoryProgress) -> Void

        init(_ handler: @escaping (RepositoryProgress) -> Void) {
            self.handler = handler
        }
    }

    final class TaskCancellationBox: @unchecked Sendable {
        private let cancellation: () -> Void

        init(task: URLSessionDownloadTask) {
            self.cancellation = { task.cancel() }
        }

        func cancel() {
            cancellation()
        }
    }

    actor DownloadStateRegistry {
        private var isCancelled = false
        private var activeTaskID: Int?
        private var activeCancellation: TaskCancellationBox?
        private var continuations: [Int: CheckedContinuation<URL, Error>] = [:]
        private var destinations: [Int: URL] = [:]
        private var progressHandlers: [Int: ProgressHandlerBox] = [:]
        private let repositoryProgressHandler: RepositoryProgressHandlerBox?
        private var repositoryTotalBytes: Int64 = 0
        private var repositoryDownloadedBytes: Int64 = 0
        private var repositoryTotalFiles = 0
        private var repositoryCompletedFiles = 0
        private var lastProgressAdvanceTime: TimeInterval?
        private var lastSpeedSampleTime: TimeInterval?
        private var lastSpeedSampleBytes: Int64 = 0
        private var lastMeasuredBytesPerSecond: Int64?
        private var heartbeatTask: Task<Void, Never>?

        init(repositoryProgressHandler: RepositoryProgressHandlerBox?) {
            self.repositoryProgressHandler = repositoryProgressHandler
        }

        func resetForNewRepositoryDownload() {
            isCancelled = false
            activeTaskID = nil
            activeCancellation = nil
            repositoryTotalBytes = 0
            repositoryDownloadedBytes = 0
            repositoryTotalFiles = 0
            repositoryCompletedFiles = 0
            lastProgressAdvanceTime = nil
            lastSpeedSampleTime = nil
            lastSpeedSampleBytes = 0
            lastMeasuredBytesPerSecond = nil
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }

        func beginRepositoryDownload(totalBytes: Int64, totalFiles: Int) {
            repositoryTotalBytes = max(0, totalBytes)
            repositoryDownloadedBytes = 0
            repositoryTotalFiles = max(0, totalFiles)
            repositoryCompletedFiles = 0
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
            continuation: CheckedContinuation<URL, Error>,
            progressHandler: ProgressHandlerBox
        ) {
            let taskID = task.taskIdentifier
            activeTaskID = taskID
            activeCancellation = TaskCancellationBox(task: task)
            continuations[taskID] = continuation
            destinations[taskID] = destination
            progressHandlers[taskID] = progressHandler
        }

        func requestCancellation() {
            isCancelled = true
            activeCancellation?.cancel()
        }

        func cancellationRequested() -> Bool {
            isCancelled
        }

        func reportProgress(taskID: Int, totalBytesWritten: Int64) {
            progressHandlers[taskID]?.handler(totalBytesWritten)
        }

        func reportRepositoryProgress(downloadedBytes: Int64, completedFiles: Int) {
            let now = ProcessInfo.processInfo.systemUptime
            let clampedBytes = min(max(0, downloadedBytes), repositoryTotalBytes)
            let clampedCompletedFiles = min(max(0, completedFiles), repositoryTotalFiles)

            if clampedBytes > repositoryDownloadedBytes {
                if let previousSpeedSampleTime = lastSpeedSampleTime {
                    let elapsed = max(now - previousSpeedSampleTime, 0.001)
                    let deltaBytes = clampedBytes - lastSpeedSampleBytes
                    if deltaBytes > 0 {
                        lastMeasuredBytesPerSecond = Int64(Double(deltaBytes) / elapsed)
                        lastSpeedSampleTime = now
                        lastSpeedSampleBytes = clampedBytes
                    }
                } else {
                    lastSpeedSampleTime = now
                    lastSpeedSampleBytes = clampedBytes
                }
                lastProgressAdvanceTime = now
            }

            repositoryDownloadedBytes = clampedBytes
            repositoryCompletedFiles = clampedCompletedFiles
            emitRepositoryProgress(isStalled: false)
        }

        func finishRepositoryDownload() {
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }

        func resumeSuccess(taskID: Int, temporaryURL: URL) {
            let continuation = continuations.removeValue(forKey: taskID)
            destinations.removeValue(forKey: taskID)
            progressHandlers.removeValue(forKey: taskID)
            clearActiveTaskIfNeeded(taskID: taskID)
            continuation?.resume(returning: temporaryURL)
        }

        func resumeFailure(taskID: Int, error: Error) {
            let continuation = continuations.removeValue(forKey: taskID)
            destinations.removeValue(forKey: taskID)
            progressHandlers.removeValue(forKey: taskID)
            clearActiveTaskIfNeeded(taskID: taskID)
            continuation?.resume(throwing: error)
        }

        func destinationPath(taskID: Int) -> String {
            destinations[taskID]?.lastPathComponent ?? "unknown"
        }

        private func clearActiveTaskIfNeeded(taskID: Int) {
            guard activeTaskID == taskID else { return }
            activeTaskID = nil
            activeCancellation = nil
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
            guard let activeTaskID else { return }
            guard activeTaskID >= 0 else { return }

            let now = ProcessInfo.processInfo.systemUptime
            guard let lastProgressAdvanceTime, now - lastProgressAdvanceTime >= 1.5 else {
                return
            }
            emitRepositoryProgress(isStalled: true)
        }

        private func emitRepositoryProgress(isStalled: Bool) {
            repositoryProgressHandler?.handler(
                RepositoryProgress(
                    downloadedBytes: repositoryDownloadedBytes,
                    totalBytes: repositoryTotalBytes,
                    completedFiles: repositoryCompletedFiles,
                    totalFiles: repositoryTotalFiles,
                    bytesPerSecond: lastMeasuredBytesPerSecond,
                    isStalled: isStalled
                )
            )
        }
    }

    private var session: URLSession!
    private let state: DownloadStateRegistry

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

    convenience override init() {
        self.init(progressHandler: nil)
    }

    init(progressHandler: ((RepositoryProgress) -> Void)?) {
        let progressBox = progressHandler.map(RepositoryProgressHandlerBox.init)
        state = DownloadStateRegistry(repositoryProgressHandler: progressBox)
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Public API

    /// Download all files from a HuggingFace repo into `targetDir`.
    func downloadRepo(repo: String, to targetDir: URL) async throws {
        await state.resetForNewRepositoryDownload()

        let files = try await listFiles(repo: repo)
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        await state.beginRepositoryDownload(totalBytes: totalBytes, totalFiles: files.count)

        var completedBytes: Int64 = 0
        var completedFiles = 0

        do {
            for file in files {
                guard !(await state.cancellationRequested()) else {
                    await state.finishRepositoryDownload()
                    throw DownloadError.cancelled
                }

                let relativePath = try Self.validatedRelativeRepoPath(file.path)
                let destURL = try Self.validatedDestinationURL(for: relativePath, in: targetDir)
                let parentDir = destURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

                let downloadURL = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(relativePath)")!
                let baseCompletedBytes = completedBytes
                let baseCompletedFiles = completedFiles

                try await downloadFile(
                    from: downloadURL,
                    to: destURL,
                    progressHandler: ProgressHandlerBox { [state] bytesWritten in
                        Task {
                            await state.reportRepositoryProgress(
                                downloadedBytes: baseCompletedBytes + bytesWritten,
                                completedFiles: baseCompletedFiles
                            )
                        }
                    }
                )

                completedBytes += file.size
                completedFiles += 1
                await state.reportRepositoryProgress(
                    downloadedBytes: completedBytes,
                    completedFiles: completedFiles
                )
            }
            await state.finishRepositoryDownload()
        } catch {
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

    private func listFiles(repo: String) async throws -> [RepoFile] {
        let urlString = "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true"
        guard let url = URL(string: urlString) else {
            throw DownloadError.apiError("Invalid repo URL")
        }

        let (data, response) = try await session.data(from: url)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DownloadError.apiError("API returned HTTP \(http.statusCode)")
        }

        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DownloadError.apiError("Unexpected API response format")
        }

        return items.compactMap { item -> RepoFile? in
            guard let type = item["type"] as? String, type == "file",
                  let path = item["path"] as? String,
                  path != ".gitattributes" else { return nil }

            let size: Int64
            if let lfs = item["lfs"] as? [String: Any], let lfsSize = lfs["size"] as? Int64 {
                size = lfsSize
            } else if let s = item["size"] as? Int64 {
                size = s
            } else if let s = item["size"] as? Int {
                size = Int64(s)
            } else {
                size = 0
            }

            return RepoFile(path: path, size: size)
        }
    }

    // MARK: - Private: Download Single File

    private func downloadFile(
        from url: URL,
        to destination: URL,
        progressHandler: ProgressHandlerBox
    ) async throws {
        let temporaryURL: URL
        do {
            temporaryURL = try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: url)
                Task {
                    await state.register(
                        task: task,
                        destination: destination,
                        continuation: continuation,
                        progressHandler: progressHandler
                    )
                    task.resume()
                }
            }
        } catch {
            throw error
        }

        if await state.cancellationRequested() {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw DownloadError.cancelled
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: temporaryURL, to: destination)
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

        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            Task {
                let path = await state.destinationPath(taskID: taskID)
                await state.resumeFailure(
                    taskID: taskID,
                    error: DownloadError.httpError(statusCode: http.statusCode, path: path)
                )
            }
            return
        }

        let safeTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        do {
            try FileManager.default.moveItem(at: location, to: safeTmp)
            Task {
                await state.resumeSuccess(taskID: taskID, temporaryURL: safeTmp)
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
