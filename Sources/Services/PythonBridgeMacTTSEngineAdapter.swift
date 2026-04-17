import Combine
import Foundation
import QwenVoiceNative

@MainActor
final class PythonBridgeMacTTSEngineAdapter: MacTTSEngine {
    private let bridge: PythonBridge
    private let snapshotSubject: CurrentValueSubject<TTSEngineSnapshot, Never>
    private var latestEvent: QwenVoiceNative.GenerationEvent?
    private var cancellables: Set<AnyCancellable> = []

    init(
        bridge: PythonBridge,
        notificationCenter: NotificationCenter = .default
    ) {
        self.bridge = bridge
        self.snapshotSubject = CurrentValueSubject(
            Self.makeSnapshot(from: bridge, latestEvent: nil)
        )

        bridge.objectWillChange
            .sink { [weak self] _ in
                self?.publishSnapshot()
            }
            .store(in: &cancellables)

        notificationCenter.publisher(for: .generationChunkReceived)
            .sink { [weak self] notification in
                self?.handleGenerationChunk(notification)
            }
            .store(in: &cancellables)
    }

    var snapshot: TTSEngineSnapshot {
        snapshotSubject.value
    }

    var snapshotPublisher: AnyPublisher<TTSEngineSnapshot, Never> {
        snapshotSubject.eraseToAnyPublisher()
    }

    func initialize(appSupportDirectory: URL) async throws {
        try await bridge.initialize(appSupportDir: appSupportDirectory.path)
    }

    func ping() async throws -> Bool {
        try await bridge.ping()
    }

    func loadModel(id: String) async throws {
        _ = try await bridge.loadModel(id: id)
    }

    func unloadModel() async throws {
        try await bridge.unloadModel()
    }

    func ensureModelLoadedIfNeeded(id: String) async {
        await bridge.ensureModelLoadedIfNeeded(id: id)
    }

    func prewarmModelIfNeeded(for request: QwenVoiceNative.GenerationRequest) async {
        switch request.payload {
        case .custom(let speakerID, let deliveryStyle):
            await bridge.prewarmModelIfNeeded(
                modelID: request.modelID,
                mode: .custom,
                voice: speakerID,
                instruct: deliveryStyle
            )
        case .design:
            await bridge.prewarmModelIfNeeded(
                modelID: request.modelID,
                mode: .design
            )
        case .clone(let reference):
            await bridge.prewarmModelIfNeeded(
                modelID: request.modelID,
                mode: .clone,
                refAudio: reference.audioPath,
                refText: reference.transcript
            )
        }
    }

    func ensureCloneReferencePrimed(modelID: String, reference: QwenVoiceNative.CloneReference) async throws {
        try await bridge.ensureCloneReferencePrimed(
            modelID: modelID,
            refAudio: reference.audioPath,
            refText: reference.transcript
        )
    }

    func cancelClonePreparationIfNeeded() async {
        await bridge.cancelCloneReferencePrimingIfNeeded()
    }

    func generate(_ request: QwenVoiceNative.GenerationRequest) async throws -> QwenVoiceNative.GenerationResult {
        let bridgeResult: GenerationResult

        switch request.payload {
        case .custom(let speakerID, let deliveryStyle):
            if request.shouldStream {
                bridgeResult = try await bridge.generateCustomStreamingFlow(
                    modelID: request.modelID,
                    text: request.text,
                    voice: speakerID,
                    emotion: deliveryStyle ?? "",
                    outputPath: request.outputPath
                )
            } else {
                bridgeResult = try await bridge.generateCustomFlow(
                    modelID: request.modelID,
                    text: request.text,
                    voice: speakerID,
                    emotion: deliveryStyle ?? "",
                    outputPath: request.outputPath,
                    batchIndex: request.batchIndex,
                    batchTotal: request.batchTotal
                )
            }
        case .design(let voiceDescription, let deliveryStyle):
            if request.shouldStream {
                bridgeResult = try await bridge.generateDesignStreamingFlow(
                    modelID: request.modelID,
                    text: request.text,
                    voiceDescription: voiceDescription,
                    emotion: deliveryStyle ?? "",
                    outputPath: request.outputPath
                )
            } else {
                bridgeResult = try await bridge.generateDesignFlow(
                    modelID: request.modelID,
                    text: request.text,
                    voiceDescription: voiceDescription,
                    emotion: deliveryStyle ?? "",
                    outputPath: request.outputPath,
                    batchIndex: request.batchIndex,
                    batchTotal: request.batchTotal
                )
            }
        case .clone(let reference):
            if request.shouldStream {
                bridgeResult = try await bridge.generateCloneStreamingFlow(
                    modelID: request.modelID,
                    text: request.text,
                    refAudio: reference.audioPath,
                    refText: reference.transcript,
                    outputPath: request.outputPath
                )
            } else {
                bridgeResult = try await bridge.generateCloneFlow(
                    modelID: request.modelID,
                    text: request.text,
                    refAudio: reference.audioPath,
                    refText: reference.transcript,
                    outputPath: request.outputPath,
                    batchIndex: request.batchIndex,
                    batchTotal: request.batchTotal
                )
            }
        }

        return Self.mapGenerationResult(bridgeResult)
    }

    func generateBatch(
        _ requests: [QwenVoiceNative.GenerationRequest],
        progressHandler: ((Double?, String) -> Void)?
    ) async throws -> [QwenVoiceNative.GenerationResult] {
        guard !requests.isEmpty else { return [] }

        if let sharedCloneBatch = sharedCloneBatchContext(for: requests) {
            let results = try await bridge.generateCloneBatchFlow(
                modelID: sharedCloneBatch.modelID,
                texts: sharedCloneBatch.texts,
                refAudio: sharedCloneBatch.reference.audioPath,
                refText: sharedCloneBatch.reference.transcript,
                outputPaths: sharedCloneBatch.outputPaths,
                progressHandler: progressHandler
            )
            return results.map(Self.mapGenerationResult)
        }

        var results: [QwenVoiceNative.GenerationResult] = []
        results.reserveCapacity(requests.count)
        for request in requests {
            results.append(try await generate(request))
        }
        return results
    }

    func cancelActiveGeneration() async throws {
        try await bridge.cancelActiveGenerationAndRecover()
    }

    func listPreparedVoices() async throws -> [QwenVoiceNative.PreparedVoice] {
        try await bridge.listVoices().map(Self.mapPreparedVoice)
    }

    func enrollPreparedVoice(
        name: String,
        audioPath: String,
        transcript: String?
    ) async throws -> QwenVoiceNative.PreparedVoice {
        Self.mapPreparedVoice(
            try await bridge.enrollVoice(name: name, audioPath: audioPath, transcript: transcript)
        )
    }

    func deletePreparedVoice(id: String) async throws {
        try await bridge.deleteVoice(name: id)
    }

    func clearGenerationActivity() {
        bridge.clearGenerationActivity()
    }

    func clearVisibleError() {
        bridge.lastError = nil
    }

    private func publishSnapshot() {
        snapshotSubject.send(Self.makeSnapshot(from: bridge, latestEvent: latestEvent))
    }

    private func handleGenerationChunk(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        latestEvent = Self.makeGenerationEvent(from: userInfo)
        publishSnapshot()
    }

    private static func makeSnapshot(
        from bridge: PythonBridge,
        latestEvent: QwenVoiceNative.GenerationEvent?
    ) -> TTSEngineSnapshot {
        TTSEngineSnapshot(
            isReady: bridge.isReady,
            loadState: makeLoadState(from: bridge),
            clonePreparationState: makeClonePreparationState(from: bridge),
            latestEvent: latestEvent,
            visibleErrorMessage: bridge.lastError
        )
    }

    private static func makeLoadState(from bridge: PythonBridge) -> EngineLoadState {
        if let lastError = bridge.lastError, !lastError.isEmpty {
            return .failed(message: lastError)
        }

        if !bridge.isReady {
            return .starting
        }

        if case .running(let activity) = bridge.sidebarStatus {
            return .running(
                modelID: bridge.modelLoadCoordinator.currentLoadedModelID,
                label: activity.label,
                fraction: activity.fraction
            )
        }

        if let modelID = bridge.modelLoadCoordinator.currentLoadedModelID {
            return .loaded(modelID: modelID)
        }

        return .idle
    }

    private static func makeClonePreparationState(from bridge: PythonBridge) -> ClonePreparationState {
        switch bridge.cloneReferencePrimingPhase {
        case .idle:
            return .idle
        case .preparing:
            return .preparing(key: bridge.cloneReferencePrimingKey)
        case .primed:
            return .primed(key: bridge.cloneReferencePrimingKey)
        case .failed:
            return .failed(
                key: bridge.cloneReferencePrimingKey,
                message: bridge.cloneReferencePrimingError
            )
        }
    }

    private static func makeGenerationEvent(
        from userInfo: [AnyHashable: Any]
    ) -> QwenVoiceNative.GenerationEvent? {
        guard let requestID = userInfo["requestID"] as? Int,
              let mode = userInfo["mode"] as? String,
              let title = userInfo["title"] as? String else {
            return nil
        }

        return QwenVoiceNative.GenerationEvent(
            kind: .streamChunk,
            requestID: requestID,
            mode: mode,
            title: title,
            chunkPath: userInfo["chunkPath"] as? String,
            isFinal: userInfo["isFinal"] as? Bool ?? false,
            chunkDurationSeconds: userInfo["chunkDurationSeconds"] as? Double,
            cumulativeDurationSeconds: userInfo["cumulativeDurationSeconds"] as? Double,
            streamSessionDirectory: userInfo["streamSessionDirectory"] as? String
        )
    }

    private static func mapGenerationResult(
        _ result: GenerationResult
    ) -> QwenVoiceNative.GenerationResult {
        let sample = result.metrics.map {
            QwenVoiceNative.BenchmarkSample(
                tokenCount: $0.tokenCount,
                processingTimeSeconds: $0.processingTimeSeconds,
                peakMemoryUsage: $0.peakMemoryUsage,
                streamingUsed: $0.streamingUsed,
                preparedCloneUsed: $0.preparedCloneUsed,
                cloneCacheHit: $0.cloneCacheHit,
                firstChunkMs: $0.firstChunkMs
            )
        }

        return QwenVoiceNative.GenerationResult(
            audioPath: result.audioPath,
            durationSeconds: result.durationSeconds,
            streamSessionDirectory: result.streamSessionDirectory,
            benchmarkSample: sample
        )
    }

    private static func mapPreparedVoice(_ voice: Voice) -> QwenVoiceNative.PreparedVoice {
        QwenVoiceNative.PreparedVoice(
            id: voice.id,
            name: voice.name,
            audioPath: voice.wavPath,
            hasTranscript: voice.hasTranscript
        )
    }

    private struct SharedCloneBatchContext {
        let modelID: String
        let reference: QwenVoiceNative.CloneReference
        let texts: [String]
        let outputPaths: [String]
    }

    private func sharedCloneBatchContext(
        for requests: [QwenVoiceNative.GenerationRequest]
    ) -> SharedCloneBatchContext? {
        guard requests.count > 1 else { return nil }
        guard requests.allSatisfy({ !$0.shouldStream && $0.modelID == requests[0].modelID }) else {
            return nil
        }
        guard case .clone(let firstReference) = requests[0].payload else { return nil }
        guard requests.allSatisfy({
            guard case .clone(let reference) = $0.payload else { return false }
            return reference == firstReference
        }) else {
            return nil
        }

        return SharedCloneBatchContext(
            modelID: requests[0].modelID,
            reference: firstReference,
            texts: requests.map(\.text),
            outputPaths: requests.map(\.outputPath)
        )
    }
}
