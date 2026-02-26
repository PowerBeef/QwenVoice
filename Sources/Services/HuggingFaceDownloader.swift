import Foundation

/// Downloads a HuggingFace model repository using native URLSession.
final class HuggingFaceDownloader: NSObject, URLSessionDownloadDelegate {

    enum DownloadError: LocalizedError {
        case cancelled
        case httpError(statusCode: Int, path: String)
        case fileDownloadFailed(path: String, underlying: Error)
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Download cancelled"
            case .httpError(let code, let path):
                return "HTTP \(code) downloading \(path)"
            case .fileDownloadFailed(let path, let underlying):
                return "Failed to download \(path): \(underlying.localizedDescription)"
            case .apiError(let message):
                return message
            }
        }
    }

    struct RepoFile {
        let path: String
        let size: Int64
    }

    /// Callback: (bytesDownloaded, bytesTotal)
    var onProgress: ((Int64, Int64) -> Void)?

    private var isCancelled = false
    private var session: URLSession!

    /// Tracks the active download task for cancellation.
    private var activeTask: URLSessionDownloadTask?

    /// Bridge from delegate callbacks to async/await.
    /// Keyed by task.taskIdentifier.
    private var continuations: [Int: CheckedContinuation<URL, Error>] = [:]
    private var destinations: [Int: URL] = [:]

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600 // 1 hour max per file
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Public API

    /// Download all files from a HuggingFace repo into `targetDir`.
    func downloadRepo(repo: String, to targetDir: URL) async throws {
        let files = try await listFiles(repo: repo)
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        onProgress?(0, totalBytes)

        var completedBytes: Int64 = 0

        for file in files {
            guard !isCancelled else { throw DownloadError.cancelled }

            let destURL = targetDir.appendingPathComponent(file.path)
            let parentDir = destURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            let downloadURL = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file.path)")!
            let finalCompletedBytes = completedBytes

            try await downloadFile(
                from: downloadURL,
                to: destURL,
                fileSize: file.size,
                progressHandler: { [weak self] bytesWritten in
                    self?.onProgress?(finalCompletedBytes + bytesWritten, totalBytes)
                }
            )

            completedBytes += file.size
            onProgress?(completedBytes, totalBytes)
        }
    }

    /// Cancel all in-flight downloads.
    func cancel() {
        isCancelled = true
        activeTask?.cancel()
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

            // Size may be in "size" or inside "lfs.size"
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

    /// Bytes written by the currently active download task (updated by delegate).
    private var currentTaskBytesWritten: Int64 = 0
    private var currentProgressHandler: ((Int64) -> Void)?

    private func downloadFile(
        from url: URL,
        to destination: URL,
        fileSize: Int64,
        progressHandler: @escaping (Int64) -> Void
    ) async throws {
        currentTaskBytesWritten = 0
        currentProgressHandler = progressHandler

        let tempURL: URL = try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: url)
            let taskID = task.taskIdentifier
            continuations[taskID] = continuation
            destinations[taskID] = destination
            activeTask = task
            task.resume()
        }

        // Move downloaded temp file to final destination
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempURL, to: destination)

        activeTask = nil
        currentProgressHandler = nil
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        currentTaskBytesWritten = totalBytesWritten
        currentProgressHandler?(totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskID = downloadTask.taskIdentifier

        // Check HTTP status
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            let path = destinations[taskID]?.lastPathComponent ?? "unknown"
            continuations[taskID]?.resume(throwing: DownloadError.httpError(statusCode: http.statusCode, path: path))
            continuations.removeValue(forKey: taskID)
            destinations.removeValue(forKey: taskID)
            return
        }

        // Move to a safe temp location (the delegate location is deleted after this method returns)
        let safeTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: safeTmp)
            continuations[taskID]?.resume(returning: safeTmp)
        } catch {
            continuations[taskID]?.resume(throwing: error)
        }
        continuations.removeValue(forKey: taskID)
        destinations.removeValue(forKey: taskID)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskID = task.taskIdentifier
        guard let error = error else { return } // Success handled in didFinishDownloadingTo

        if (error as NSError).code == NSURLErrorCancelled {
            continuations[taskID]?.resume(throwing: DownloadError.cancelled)
        } else {
            let path = destinations[taskID]?.lastPathComponent ?? "unknown"
            continuations[taskID]?.resume(throwing: DownloadError.fileDownloadFailed(path: path, underlying: error))
        }
        continuations.removeValue(forKey: taskID)
        destinations.removeValue(forKey: taskID)
    }
}
