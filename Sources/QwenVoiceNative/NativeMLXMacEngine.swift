import Combine
import Foundation

@MainActor
    public final class NativeMLXMacEngine: MacTTSEngine {
    public enum EngineError: LocalizedError, Equatable {
        case nativeBatchRequiresSingleMode

        public var errorDescription: String? {
            switch self {
            case .nativeBatchRequiresSingleMode:
                return "Native batch generation requires all requests to share the same generation mode."
            }
        }
    }

    private enum BatchMode: Equatable {
        case custom
        case design
        case clone

        init(payload: GenerationRequest.Payload) {
            switch payload {
            case .custom:
                self = .custom
            case .design:
                self = .design
            case .clone:
                self = .clone
            }
        }
    }

    private let runtime: MacNativeRuntime
    private let snapshotSubject: CurrentValueSubject<TTSEngineSnapshot, Never>

    public init(runtime: MacNativeRuntime = MacNativeRuntime()) {
        self.runtime = runtime
        self.snapshotSubject = CurrentValueSubject(
            TTSEngineSnapshot(
                isReady: false,
                loadState: .idle,
                clonePreparationState: .idle,
                latestEvent: nil,
                visibleErrorMessage: nil
            )
        )
    }

    public var snapshot: TTSEngineSnapshot {
        snapshotSubject.value
    }

    public var snapshotPublisher: AnyPublisher<TTSEngineSnapshot, Never> {
        snapshotSubject.eraseToAnyPublisher()
    }

    public func initialize(appSupportDirectory: URL) async throws {
        do {
            _ = try await runtime.initialize(appSupportDirectory: appSupportDirectory)
            publishSnapshot { _ in
                TTSEngineSnapshot(
                    isReady: true,
                    loadState: .idle,
                    clonePreparationState: .idle,
                    latestEvent: nil,
                    visibleErrorMessage: nil
                )
            }
        } catch {
            publishSnapshot { _ in
                TTSEngineSnapshot(
                    isReady: false,
                    loadState: .failed(message: error.localizedDescription),
                    clonePreparationState: .idle,
                    latestEvent: nil,
                    visibleErrorMessage: error.localizedDescription
                )
            }
            throw error
        }
    }

    public func ping() async throws -> Bool {
        snapshot.isReady
    }

    public func loadModel(id: String) async throws {
        if snapshot.loadState != .loaded(modelID: id) {
            publishSnapshot { current in
                TTSEngineSnapshot(
                    isReady: current.isReady,
                    loadState: .starting,
                    clonePreparationState: .idle,
                    latestEvent: current.latestEvent,
                    visibleErrorMessage: nil
                )
            }
        }

        do {
            try await runtime.loadModel(id: id)
            publishSnapshot { current in
                TTSEngineSnapshot(
                    isReady: current.isReady,
                    loadState: .loaded(modelID: id),
                    clonePreparationState: current.clonePreparationState,
                    latestEvent: current.latestEvent,
                    visibleErrorMessage: nil
                )
            }
        } catch {
            publishRuntimeFailure(error)
            throw error
        }
    }

    public func unloadModel() async throws {
        await runtime.unloadModel()
        publishSnapshot { current in
            TTSEngineSnapshot(
                isReady: current.isReady,
                loadState: .idle,
                clonePreparationState: .idle,
                latestEvent: current.latestEvent,
                visibleErrorMessage: nil
            )
        }
    }

    public func ensureModelLoadedIfNeeded(id: String) async {
        if await runtime.currentLoadedModelID() == id {
            return
        }

        do {
            try await loadModel(id: id)
        } catch {
            publishRuntimeFailure(error)
        }
    }

    public func prewarmModelIfNeeded(for request: GenerationRequest) async {
        if snapshot.loadState != .loaded(modelID: request.modelID) {
            publishSnapshot { current in
                TTSEngineSnapshot(
                    isReady: current.isReady,
                    loadState: .starting,
                    clonePreparationState: .idle,
                    latestEvent: current.latestEvent,
                    visibleErrorMessage: nil
                )
            }
        }

        do {
            try await runtime.prewarmModelIfNeeded(for: request)
            publishSnapshot { current in
                TTSEngineSnapshot(
                    isReady: current.isReady,
                    loadState: .loaded(modelID: request.modelID),
                    clonePreparationState: current.clonePreparationState,
                    latestEvent: current.latestEvent,
                    visibleErrorMessage: nil
                )
            }
        } catch {
            publishRuntimeFailure(error)
        }
    }

    public func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {
        try await loadModel(id: modelID)
        let key = clonePreparationKey(modelID: modelID, reference: reference)

        publishSnapshot { current in
            TTSEngineSnapshot(
                isReady: current.isReady,
                loadState: current.loadState,
                clonePreparationState: .preparing(key: key),
                latestEvent: current.latestEvent,
                visibleErrorMessage: nil
            )
        }

        do {
            _ = try await runtime.ensureCloneReferencePrimed(
                modelID: modelID,
                reference: reference
            )
            publishSnapshot { current in
                TTSEngineSnapshot(
                    isReady: current.isReady,
                    loadState: current.loadState,
                    clonePreparationState: .primed(key: key),
                    latestEvent: current.latestEvent,
                    visibleErrorMessage: nil
                )
            }
        } catch {
            publishSnapshot { current in
                TTSEngineSnapshot(
                    isReady: current.isReady,
                    loadState: current.loadState,
                    clonePreparationState: .failed(
                        key: key,
                        message: error.localizedDescription
                    ),
                    latestEvent: current.latestEvent,
                    visibleErrorMessage: error.localizedDescription
                )
            }
            throw error
        }
    }

    public func cancelClonePreparationIfNeeded() async {
        publishSnapshot { current in
            TTSEngineSnapshot(
                isReady: current.isReady,
                loadState: current.loadState,
                clonePreparationState: .idle,
                latestEvent: current.latestEvent,
                visibleErrorMessage: current.visibleErrorMessage
            )
        }
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        switch request.payload {
        case .custom, .design, .clone:
            break
        }

        let generationLabel = request.streamingTitle ?? String(request.text.prefix(40))
        publishSnapshot { current in
            TTSEngineSnapshot(
                isReady: current.isReady,
                loadState: .running(modelID: request.modelID, label: generationLabel, fraction: nil),
                clonePreparationState: current.clonePreparationState,
                latestEvent: nil,
                visibleErrorMessage: nil
            )
        }

        do {
            let prepared = try await runtime.prepareGeneration(for: request)
            let session = NativeStreamingSynthesisSession(
                requestID: prepared.requestID,
                request: prepared.request,
                model: prepared.model,
                streamSessionsDirectory: prepared.streamSessionsDirectory,
                warmState: prepared.warmState,
                timingOverridesMS: prepared.timingOverridesMS,
                booleanFlags: prepared.booleanFlags,
                stringFlags: prepared.stringFlags,
                cloneConditioning: prepared.cloneConditioning
            )

            let result = try await session.run { [weak self] event in
                self?.publishSnapshot { current in
                    TTSEngineSnapshot(
                        isReady: current.isReady,
                        loadState: .running(
                            modelID: request.modelID,
                            label: event.title,
                            fraction: nil
                        ),
                        clonePreparationState: current.clonePreparationState,
                        latestEvent: event,
                        visibleErrorMessage: nil
                    )
                }
            }

            publishSnapshot { current in
                TTSEngineSnapshot(
                    isReady: current.isReady,
                    loadState: .loaded(modelID: request.modelID),
                    clonePreparationState: current.clonePreparationState,
                    latestEvent: current.latestEvent,
                    visibleErrorMessage: nil
                )
            }
            return result
        } catch {
            await publishGenerationFailure(error)
            throw error
        }
    }

    public func generateBatch(
        _ requests: [GenerationRequest],
        progressHandler: ((Double?, String) -> Void)?
    ) async throws -> [GenerationResult] {
        guard !requests.isEmpty else { return [] }
        let batchMode = BatchMode(payload: requests[0].payload)
        guard requests.dropFirst().allSatisfy({ BatchMode(payload: $0.payload) == batchMode }) else {
            let error = EngineError.nativeBatchRequiresSingleMode
            publishNonLoadError(error)
            throw error
        }

        var results: [GenerationResult] = []
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

    public func cancelActiveGeneration() async throws {
        clearGenerationActivity()
    }

    public func listPreparedVoices() async throws -> [PreparedVoice] {
        do {
            return try await runtime.listPreparedVoices()
        } catch {
            publishNonLoadError(error)
            throw error
        }
    }

    public func enrollPreparedVoice(
        name: String,
        audioPath: String,
        transcript: String?
    ) async throws -> PreparedVoice {
        do {
            let voice = try await runtime.enrollPreparedVoice(
                name: name,
                audioPath: audioPath,
                transcript: transcript
            )
            clearVisibleError()
            return voice
        } catch {
            publishNonLoadError(error)
            throw error
        }
    }

    public func deletePreparedVoice(id: String) async throws {
        do {
            try await runtime.deletePreparedVoice(id: id)
            clearVisibleError()
        } catch {
            publishNonLoadError(error)
            throw error
        }
    }

    public func clearGenerationActivity() {
        publishSnapshot { current in
            TTSEngineSnapshot(
                isReady: current.isReady,
                loadState: current.loadState,
                clonePreparationState: current.clonePreparationState,
                latestEvent: nil,
                visibleErrorMessage: current.visibleErrorMessage
            )
        }
    }

    public func clearVisibleError() {
        publishSnapshot { current in
            TTSEngineSnapshot(
                isReady: current.isReady,
                loadState: current.loadState,
                clonePreparationState: current.clonePreparationState,
                latestEvent: current.latestEvent,
                visibleErrorMessage: nil
            )
        }
    }

    private func clonePreparationKey(modelID: String, reference: CloneReference) -> String {
        GenerationSemantics.clonePreparationKey(modelID: modelID, reference: reference)
    }

    private func publishRuntimeFailure(_ error: Error) {
        publishSnapshot { current in
            TTSEngineSnapshot(
                isReady: current.isReady,
                loadState: .failed(message: error.localizedDescription),
                clonePreparationState: .idle,
                latestEvent: current.latestEvent,
                visibleErrorMessage: error.localizedDescription
            )
        }
    }

    private func publishNonLoadError(_ error: Error) {
        publishSnapshot { current in
            TTSEngineSnapshot(
                isReady: current.isReady,
                loadState: current.loadState,
                clonePreparationState: current.clonePreparationState,
                latestEvent: current.latestEvent,
                visibleErrorMessage: error.localizedDescription
            )
        }
    }

    private func publishGenerationFailure(_ error: Error) async {
        if let loadedModelID = await runtime.currentLoadedModelID() {
            publishSnapshot { current in
                TTSEngineSnapshot(
                    isReady: current.isReady,
                    loadState: .loaded(modelID: loadedModelID),
                    clonePreparationState: current.clonePreparationState,
                    latestEvent: current.latestEvent,
                    visibleErrorMessage: error.localizedDescription
                )
            }
        } else {
            publishRuntimeFailure(error)
        }
    }

    private func publishSnapshot(
        _ transform: (TTSEngineSnapshot) -> TTSEngineSnapshot
    ) {
        snapshotSubject.send(transform(snapshotSubject.value))
    }
}
