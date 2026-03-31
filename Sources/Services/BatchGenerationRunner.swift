import Foundation
import Combine

struct BatchProgressSnapshot: Equatable {
    let completedCount: Int
    let totalCount: Int
    let activeItemIndex: Int?
    let backendFraction: Double?
    let statusMessage: String

    init(
        completedCount: Int = 0,
        totalCount: Int = 0,
        activeItemIndex: Int? = nil,
        backendFraction: Double? = nil,
        statusMessage: String = ""
    ) {
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.activeItemIndex = activeItemIndex
        self.backendFraction = backendFraction
        self.statusMessage = statusMessage
    }

    var itemFraction: Double {
        guard totalCount > 0 else { return 0.0 }
        return min(max(Double(completedCount) / Double(totalCount), 0.0), 1.0)
    }

    var displayFraction: Double {
        min(max(backendFraction ?? itemFraction, 0.0), 1.0)
    }

    var itemStatusText: String {
        guard totalCount > 0 else { return "" }
        let completedText = "\(completedCount) of \(totalCount) clips completed"
        if let activeItemIndex, completedCount < totalCount {
            return "\(completedText) · Item \(min(activeItemIndex + 1, totalCount)) active"
        }
        return completedText
    }
}

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
        outputPath: String,
        batchIndex: Int?,
        batchTotal: Int?
    ) async throws -> GenerationResult

    func generateCloneBatchFlow(
        modelID: String,
        texts: [String],
        refAudio: String,
        refText: String?,
        outputPaths: [String],
        progressHandler: ((Double?, String) -> Void)?
    ) async throws -> [GenerationResult]

    func cancelActiveGenerationAndRestart(pythonPath: String, appSupportDir: String) async throws
    func clearGenerationActivity()
}

@MainActor
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

    init(
        mode: GenerationMode,
        model: TTSModel,
        lines: [String],
        voice: String?,
        emotion: String?,
        voiceDescription: String?,
        refAudio: String?,
        refText: String?
    ) {
        self.mode = mode
        self.model = model
        self.lines = lines
        self.voice = voice
        self.emotion = emotion
        self.voiceDescription = voiceDescription
        self.refAudio = refAudio
        self.refText = refText
    }

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
    @Published private(set) var progressSnapshot = BatchProgressSnapshot()
    @Published var errorMessage: String?
    @Published private(set) var outcome: BatchGenerationOutcome?

    private var runner: BatchGenerationRunner?
    private var runTask: Task<Void, Never>?
    private var cancelTask: Task<Void, Never>?
    private var cancelRestartFailed = false

    func startBatch(
        batchText: String,
        requestBuilder: ([String]) -> BatchGenerationRequest?,
        bridge: any BatchGenerationBridging,
        store: any GenerationPersisting = DatabaseService.shared
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
        outcome = nil
        progressSnapshot = BatchProgressSnapshot(
            completedCount: 0,
            totalCount: lines.count,
            activeItemIndex: lines.isEmpty ? nil : 0,
            statusMessage: "Preparing batch..."
        )

        runTask = Task { [weak self] in
            guard let self else { return }

            do {
                let outcome = try await runner.run(
                    request: request,
                    makeOutputPath: { makeOutputPath(subfolder: $0, text: $1) },
                    onProgress: { [weak self] snapshot in
                        self?.progressSnapshot = snapshot
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
                self.outcome = outcome
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
        progressSnapshot = BatchProgressSnapshot(
            completedCount: progressSnapshot.completedCount,
            totalCount: progressSnapshot.totalCount,
            activeItemIndex: progressSnapshot.activeItemIndex,
            backendFraction: progressSnapshot.backendFraction,
            statusMessage: "Cancelling..."
        )
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
        onProgress: @escaping @MainActor (BatchProgressSnapshot) -> Void
    ) async throws -> BatchGenerationOutcome {
        var completedCount = 0
        let total = request.lines.count

        if request.mode == .clone && total > 1 {
            if await cancellationState.isRequested {
                bridge.clearGenerationActivity()
                return .cancelled(completedCount: completedCount)
            }

            onProgress(
                makeProgressSnapshot(
                    completedCount: completedCount,
                    totalCount: total,
                    activeItemIndex: 0,
                    statusMessage: "Preparing batch..."
                )
            )

            let outputPaths = request.lines.map {
                makeOutputPath(request.model.outputSubfolder, $0)
            }

            do {
                let results = try await bridge.generateCloneBatchFlow(
                    modelID: request.model.id,
                    texts: request.lines,
                    refAudio: request.refAudio ?? "",
                    refText: request.refText,
                    outputPaths: outputPaths,
                    progressHandler: { fraction, message in
                        onProgress(
                            self.makeProgressSnapshot(
                                completedCount: completedCount,
                                totalCount: total,
                                activeItemIndex: completedCount < total ? completedCount : nil,
                                backendFraction: fraction,
                                statusMessage: message
                            )
                        )
                    }
                )

                guard results.count == request.lines.count else {
                    throw BatchGenerationRunnerError.unexpectedResultCount(
                        expected: request.lines.count,
                        actual: results.count
                    )
                }

                for (index, pair) in zip(request.lines, results).enumerated() {
                    if await cancellationState.isRequested {
                        bridge.clearGenerationActivity()
                        return .cancelled(completedCount: completedCount)
                    }

                    onProgress(
                        makeProgressSnapshot(
                            completedCount: completedCount,
                            totalCount: total,
                            activeItemIndex: index,
                            statusMessage: "Saving item \(index + 1)/\(total)..."
                        )
                    )

                    let (line, result) = pair
                    var generation = request.makeHistoryRecord(for: line, result: result)
                    try store.saveGeneration(&generation)
                    NotificationCenter.default.post(name: .generationSaved, object: nil)
                    completedCount += 1
                }

                onProgress(
                    makeProgressSnapshot(
                        completedCount: completedCount,
                        totalCount: total,
                        activeItemIndex: nil,
                        statusMessage: "Done"
                    )
                )
                return .completed(completedCount: completedCount)
            } catch {
                if await cancellationState.isRequested, case PythonBridgeError.cancelled = error {
                    bridge.clearGenerationActivity()
                    return .cancelled(completedCount: completedCount)
                }
                throw error
            }
        }

        for (index, line) in request.lines.enumerated() {
            if await cancellationState.isRequested {
                bridge.clearGenerationActivity()
                return .cancelled(completedCount: completedCount)
            }

            onProgress(
                makeProgressSnapshot(
                    completedCount: completedCount,
                    totalCount: total,
                    activeItemIndex: index,
                    statusMessage: "Generating item \(index + 1)/\(total)..."
                )
            )

            let outputPath = makeOutputPath(request.model.outputSubfolder, line)
            do {
                let result = try await generateResult(
                    for: request,
                    line: line,
                    outputPath: outputPath,
                    batchIndex: index + 1,
                    batchTotal: total
                )

                onProgress(
                    makeProgressSnapshot(
                        completedCount: completedCount,
                        totalCount: total,
                        activeItemIndex: index,
                        statusMessage: "Saving item \(index + 1)/\(total)..."
                    )
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

        onProgress(
            makeProgressSnapshot(
                completedCount: completedCount,
                totalCount: total,
                activeItemIndex: nil,
                statusMessage: "Done"
            )
        )
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
                outputPath: outputPath,
                batchIndex: batchIndex,
                batchTotal: batchTotal
            )
        }
    }

    private func makeProgressSnapshot(
        completedCount: Int,
        totalCount: Int,
        activeItemIndex: Int?,
        backendFraction: Double? = nil,
        statusMessage: String
    ) -> BatchProgressSnapshot {
        BatchProgressSnapshot(
            completedCount: completedCount,
            totalCount: totalCount,
            activeItemIndex: activeItemIndex,
            backendFraction: backendFraction,
            statusMessage: statusMessage
        )
    }
}

actor BatchGenerationCancellationState {
    private(set) var isRequested = false

    func request() {
        isRequested = true
    }
}

private enum BatchGenerationRunnerError: LocalizedError {
    case unexpectedResultCount(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .unexpectedResultCount(let expected, let actual):
            return "Clone batch generation returned \(actual) results for \(expected) requests."
        }
    }
}
