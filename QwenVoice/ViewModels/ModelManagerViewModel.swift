import Foundation

/// Manages model download/delete state for ModelsView.
@MainActor
final class ModelManagerViewModel: ObservableObject {

    enum ModelStatus: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded(sizeBytes: Int)
    }

    @Published var statuses: [String: ModelStatus] = [:]

    private var downloadTasks: [String: URLSessionDownloadTask] = [:]

    func refresh() async {
        let modelsDir = QwenVoiceApp.modelsDir

        for model in TTSModel.all {
            let modelDir = modelsDir.appendingPathComponent(model.folder)
            if FileManager.default.fileExists(atPath: modelDir.path) {
                let size = Self.directorySize(url: modelDir)
                statuses[model.id] = .downloaded(sizeBytes: size)
            } else {
                if case .downloading = statuses[model.id] {
                    // Keep downloading state
                } else {
                    statuses[model.id] = .notDownloaded
                }
            }
        }
    }

    func download(_ model: TTSModel) async {
        statuses[model.id] = .downloading(progress: 0)

        let modelsDir = QwenVoiceApp.modelsDir
        let targetDir = modelsDir.appendingPathComponent(model.folder)

        guard let pythonPath = PythonBridge.findPython() else {
            statuses[model.id] = .notDownloaded
            return
        }

        let script = """
from huggingface_hub import snapshot_download
snapshot_download(repo_id='\(model.huggingFaceRepo)', local_dir='\(targetDir.path)', repo_type='model')
"""

        let pollTask = Task {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(2))
                let currentSize = Self.directorySize(url: targetDir)
                let estimatedTotal = 800_000_000
                let progress = min(0.95, Double(currentSize) / Double(estimatedTotal))
                statuses[model.id] = .downloading(progress: progress)
            }
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: pythonPath)
                process.arguments = ["-c", script]
                process.currentDirectoryURL = modelsDir
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                nonisolated(unsafe) var resumed = false

                process.terminationHandler = { proc in
                    guard !resumed else { return }
                    resumed = true
                    if proc.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: NSError(domain: "ModelDownload", code: Int(proc.terminationStatus)))
                    }
                }

                do {
                    try process.run()
                } catch {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: error)
                }
            }

            pollTask.cancel()
            let size = Self.directorySize(url: targetDir)
            statuses[model.id] = .downloaded(sizeBytes: size)
        } catch {
            pollTask.cancel()
            statuses[model.id] = .notDownloaded
        }
    }

    func cancelDownload(_ model: TTSModel) {
        downloadTasks[model.id]?.cancel()
        downloadTasks.removeValue(forKey: model.id)
        statuses[model.id] = .notDownloaded
    }

    func delete(_ model: TTSModel) async {
        let modelDir = QwenVoiceApp.modelsDir.appendingPathComponent(model.folder)
        try? FileManager.default.removeItem(at: modelDir)
        statuses[model.id] = .notDownloaded
    }

    private static func directorySize(url: URL) -> Int {
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
}
