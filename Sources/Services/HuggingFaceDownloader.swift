import CryptoKit
import Foundation

/// Downloads a HuggingFace model repository using native URLSession.
final class HuggingFaceDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    enum DownloadPhase: String, Equatable, Sendable {
        case downloading
        case interrupted
        case resuming
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
        let targetFolder: String
        let updatedAtUTC: String
        let files: [FileEntry]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case repo
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
        private var activeTaskID: Int?
        private var activeCancellation: TaskCancellationBox?
        private var continuations: [Int: CheckedContinuation<DownloadedTemporaryFile, Error>] = [:]
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
        private var phase: DownloadPhase = .downloading
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
            phase = .downloading
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }

        func beginRepositoryDownload(totalBytes: Int64, totalFiles: Int, phase: DownloadPhase = .downloading) {
            repositoryTotalBytes = max(0, totalBytes)
            repositoryDownloadedBytes = 0
            repositoryTotalFiles = max(0, totalFiles)
            repositoryCompletedFiles = 0
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
            progressHandler: ProgressHandlerBox,
            resumeDataURL: URL?
        ) {
            let taskID = task.taskIdentifier
            activeTaskID = taskID
            activeCancellation = TaskCancellationBox(task: task, resumeDataURL: resumeDataURL)
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

        func setPhase(_ phase: DownloadPhase) {
            self.phase = phase
            emitRepositoryProgress(isStalled: false)
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

        func resumeSuccess(taskID: Int, temporaryFile: DownloadedTemporaryFile) {
            let continuation = continuations.removeValue(forKey: taskID)
            destinations.removeValue(forKey: taskID)
            progressHandlers.removeValue(forKey: taskID)
            clearActiveTaskIfNeeded(taskID: taskID)
            continuation?.resume(returning: temporaryFile)
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
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Public API

    /// Download all files from a HuggingFace repo into `targetDir`.
    func downloadRepo(repo: String, to targetDir: URL) async throws {
        await state.resetForNewRepositoryDownload()

        let files = try await listFiles(repo: repo)
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        await state.beginRepositoryDownload(totalBytes: totalBytes, totalFiles: files.count)

        let stagingRoot = Self.stagingRoot(forTargetDirectory: targetDir)
        let filesRoot = stagingRoot.appendingPathComponent("files", isDirectory: true)
        let partialRoot = stagingRoot.appendingPathComponent("partials", isDirectory: true)
        let resumeRoot = stagingRoot.appendingPathComponent("resume-data", isDirectory: true)
        try fileManager.createDirectory(at: filesRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: partialRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resumeRoot, withIntermediateDirectories: true)
        try persistDownloadState(
            repo: repo,
            targetDir: targetDir,
            files: files,
            stagingRoot: stagingRoot
        )

        var completedBytes: Int64 = 0
        var completedFiles = 0

        do {
            for file in files {
                guard !(await state.cancellationRequested()) else {
                    await state.finishRepositoryDownload()
                    throw DownloadError.cancelled
                }

                let relativePath = try Self.validatedRelativeRepoPath(file.path)
                let destURL = try Self.validatedDestinationURL(for: relativePath, in: filesRoot)
                let partialURL = try Self.partialURL(for: relativePath, in: partialRoot)
                let resumeDataURL = Self.resumeDataURL(for: relativePath, in: resumeRoot)
                try fileManager.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.createDirectory(at: partialURL.deletingLastPathComponent(), withIntermediateDirectories: true)

                if fileIsValid(at: destURL, expectedSize: file.size, sha256: file.sha256) {
                    completedBytes += file.size
                    completedFiles += 1
                    await state.reportRepositoryProgress(
                        downloadedBytes: completedBytes,
                        completedFiles: completedFiles
                    )
                    continue
                }

                if fileManager.fileExists(atPath: destURL.path) {
                    try? fileManager.removeItem(at: destURL)
                }

                let partialBytes = Self.fileSizeIfPresent(at: partialURL)
                if partialBytes > 0 || fileManager.fileExists(atPath: resumeDataURL.path) {
                    await state.setPhase(.resuming)
                } else {
                    await state.setPhase(.downloading)
                }

                let downloadURL = resolveBaseURL
                    .appendingPathComponent(repo)
                    .appendingPathComponent("resolve")
                    .appendingPathComponent("main")
                    .appendingPathComponent(relativePath)
                let baseCompletedBytes = completedBytes
                let baseCompletedFiles = completedFiles

                try await downloadFile(
                    from: downloadURL,
                    to: destURL,
                    partialURL: partialURL,
                    resumeDataURL: resumeDataURL,
                    expectedSize: file.size,
                    sha256: file.sha256,
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
            await state.setPhase(.verifying)
            try verifyDownloadedFiles(files, in: filesRoot)
            await state.setPhase(.installing)
            try installStagedRepository(filesRoot: filesRoot, targetDir: targetDir)
            try? fileManager.removeItem(at: stagingRoot)
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
        let url = apiBaseURL
            .appendingPathComponent(repo)
            .appendingPathComponent("tree")
            .appendingPathComponent("main")
            .appending(queryItems: [URLQueryItem(name: "recursive", value: "true")])

        let (data, response) = try await session.data(from: url)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DownloadError.apiError("API returned HTTP \(http.statusCode)")
        }

        return try Self.repoFiles(fromAPIData: data)
    }

    // MARK: - Private: Download Single File

    private func downloadFile(
        from url: URL,
        to destination: URL,
        partialURL: URL,
        resumeDataURL: URL,
        expectedSize: Int64,
        sha256: String?,
        progressHandler: ProgressHandlerBox
    ) async throws {
        if fileIsValid(at: partialURL, expectedSize: expectedSize, sha256: sha256) {
            try publishDownloadedFile(partialURL, to: destination)
            return
        }

        let completedBytes = Self.fileSizeIfPresent(at: partialURL)
        let downloaded = try await downloadTemporaryFile(
            from: url,
            existingBytes: completedBytes,
            resumeDataURL: resumeDataURL,
            progressHandler: progressHandler
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

    private func downloadTemporaryFile(
        from url: URL,
        existingBytes: Int64,
        resumeDataURL: URL,
        progressHandler: ProgressHandlerBox
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
                            progressHandler: progressHandler,
                            resumeDataURL: resumeDataURL
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
                    progressHandler: progressHandler,
                    resumeDataURL: resumeDataURL
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

    private func persistDownloadState(
        repo: String,
        targetDir: URL,
        files: [RepoFile],
        stagingRoot: URL
    ) throws {
        let manifest = DownloadStateManifest(
            schemaVersion: 1,
            repo: repo,
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
