import Foundation
import Combine

@MainActor
protocol BatchGenerationBridging: AnyObject {
    func generateCustomFlow(
        modelID: String,
        text: String,
        voice: String,
        emotion: String,
        outputPath: String,
        batchIndex: Int?,
        batchTotal: Int?
    ) async throws -> GenerationResult

    func generateDesignFlow(
        modelID: String,
        text: String,
        voiceDescription: String,
        emotion: String,
        outputPath: String,
        batchIndex: Int?,
        batchTotal: Int?
    ) async throws -> GenerationResult

    func generateCloneFlow(
        modelID: String,
        text: String,
        refAudio: String,
        refText: String?,
        emotion: String,
        outputPath: String,
        batchIndex: Int?,
        batchTotal: Int?
    ) async throws -> GenerationResult

    func cancelActiveGenerationAndRestart(pythonPath: String, appSupportDir: String) async throws
    func clearGenerationActivity()
}

protocol GenerationPersisting {
    func saveGeneration(_ generation: inout Generation) throws
}

extension PythonBridge: BatchGenerationBridging { }
extension DatabaseService: GenerationPersisting { }

struct BatchGenerationRequest {
    let mode: GenerationMode
    let model: TTSModel
    let lines: [String]
    let voice: String?
    let emotion: String?
    let voiceDescription: String?
    let refAudio: String?
    let refText: String?

    func validationError(modelsDirectory: URL) -> String? {
        guard model.isAvailable(in: modelsDirectory) else {
            return "Model '\(model.name)' is unavailable or incomplete. Go to Settings > Models to download or re-download it."
        }

        if mode == .design && (voiceDescription ?? "").isEmpty {
            return "Enter a voice description before starting batch generation."
        }

        if mode == .clone && refAudio == nil {
            return "Select a reference audio file before starting batch generation."
        }

        return nil
    }

    func makeHistoryRecord(for line: String, result: GenerationResult) -> Generation {
        let voiceName: String?
        switch mode {
        case .custom:
            voiceName = voice
        case .design:
            voiceName = voiceDescription
        case .clone:
            if let voice {
                voiceName = voice
            } else if let refAudio {
                voiceName = URL(fileURLWithPath: refAudio).deletingPathExtension().lastPathComponent
            } else {
                voiceName = nil
            }
        }

        return Generation(
            text: line,
            mode: model.mode.rawValue,
            modelTier: model.tier,
            voice: voiceName,
            emotion: emotion,
            speed: nil,
            audioPath: result.audioPath,
            duration: result.durationSeconds,
            createdAt: Date()
        )
    }
}

enum BatchGenerationOutcome: Equatable {
    case completed(completedCount: Int)
    case cancelled(completedCount: Int)
}

@MainActor
final class BatchGenerationCoordinator: ObservableObject {
    @Published private(set) var isProcessing = false
    @Published private(set) var isCancelling = false
    @Published private(set) var currentIndex = 0
    @Published private(set) var totalItems = 0
    @Published var errorMessage: String?

    private var runner: BatchGenerationRunner?
    private var runTask: Task<Void, Never>?
    private var cancelTask: Task<Void, Never>?
    private var cancelRestartFailed = false

    func startBatch(
        batchText: String,
        requestBuilder: ([String]) -> BatchGenerationRequest?,
        bridge: any BatchGenerationBridging,
        store: any GenerationPersisting = DatabaseService.shared,
        dismiss: @escaping () -> Void
    ) {
        let lines = batchText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return }
        guard let request = requestBuilder(lines) else {
            errorMessage = "Model configuration not found"
            return
        }

        if let validationError = request.validationError(modelsDirectory: QwenVoiceApp.modelsDir) {
            errorMessage = validationError
            return
        }

        let runner = BatchGenerationRunner(
            bridge: bridge,
            store: store
        )

        self.runner = runner
        runTask?.cancel()
        cancelTask = nil
        cancelRestartFailed = false
        isProcessing = true
        isCancelling = false
        errorMessage = nil
        totalItems = lines.count
        currentIndex = 0

        runTask = Task { [weak self] in
            guard let self else { return }

            do {
                let outcome = try await runner.run(
                    request: request,
                    makeOutputPath: { makeOutputPath(subfolder: $0, text: $1) },
                    onItemStarted: { [weak self] index, total in
                        self?.currentIndex = index
                        self?.totalItems = total
                    }
                )

                if case .cancelled = outcome, let cancelTask = self.cancelTask {
                    await cancelTask.value
                }

                if self.cancelRestartFailed {
                    self.isProcessing = false
                    self.isCancelling = false
                    self.runner = nil
                    self.runTask = nil
                    return
                }

                self.isProcessing = false
                self.isCancelling = false
                self.runner = nil
                self.runTask = nil
                dismiss()
            } catch {
                self.errorMessage = error.localizedDescription
                self.isProcessing = false
                self.isCancelling = false
                self.runner = nil
                self.runTask = nil
            }
        }
    }

    func cancelBatch(
        pythonPath: String?,
        dismiss: @escaping () -> Void
    ) {
        guard isProcessing else {
            dismiss()
            return
        }

        guard !isCancelling else { return }
        guard let runner else {
            isProcessing = false
            dismiss()
            return
        }
        guard let pythonPath, !pythonPath.isEmpty else {
            errorMessage = "Batch generation was interrupted, but the backend could not be restarted because the Python runtime path is unavailable."
            return
        }

        isCancelling = true
        errorMessage = nil
        cancelRestartFailed = false
        cancelTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await runner.requestCancellation(
                    pythonPath: pythonPath,
                    appSupportDir: AppPaths.appSupportDir.path
                )
            } catch {
                self.cancelRestartFailed = true
                self.errorMessage = "Batch generation was interrupted, but the backend could not be restarted: \(error.localizedDescription)"
                self.isProcessing = false
                self.isCancelling = false
                self.runner = nil
                self.runTask = nil
            }
        }
    }
}

@MainActor
final class BatchGenerationRunner {
    private let bridge: any BatchGenerationBridging
    private let store: any GenerationPersisting
    private let cancellationState = BatchGenerationCancellationState()

    init(
        bridge: any BatchGenerationBridging,
        store: any GenerationPersisting
    ) {
        self.bridge = bridge
        self.store = store
    }

    func run(
        request: BatchGenerationRequest,
        makeOutputPath: (String, String) -> String,
        onItemStarted: @escaping @MainActor (Int, Int) -> Void
    ) async throws -> BatchGenerationOutcome {
        var completedCount = 0
        let total = request.lines.count

        for (index, line) in request.lines.enumerated() {
            if await cancellationState.isRequested {
                bridge.clearGenerationActivity()
                return .cancelled(completedCount: completedCount)
            }

            onItemStarted(index, total)

            let outputPath = makeOutputPath(request.model.outputSubfolder, line)
            do {
                let result = try await generateResult(
                    for: request,
                    line: line,
                    outputPath: outputPath,
                    batchIndex: index + 1,
                    batchTotal: total
                )

                var generation = request.makeHistoryRecord(for: line, result: result)
                try store.saveGeneration(&generation)
                NotificationCenter.default.post(name: .generationSaved, object: nil)
                completedCount += 1
            } catch {
                if await cancellationState.isRequested, case PythonBridgeError.cancelled = error {
                    bridge.clearGenerationActivity()
                    return .cancelled(completedCount: completedCount)
                }
                throw error
            }
        }

        if await cancellationState.isRequested {
            bridge.clearGenerationActivity()
            return .cancelled(completedCount: completedCount)
        }

        return .completed(completedCount: completedCount)
    }

    func requestCancellation(pythonPath: String, appSupportDir: String) async throws {
        await cancellationState.request()
        try await bridge.cancelActiveGenerationAndRestart(
            pythonPath: pythonPath,
            appSupportDir: appSupportDir
        )
    }

    private func generateResult(
        for request: BatchGenerationRequest,
        line: String,
        outputPath: String,
        batchIndex: Int,
        batchTotal: Int
    ) async throws -> GenerationResult {
        switch request.mode {
        case .custom:
            return try await bridge.generateCustomFlow(
                modelID: request.model.id,
                text: line,
                voice: request.voice ?? TTSModel.defaultSpeaker,
                emotion: request.emotion ?? "Normal tone",
                outputPath: outputPath,
                batchIndex: batchIndex,
                batchTotal: batchTotal
            )
        case .design:
            return try await bridge.generateDesignFlow(
                modelID: request.model.id,
                text: line,
                voiceDescription: request.voiceDescription ?? "",
                emotion: request.emotion ?? "Normal tone",
                outputPath: outputPath,
                batchIndex: batchIndex,
                batchTotal: batchTotal
            )
        case .clone:
            return try await bridge.generateCloneFlow(
                modelID: request.model.id,
                text: line,
                refAudio: request.refAudio ?? "",
                refText: request.refText,
                emotion: request.emotion ?? "Normal tone",
                outputPath: outputPath,
                batchIndex: batchIndex,
                batchTotal: batchTotal
            )
        }
    }
}

actor BatchGenerationCancellationState {
    private(set) var isRequested = false

    func request() {
        isRequested = true
    }
}
