import Foundation
import QwenVoiceCore

/// Resume-data marker used by the simulated backend. It is not interpreted by
/// `URLSession`; it simply records the byte offset to continue from.
private struct IOSSimulatedModelDownloadResumeData: Codable, Sendable {
    let relativePath: String
    let offset: Int64
}

/// Simulator-only backend that mimics multi-file model downloads without a
/// network. It reports progress against the real catalog sizes but writes tiny
/// placeholder files, so installs complete quickly and without consuming disk.
actor IOSSimulatedModelDownloadBackend: IOSModelDownloadBackend {
    let delegate: IOSModelDeliveryDownloadDelegate
    let requiresDownloadVerification: Bool = false

    private var activeTasks: [IOSModelDownloadTaskDescription: Task<Void, Never>] = [:]
    private var currentOffsets: [IOSModelDownloadTaskDescription: Int64] = [:]
    private var nextTaskIdentifier: Int = 1
    private let perFileDelayNanoseconds: UInt64

    init(delegate: IOSModelDeliveryDownloadDelegate) {
        self.delegate = delegate
        let rawMs = ProcessInfo.processInfo.environment["QVOICE_SIM_BACKEND_DELAY_MS"].flatMap(Int.init) ?? 2_000
        let clampedMs = max(0, min(rawMs, 30_000))
        let scenario = IOSSimulatedDownloadScenario.current
        let scaledMs = clampedMs * scenario.delayMultiplier
        self.perFileDelayNanoseconds = UInt64(scaledMs) * 1_000_000
        self.scenario = scenario
    }

    private let scenario: IOSSimulatedDownloadScenario

    func startDownload(
        taskDescription: IOSModelDownloadTaskDescription,
        entry: IOSModelCatalogEntry,
        file: IOSModelCatalogFile,
        resumeData: Data?
    ) async throws {
        let startOffset: Int64
        if let resumeData,
           let decoded = try? JSONDecoder().decode(IOSSimulatedModelDownloadResumeData.self, from: resumeData),
           decoded.relativePath == taskDescription.relativePath {
            startOffset = decoded.offset
        } else {
            startOffset = 0
        }

        let totalBytes = file.sizeBytes
        let taskIdentifier = nextTaskIdentifier
        nextTaskIdentifier += 1

        let task = Task {
            await runDownload(
                taskIdentifier: taskIdentifier,
                taskDescription: taskDescription,
                totalBytes: totalBytes,
                startOffset: startOffset
            )
        }
        activeTasks[taskDescription] = task
        currentOffsets[taskDescription] = startOffset
    }

    func pause(taskDescription: IOSModelDownloadTaskDescription) async -> Data? {
        guard let task = activeTasks[taskDescription] else { return nil }
        task.cancel()
        await task.value
        let offset = currentOffsets[taskDescription] ?? 0
        activeTasks.removeValue(forKey: taskDescription)
        currentOffsets.removeValue(forKey: taskDescription)
        let marker = IOSSimulatedModelDownloadResumeData(
            relativePath: taskDescription.relativePath,
            offset: offset
        )
        return try? JSONEncoder().encode(marker)
    }

    func cancel(taskDescription: IOSModelDownloadTaskDescription) async {
        activeTasks[taskDescription]?.cancel()
        activeTasks.removeValue(forKey: taskDescription)
        currentOffsets.removeValue(forKey: taskDescription)
    }

    func cancelAllTasks(for modelID: String) async {
        for (description, task) in activeTasks where description.modelID == modelID {
            task.cancel()
        }
        activeTasks = activeTasks.filter { $0.key.modelID != modelID }
        currentOffsets = currentOffsets.filter { $0.key.modelID != modelID }
    }

    func activeTaskCount() async -> Int {
        activeTasks.count
    }

    func hasTask(for taskDescription: IOSModelDownloadTaskDescription) async -> Bool {
        activeTasks[taskDescription] != nil
    }

    // MARK: - Private

    private func runDownload(
        taskIdentifier: Int,
        taskDescription: IOSModelDownloadTaskDescription,
        totalBytes: Int64,
        startOffset: Int64
    ) async {
        let encodedDescription = encodeTaskDescription(taskDescription)
        let remainingBytes = max(0, totalBytes - startOffset)
        let chunkCount = max(5, 20)
        let chunkSize = max(remainingBytes / Int64(chunkCount), 1)
        let delayPerChunk = perFileDelayNanoseconds / UInt64(chunkCount)

        var offset = startOffset
        for chunkIndex in 0..<chunkCount {
            guard !Task.isCancelled else { break }
            offset = min(offset + chunkSize, totalBytes)
            currentOffsets[taskDescription] = offset
            delegate.onProgress?(
                taskIdentifier,
                encodedDescription,
                offset,
                totalBytes
            )

            if scenario == .failMid, chunkIndex >= chunkCount / 2 {
                let error = NSError(
                    domain: "IOSSimulatedModelDownloadBackend",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Simulated mid-download failure."]
                )
                delegate.onCompleted?(taskIdentifier, encodedDescription, error)
                await taskCompleted(taskDescription: taskDescription)
                return
            }

            if offset < totalBytes {
                do {
                    try await Task.sleep(nanoseconds: delayPerChunk)
                } catch {
                    break
                }
            }
        }

        guard !Task.isCancelled else {
            let error = NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCancelled,
                userInfo: [NSLocalizedDescriptionKey: "Download cancelled."]
            )
            delegate.onCompleted?(taskIdentifier, encodedDescription, error)
            await taskCompleted(taskDescription: taskDescription)
            return
        }

        // Final progress at the full size before finishing.
        delegate.onProgress?(
            taskIdentifier,
            encodedDescription,
            totalBytes,
            totalBytes
        )

        let safeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        let content = Data(
            "Vocello simulated model file for \(taskDescription.modelID)/\(taskDescription.relativePath)".utf8
        )
        do {
            try content.write(to: safeURL, options: .atomic)
            delegate.onFinished?(taskIdentifier, encodedDescription, safeURL)
        } catch {
            delegate.onCompleted?(taskIdentifier, encodedDescription, error)
        }

        await taskCompleted(taskDescription: taskDescription)
    }

    private func taskCompleted(taskDescription: IOSModelDownloadTaskDescription) {
        activeTasks.removeValue(forKey: taskDescription)
        currentOffsets.removeValue(forKey: taskDescription)
    }
}
