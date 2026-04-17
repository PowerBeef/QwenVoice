import Foundation
import QwenVoiceNative

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

struct BatchGenerationItemState: Identifiable, Equatable {
    enum Status: Equatable {
        case pending
        case running
        case saved(audioPath: String)
        case failed(message: String)
        case cancelled
    }

    let id = UUID()
    let index: Int
    let line: String
    var status: Status

    var audioPath: String? {
        if case .saved(let audioPath) = status {
            return audioPath
        }
        return nil
    }

    var isSaved: Bool {
        if case .saved = status {
            return true
        }
        return false
    }

    var isRetryable: Bool {
        switch status {
        case .pending, .running, .failed, .cancelled:
            return true
        case .saved:
            return false
        }
    }

    var statusLabel: String {
        switch status {
        case .pending:
            return "Pending"
        case .running:
            return "Running"
        case .saved:
            return "Saved"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    var statusMessage: String? {
        switch status {
        case .failed(let message):
            return message
        default:
            return nil
        }
    }
}

@MainActor
protocol GenerationPersisting {
    func saveGeneration(_ generation: inout Generation) throws
}

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

    func validationError(isModelAvailable: Bool, recoveryDetail: String) -> String? {
        guard isModelAvailable else {
            return recoveryDetail
        }

        if mode == .design && (voiceDescription ?? "").isEmpty {
            return "Enter a voice description before starting batch generation."
        }

        if mode == .clone && refAudio == nil {
            return "Select a reference audio file before starting batch generation."
        }

        return nil
    }

    func makeHistoryRecord(for line: String, result: QwenVoiceNative.GenerationResult) -> Generation {
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

    func makeGenerationRequest(
        for line: String,
        outputPath: String,
        batchIndex: Int?,
        batchTotal: Int?
    ) -> QwenVoiceNative.GenerationRequest {
        switch mode {
        case .custom:
            return QwenVoiceNative.GenerationRequest(
                modelID: model.id,
                text: line,
                outputPath: outputPath,
                shouldStream: false,
                batchIndex: batchIndex,
                batchTotal: batchTotal,
                payload: .custom(
                    speakerID: voice ?? TTSModel.defaultSpeaker,
                    deliveryStyle: emotion ?? "Normal tone"
                )
            )
        case .design:
            return QwenVoiceNative.GenerationRequest(
                modelID: model.id,
                text: line,
                outputPath: outputPath,
                shouldStream: false,
                batchIndex: batchIndex,
                batchTotal: batchTotal,
                payload: .design(
                    voiceDescription: voiceDescription ?? "",
                    deliveryStyle: emotion ?? "Normal tone"
                )
            )
        case .clone:
            return QwenVoiceNative.GenerationRequest(
                modelID: model.id,
                text: line,
                outputPath: outputPath,
                shouldStream: false,
                batchIndex: batchIndex,
                batchTotal: batchTotal,
                payload: .clone(
                    reference: CloneReference(
                        audioPath: refAudio ?? "",
                        transcript: refText
                    )
                )
            )
        }
    }

    func makeBatchGenerationRequests(
        makeOutputPath: (String, String) -> String
    ) -> [QwenVoiceNative.GenerationRequest] {
        lines.enumerated().map { index, line in
            makeGenerationRequest(
                for: line,
                outputPath: makeOutputPath(model.outputSubfolder, line),
                batchIndex: index + 1,
                batchTotal: lines.count
            )
        }
    }
}

enum BatchGenerationOutcome: Equatable {
    case completed(items: [BatchGenerationItemState])
    case cancelled(items: [BatchGenerationItemState], restartFailedMessage: String?)
    case failed(items: [BatchGenerationItemState], message: String)

    var items: [BatchGenerationItemState] {
        switch self {
        case .completed(let items):
            return items
        case .cancelled(let items, _):
            return items
        case .failed(let items, _):
            return items
        }
    }

    var completedCount: Int {
        items.filter(\.isSaved).count
    }

    var totalCount: Int {
        items.count
    }

    var retryRemainingLines: [String] {
        items.compactMap { item in
            switch item.status {
            case .pending, .running, .cancelled:
                return item.line
            case .failed, .saved:
                return nil
            }
        }
    }

    var retryFailedLines: [String] {
        items.compactMap { item in
            if case .failed = item.status {
                return item.line
            }
            return nil
        }
    }

    var savedAudioPaths: [String] {
        items.compactMap(\.audioPath)
    }

    func withRestartFailure(_ message: String?) -> BatchGenerationOutcome {
        guard case .cancelled(let items, _) = self else { return self }
        return .cancelled(items: items, restartFailedMessage: message)
    }
}

@MainActor
final class BatchGenerationCoordinator: ObservableObject {
    @Published private(set) var isProcessing = false
    @Published private(set) var isCancelling = false
    @Published private(set) var progressSnapshot = BatchProgressSnapshot()
    @Published private(set) var itemStates: [BatchGenerationItemState] = []
    @Published var errorMessage: String?
    @Published private(set) var outcome: BatchGenerationOutcome?

    private var runner: BatchGenerationRunner?
    private var runTask: Task<Void, Never>?
    private var cancelTask: Task<Void, Never>?
    private var cancelRestartFailedMessage: String?

    func startBatch(
        batchText: String,
        requestBuilder: ([String]) -> BatchGenerationRequest?,
        isModelAvailable: (TTSModel) -> Bool,
        recoveryDetail: (TTSModel) -> String,
        engineStore: TTSEngineStore,
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

        if let validationError = request.validationError(
            isModelAvailable: isModelAvailable(request.model),
            recoveryDetail: recoveryDetail(request.model)
        ) {
            errorMessage = validationError
            return
        }

        let runner = BatchGenerationRunner(
            engineStore: engineStore,
            store: store
        )

        self.runner = runner
        runTask?.cancel()
        cancelTask = nil
        cancelRestartFailedMessage = nil
        isProcessing = true
        isCancelling = false
        errorMessage = nil
        outcome = nil
        itemStates = lines.enumerated().map { index, line in
            BatchGenerationItemState(index: index, line: line, status: .pending)
        }
        progressSnapshot = BatchProgressSnapshot(
            completedCount: 0,
            totalCount: lines.count,
            activeItemIndex: lines.isEmpty ? nil : 0,
            statusMessage: "Preparing batch..."
        )

        runTask = Task { [weak self] in
            guard let self else { return }

            var outcome = await runner.run(
                request: request,
                makeOutputPath: { makeOutputPath(subfolder: $0, text: $1) },
                onProgress: { [weak self] snapshot in
                    self?.progressSnapshot = snapshot
                },
                onItemsUpdated: { [weak self] items in
                    self?.itemStates = items
                }
            )

            if case .cancelled = outcome, let cancelTask = self.cancelTask {
                await cancelTask.value
                if let cancelRestartFailedMessage {
                    outcome = outcome.withRestartFailure(cancelRestartFailedMessage)
                }
            }

            self.isProcessing = false
            self.isCancelling = false
            self.runner = nil
            self.runTask = nil
            self.outcome = outcome

            if case .failed(_, let message) = outcome {
                self.errorMessage = message
            } else if case .cancelled(_, let restartFailedMessage) = outcome {
                self.errorMessage = restartFailedMessage
            }
        }
    }

    func cancelBatch(
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

        isCancelling = true
        errorMessage = nil
        cancelRestartFailedMessage = nil
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
                try await runner.requestCancellation()
            } catch {
                self.cancelRestartFailedMessage = "Batch generation was interrupted, but the backend could not be restarted: \(error.localizedDescription)"
            }
        }
    }
}

@MainActor
final class BatchGenerationRunner {
    private let engineStore: TTSEngineStore
    private let store: any GenerationPersisting
    private let generationEvents: GenerationLibraryEvents
    private let cancellationState = BatchGenerationCancellationState()

    init(
        engineStore: TTSEngineStore,
        store: any GenerationPersisting,
        generationEvents: GenerationLibraryEvents = .shared
    ) {
        self.engineStore = engineStore
        self.store = store
        self.generationEvents = generationEvents
    }

    func run(
        request: BatchGenerationRequest,
        makeOutputPath: (String, String) -> String,
        onProgress: @escaping @MainActor (BatchProgressSnapshot) -> Void,
        onItemsUpdated: @escaping @MainActor ([BatchGenerationItemState]) -> Void
    ) async -> BatchGenerationOutcome {
        var items = request.lines.enumerated().map { index, line in
            BatchGenerationItemState(index: index, line: line, status: .pending)
        }
        var completedCount = 0
        let total = request.lines.count

        func publishItems() {
            onItemsUpdated(items)
        }

        func markItemsCancelled(startingAt index: Int) {
            guard index < items.count else { return }
            for itemIndex in index..<items.count where !items[itemIndex].isSaved {
                items[itemIndex].status = .cancelled
            }
        }

        func publishProgress(activeItemIndex: Int?, message: String, backendFraction: Double? = nil) {
            onProgress(
                BatchProgressSnapshot(
                    completedCount: completedCount,
                    totalCount: total,
                    activeItemIndex: activeItemIndex,
                    backendFraction: backendFraction,
                    statusMessage: message
                )
            )
        }

        publishItems()

        if total > 1 {
            if await cancellationState.isRequested {
                markItemsCancelled(startingAt: 0)
                publishItems()
                engineStore.clearGenerationActivity()
                return .cancelled(items: items, restartFailedMessage: nil)
            }

            items[0].status = .running
            publishItems()
            publishProgress(activeItemIndex: 0, message: "Preparing batch...")

            let batchRequests = request.makeBatchGenerationRequests(makeOutputPath: makeOutputPath)

            do {
                let results = try await engineStore.generateBatch(
                    batchRequests,
                    progressHandler: { fraction, message in
                        publishProgress(
                            activeItemIndex: completedCount < total ? completedCount : nil,
                            message: message,
                            backendFraction: fraction
                        )
                    }
                )

                guard results.count == request.lines.count else {
                    if let firstRunningIndex = items.firstIndex(where: { $0.status == .running || $0.status == .pending }) {
                        items[firstRunningIndex].status = .failed(
                            message: "Batch generation returned \(results.count) results for \(request.lines.count) requests."
                        )
                    }
                    publishItems()
                    return .failed(
                        items: items,
                        message: "Batch generation returned \(results.count) results for \(request.lines.count) requests."
                    )
                }

                for (index, pair) in zip(request.lines, results).enumerated() {
                    if await cancellationState.isRequested {
                        markItemsCancelled(startingAt: index)
                        publishItems()
                        engineStore.clearGenerationActivity()
                        return .cancelled(items: items, restartFailedMessage: nil)
                    }

                    items[index].status = .running
                    publishItems()
                    publishProgress(activeItemIndex: index, message: "Saving item \(index + 1)/\(total)...")

                    let (line, result) = pair
                    var generation = request.makeHistoryRecord(for: line, result: result)

                    do {
                        try store.saveGeneration(&generation)
                        generationEvents.announceGenerationSaved()
                        completedCount += 1
                        items[index].status = .saved(audioPath: result.audioPath)
                        if index + 1 < items.count {
                            items[index + 1].status = .pending
                        }
                        publishItems()
                    } catch {
                        items[index].status = .failed(message: error.localizedDescription)
                        publishItems()
                        return .failed(items: items, message: error.localizedDescription)
                    }
                }

                publishProgress(activeItemIndex: nil, message: "Done")
                return .completed(items: items)
            } catch {
                if await cancellationState.isRequested, case PythonBridgeError.cancelled = error {
                    if let firstUnfinished = items.firstIndex(where: { !$0.isSaved }) {
                        markItemsCancelled(startingAt: firstUnfinished)
                    }
                    publishItems()
                    engineStore.clearGenerationActivity()
                    return .cancelled(items: items, restartFailedMessage: nil)
                }

                if let activeIndex = items.firstIndex(where: { $0.status == .running || $0.status == .pending }) {
                    items[activeIndex].status = .failed(message: error.localizedDescription)
                }
                publishItems()
                return .failed(items: items, message: error.localizedDescription)
            }
        }

        for (index, line) in request.lines.enumerated() {
            if await cancellationState.isRequested {
                markItemsCancelled(startingAt: index)
                publishItems()
                engineStore.clearGenerationActivity()
                return .cancelled(items: items, restartFailedMessage: nil)
            }

            items[index].status = .running
            publishItems()
            publishProgress(activeItemIndex: index, message: "Generating item \(index + 1)/\(total)...")

            let outputPath = makeOutputPath(request.model.outputSubfolder, line)
            do {
                let result = try await generateResult(
                    for: request,
                    line: line,
                    outputPath: outputPath,
                    batchIndex: index + 1,
                    batchTotal: total
                )

                publishProgress(activeItemIndex: index, message: "Saving item \(index + 1)/\(total)...")

                var generation = request.makeHistoryRecord(for: line, result: result)
                try store.saveGeneration(&generation)
                generationEvents.announceGenerationSaved()
                completedCount += 1
                items[index].status = .saved(audioPath: result.audioPath)
                publishItems()
            } catch {
                if await cancellationState.isRequested, case PythonBridgeError.cancelled = error {
                    markItemsCancelled(startingAt: index)
                    publishItems()
                    engineStore.clearGenerationActivity()
                    return .cancelled(items: items, restartFailedMessage: nil)
                }

                items[index].status = .failed(message: error.localizedDescription)
                publishItems()
                return .failed(items: items, message: error.localizedDescription)
            }
        }

        if await cancellationState.isRequested {
            if let firstUnfinished = items.firstIndex(where: { !$0.isSaved }) {
                markItemsCancelled(startingAt: firstUnfinished)
            }
            publishItems()
            engineStore.clearGenerationActivity()
            return .cancelled(items: items, restartFailedMessage: nil)
        }

        publishProgress(activeItemIndex: nil, message: "Done")
        return .completed(items: items)
    }

    func requestCancellation() async throws {
        await cancellationState.request()
        try await engineStore.cancelActiveGeneration()
    }

    private func generateResult(
        for request: BatchGenerationRequest,
        line: String,
        outputPath: String,
        batchIndex: Int,
        batchTotal: Int
    ) async throws -> QwenVoiceNative.GenerationResult {
        try await engineStore.generate(
            request.makeGenerationRequest(
                for: line,
                outputPath: outputPath,
                batchIndex: batchIndex,
                batchTotal: batchTotal
            )
        )
    }
}

actor BatchGenerationCancellationState {
    private(set) var isRequested = false

    func request() {
        isRequested = true
    }
}
