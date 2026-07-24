import Combine
import Foundation
import QwenVoiceCore

@MainActor
public final class TTSEngineStore: ObservableObject {
    @Published public private(set) var snapshot: TTSEngineSnapshot
    @Published public private(set) var frontendState: TTSEngineFrontendState
    @Published public private(set) var latestEvent: GenerationEvent?
    @Published public private(set) var hasActiveGeneration = false

    public var isReady: Bool { snapshot.isReady }
    public var loadState: EngineLoadState { snapshot.loadState }
    public var clonePreparationState: ClonePreparationState { snapshot.clonePreparationState }
    public var visibleErrorMessage: String? { snapshot.visibleErrorMessage }
    public var lifecycleState: EngineLifecycleState { frontendState.lifecycleState }

    private let engine: any MacTTSEngine
    private var snapshotCancellable: AnyCancellable?
    private var activeGenerationDepth = 0
    /// Sustained performance-critical activity (for example a long-form
    /// project spanning several generations plus QC and assembly). Keeps the
    /// generation performance gate engaged across inter-segment gaps without
    /// tripping the single-generation busy guard.
    @Published public private(set) var hasSustainedPerformanceActivity = false
    private var sustainedPerformanceDepth = 0

    public init(engine: any MacTTSEngine) {
        self.engine = engine
        self.snapshot = engine.snapshot
        self.frontendState = TTSEngineFrontendState(snapshot: engine.snapshot)
        snapshotCancellable = engine.snapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.apply(snapshot: snapshot)
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

    /// Retire the engine's backing process while idle (see
    /// `MacTTSEngine.retireServiceIfIdle`). Refused client-side when a
    /// generation is active.
    @discardableResult
    public func retireServiceIfIdle() async -> Bool {
        guard !hasActiveGeneration else { return false }
        return await engine.retireServiceIfIdle()
    }

    public func ensureModelLoadedIfNeeded(id: String) async {
        await engine.ensureModelLoadedIfNeeded(id: id)
    }

    public func prewarmModelIfNeeded(for request: GenerationRequest) async {
        await engine.prewarmModelIfNeeded(for: request)
    }

    public func prefetchInteractiveReadinessIfNeeded(
        for request: GenerationRequest
    ) async -> InteractivePrefetchDiagnostics? {
        await engine.prefetchInteractiveReadinessIfNeeded(for: request)
    }

    public func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {
        try await engine.ensureCloneReferencePrimed(modelID: modelID, reference: reference)
    }

    public func cancelClonePreparationIfNeeded() async {
        await engine.cancelClonePreparationIfNeeded()
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        try beginActiveGeneration()
        defer { finishActiveGeneration() }
        if BenchForceColdPolicy.shouldUnloadBeforeGeneration {
            try? await unloadModel()
        }
        return try await engine.generate(request)
    }

    public func cancelActiveGeneration() async throws {
        defer {
            activeGenerationDepth = 0
            hasActiveGeneration = Self.snapshotHasActiveGeneration(snapshot)
        }
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
        let nextFrontendState = TTSEngineFrontendState(
            snapshot: snapshot,
            latestEvent: latestEvent?.withoutPreviewAudioPayload()
        )
        let nextHasActiveGeneration = activeGenerationDepth > 0 || Self.snapshotHasActiveGeneration(snapshot)
        guard self.snapshot != snapshot
            || frontendState != nextFrontendState
            || hasActiveGeneration != nextHasActiveGeneration else {
            return
        }
        self.snapshot = snapshot
        frontendState = nextFrontendState
        hasActiveGeneration = nextHasActiveGeneration
    }

    public func beginSustainedPerformanceActivity() {
        sustainedPerformanceDepth += 1
        hasSustainedPerformanceActivity = true
    }

    public func endSustainedPerformanceActivity() {
        sustainedPerformanceDepth = max(sustainedPerformanceDepth - 1, 0)
        hasSustainedPerformanceActivity = sustainedPerformanceDepth > 0
    }

    private func beginActiveGeneration() throws {
        guard !hasActiveGeneration else {
            throw TTSEngineError.generationFailed(
                "The engine is already generating audio. Wait for it to finish or cancel it before starting another generation."
            )
        }
        activeGenerationDepth += 1
        hasActiveGeneration = true
    }

    private func finishActiveGeneration() {
        activeGenerationDepth = max(activeGenerationDepth - 1, 0)
        hasActiveGeneration = activeGenerationDepth > 0 || Self.snapshotHasActiveGeneration(snapshot)
    }

    private static func snapshotHasActiveGeneration(_ snapshot: TTSEngineSnapshot) -> Bool {
        if case .running(_, let label, _) = snapshot.loadState,
           label != EngineActivityLabels.preparingVoiceReference {
            return true
        }
        return false
    }
}
