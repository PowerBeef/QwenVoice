#if QW_TEST_SUPPORT
import Combine
import Foundation
import QwenVoiceNative

final class UITestStubMacEngine: MacTTSEngine, @unchecked Sendable {
    private let transport: StubBackendTransport
    private let snapshotSubject: CurrentValueSubject<TTSEngineSnapshot, Never>
    private var appSupportDirectory: URL?

    init(transport: StubBackendTransport = StubBackendTransport()) {
        self.transport = transport
        self.snapshotSubject = CurrentValueSubject(
            TTSEngineSnapshot(
                isReady: false,
                loadState: .idle,
                clonePreparationState: .idle,
                visibleErrorMessage: nil
            )
        )
    }

    var snapshot: TTSEngineSnapshot {
        snapshotSubject.value
    }

    var snapshotPublisher: AnyPublisher<TTSEngineSnapshot, Never> {
        snapshotSubject.eraseToAnyPublisher()
    }

    func initialize(appSupportDirectory: URL) async throws {
        self.appSupportDirectory = appSupportDirectory
        try await transport.initialize()
        publishSnapshot(
            isReady: true,
            loadState: .idle,
            clonePreparationState: .idle,
            visibleErrorMessage: nil
        )
    }

    func ping() async throws -> Bool {
        snapshot.isReady
    }

    func loadModel(id: String) async throws {
        publishSnapshot(
            loadState: .starting,
            clonePreparationState: snapshot.clonePreparationState,
            visibleErrorMessage: nil
        )

        do {
            _ = try await transport.loadModel(id: id)
            publishSnapshot(
                loadState: .loaded(modelID: id),
                clonePreparationState: snapshot.clonePreparationState,
                visibleErrorMessage: nil
            )
        } catch {
            publishFailure(error)
            throw error
        }
    }

    func unloadModel() async throws {
        publishSnapshot(
            loadState: .idle,
            clonePreparationState: .idle,
            visibleErrorMessage: nil
        )
    }

    func ensureModelLoadedIfNeeded(id: String) async {
        if snapshot.loadState == .loaded(modelID: id) {
            return
        }

        do {
            try await loadModel(id: id)
        } catch {
            publishFailure(error)
        }
    }

    func prewarmModelIfNeeded(for request: GenerationRequest) async {
        await ensureModelLoadedIfNeeded(id: request.modelID)
    }

    func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {
        try await loadModel(id: modelID)
        let key = GenerationSemantics.clonePreparationKey(modelID: modelID, reference: reference)
        publishSnapshot(
            loadState: .loaded(modelID: modelID),
            clonePreparationState: .preparing(key: key),
            visibleErrorMessage: nil
        )

        try? await Task.sleep(nanoseconds: 120_000_000)

        publishSnapshot(
            loadState: .loaded(modelID: modelID),
            clonePreparationState: .primed(key: key),
            visibleErrorMessage: nil
        )
    }

    func cancelClonePreparationIfNeeded() async {
        publishSnapshot(
            loadState: snapshot.loadState,
            clonePreparationState: .idle,
            visibleErrorMessage: snapshot.visibleErrorMessage
        )
    }

    func generate(_ request: GenerationRequest) async throws -> QwenVoiceNative.GenerationResult {
        try await loadModel(id: request.modelID)

        publishSnapshot(
            loadState: .running(
                modelID: request.modelID,
                label: request.streamingTitle ?? String(request.text.prefix(40)),
                fraction: nil
            ),
            clonePreparationState: snapshot.clonePreparationState,
            visibleErrorMessage: nil
        )

        let mode: GenerationMode
        switch request.payload {
        case .custom:
            mode = .custom
        case .design:
            mode = .design
        case .clone:
            mode = .clone
        }

        let streamingContext = request.shouldStream
            ? StreamingRequestContext(
                mode: mode,
                title: request.streamingTitle ?? String(request.text.prefix(40))
            )
            : nil

        do {
            let result = try await transport.generate(
                mode: mode,
                text: request.text,
                outputPath: request.outputPath,
                stream: request.shouldStream,
                streamingContext: streamingContext,
                chunkHandler: { event in
                    GenerationChunkBroker.publish(event)
                }
            )
            let loadState: EngineLoadState = .loaded(modelID: request.modelID)
            publishSnapshot(
                loadState: loadState,
                clonePreparationState: snapshot.clonePreparationState,
                visibleErrorMessage: nil
            )
            let benchmarkSample = result.metrics.map { metrics in
                BenchmarkSample(
                    tokenCount: metrics.tokenCount,
                    processingTimeSeconds: metrics.processingTimeSeconds,
                    peakMemoryUsage: metrics.peakMemoryUsage,
                    streamingUsed: metrics.streamingUsed,
                    preparedCloneUsed: metrics.preparedCloneUsed,
                    cloneCacheHit: metrics.cloneCacheHit,
                    firstChunkMs: metrics.firstChunkMs
                )
            }

            return QwenVoiceNative.GenerationResult(
                audioPath: result.audioPath,
                durationSeconds: result.durationSeconds,
                streamSessionDirectory: result.streamSessionDirectory,
                benchmarkSample: benchmarkSample
            )
        } catch {
            publishFailure(error)
            throw error
        }
    }

    func generateBatch(
        _ requests: [GenerationRequest],
        progressHandler: (@Sendable (Double?, String) -> Void)?
    ) async throws -> [QwenVoiceNative.GenerationResult] {
        guard !requests.isEmpty else { return [] }

        var results: [QwenVoiceNative.GenerationResult] = []
        results.reserveCapacity(requests.count)

        for (index, request) in requests.enumerated() {
            progressHandler?(
                Double(index) / Double(max(requests.count, 1)),
                "Generating item \(index + 1)/\(requests.count)..."
            )
            results.append(try await generate(request))
        }

        progressHandler?(1.0, "Done")
        return results
    }

    func cancelActiveGeneration() async throws {
        publishSnapshot(
            loadState: snapshot.loadState.currentModelID.map { .loaded(modelID: $0) } ?? .idle,
            clonePreparationState: snapshot.clonePreparationState,
            visibleErrorMessage: nil
        )
    }

    func listPreparedVoices() async throws -> [PreparedVoice] {
        try await transport.listVoices().map { voice in
            PreparedVoice(
                id: voice.id,
                name: voice.name,
                audioPath: voice.wavPath,
                hasTranscript: voice.hasTranscript
            )
        }
    }

    func enrollPreparedVoice(
        name: String,
        audioPath: String,
        transcript: String?
    ) async throws -> PreparedVoice {
        let voice = try await transport.enrollVoice(
            name: name,
            audioPath: audioPath,
            transcript: transcript
        )
        return PreparedVoice(
            id: voice.id,
            name: voice.name,
            audioPath: voice.wavPath,
            hasTranscript: voice.hasTranscript
        )
    }

    func deletePreparedVoice(id: String) async throws {
        try await transport.deleteVoice(name: id)
    }

    func clearGenerationActivity() {
        publishSnapshot(
            loadState: snapshot.loadState.currentModelID.map { .loaded(modelID: $0) } ?? .idle,
            clonePreparationState: snapshot.clonePreparationState,
            visibleErrorMessage: snapshot.visibleErrorMessage
        )
    }

    func clearVisibleError() {
        publishSnapshot(
            loadState: snapshot.loadState,
            clonePreparationState: snapshot.clonePreparationState,
            visibleErrorMessage: nil
        )
    }

    private func publishFailure(_ error: Error) {
        publishSnapshot(
            loadState: .failed(message: error.localizedDescription),
            clonePreparationState: snapshot.clonePreparationState,
            visibleErrorMessage: error.localizedDescription
        )
    }

    private func publishSnapshot(
        isReady: Bool? = nil,
        loadState: EngineLoadState,
        clonePreparationState: ClonePreparationState,
        visibleErrorMessage: String?
    ) {
        snapshotSubject.send(
            TTSEngineSnapshot(
                isReady: isReady ?? snapshot.isReady,
                loadState: loadState,
                clonePreparationState: clonePreparationState,
                visibleErrorMessage: visibleErrorMessage
            )
        )
    }
}
#endif
