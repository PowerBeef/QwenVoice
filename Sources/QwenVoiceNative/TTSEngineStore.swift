import Combine
import Foundation
import QwenVoiceCore

private final class BatchProgressRelay: @unchecked Sendable {
    private let handler: (Double?, String) -> Void

    init(handler: @escaping (Double?, String) -> Void) {
        self.handler = handler
    }

    func send(_ fraction: Double?, _ message: String) {
        Task { @MainActor in
            handler(fraction, message)
        }
    }
}

@MainActor
public final class TTSEngineStore: ObservableObject {
    @Published public private(set) var snapshot: TTSEngineSnapshot
    @Published public private(set) var frontendState: TTSEngineFrontendState
    @Published public private(set) var latestEvent: GenerationEvent?

    public var isReady: Bool { snapshot.isReady }
    public var loadState: EngineLoadState { snapshot.loadState }
    public var clonePreparationState: ClonePreparationState { snapshot.clonePreparationState }
    public var visibleErrorMessage: String? { snapshot.visibleErrorMessage }
    public var lifecycleState: EngineLifecycleState { frontendState.lifecycleState }

    private let engine: any MacTTSEngine
    private var snapshotCancellable: AnyCancellable?
    private var chunkCancellable: AnyCancellable?

    public init(engine: any MacTTSEngine) {
        self.engine = engine
        self.snapshot = engine.snapshot
        self.frontendState = TTSEngineFrontendState(snapshot: engine.snapshot)
        snapshotCancellable = engine.snapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.apply(snapshot: snapshot)
            }
        chunkCancellable = GenerationChunkBroker.shared.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] latestEvent in
                guard let self else { return }
                self.latestEvent = latestEvent
                self.frontendState = TTSEngineFrontendState(
                    snapshot: self.snapshot,
                    latestEvent: latestEvent
                )
            }
    }

    public func initialize(appSupportDirectory: URL) async throws {
        try await engine.initialize(appSupportDirectory: appSupportDirectory)
    }

    public func ping() async throws -> Bool {
        try await engine.ping()
    }

    public func loadModel(id: String) async throws {
        try await engine.loadModel(id: id)
    }

    public func unloadModel() async throws {
        try await engine.unloadModel()
    }

    public func ensureModelLoadedIfNeeded(id: String) async {
        await engine.ensureModelLoadedIfNeeded(id: id)
    }

    public func prewarmModelIfNeeded(for request: GenerationRequest) async {
        await engine.prewarmModelIfNeeded(for: request)
    }

    public func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {
        try await engine.ensureCloneReferencePrimed(modelID: modelID, reference: reference)
    }

    public func cancelClonePreparationIfNeeded() async {
        await engine.cancelClonePreparationIfNeeded()
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        try await engine.generate(request)
    }

    public func generateBatch(
        _ requests: [GenerationRequest],
        progressHandler: ((Double?, String) -> Void)? = nil
    ) async throws -> [GenerationResult] {
        let progressRelay = progressHandler.map { BatchProgressRelay(handler: $0) }
        let forwardedHandler = progressRelay.map { relay in
            { @Sendable (fraction: Double?, message: String) in
                relay.send(fraction, message)
            }
        }
        return try await engine.generateBatch(requests, progressHandler: forwardedHandler)
    }

    public func cancelActiveGeneration() async throws {
        try await engine.cancelActiveGeneration()
    }

    public func listPreparedVoices() async throws -> [PreparedVoice] {
        try await engine.listPreparedVoices()
    }

    public func enrollPreparedVoice(name: String, audioPath: String, transcript: String?) async throws -> PreparedVoice {
        try await engine.enrollPreparedVoice(name: name, audioPath: audioPath, transcript: transcript)
    }

    public func deletePreparedVoice(id: String) async throws {
        try await engine.deletePreparedVoice(id: id)
    }

    public func clearGenerationActivity() {
        engine.clearGenerationActivity()
    }

    public func clearVisibleError() {
        engine.clearVisibleError()
    }

    private func apply(snapshot: TTSEngineSnapshot) {
        self.snapshot = snapshot
        frontendState = TTSEngineFrontendState(
            snapshot: snapshot,
            latestEvent: latestEvent
        )
    }
}
