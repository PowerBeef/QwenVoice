import Combine
import Foundation

public struct TTSEngineFrontendState: Equatable, Sendable {
    public let isReady: Bool
    public let lifecycleState: EngineLifecycleState
    public let loadState: EngineLoadState
    public let clonePreparationState: ClonePreparationState
    public let latestEvent: GenerationEvent?
    public let visibleErrorMessage: String?

    public init(
        isReady: Bool,
        lifecycleState: EngineLifecycleState,
        loadState: EngineLoadState,
        clonePreparationState: ClonePreparationState,
        latestEvent: GenerationEvent?,
        visibleErrorMessage: String?
    ) {
        self.isReady = isReady
        self.lifecycleState = lifecycleState
        self.loadState = loadState
        self.clonePreparationState = clonePreparationState
        self.latestEvent = latestEvent
        self.visibleErrorMessage = visibleErrorMessage
    }

    public init(
        snapshot: TTSEngineSnapshot,
        latestEvent: GenerationEvent? = nil,
        lifecycleState: EngineLifecycleState? = nil
    ) {
        let resolvedLifecycleState = lifecycleState
            ?? Self.defaultLifecycleState(
                isReady: snapshot.isReady,
                visibleErrorMessage: snapshot.visibleErrorMessage
            )
        self.init(
            isReady: snapshot.isReady,
            lifecycleState: resolvedLifecycleState,
            loadState: snapshot.loadState,
            clonePreparationState: snapshot.clonePreparationState,
            latestEvent: latestEvent,
            visibleErrorMessage: snapshot.visibleErrorMessage
        )
    }

    public func updating(
        latestEvent: GenerationEvent? = nil,
        lifecycleState: EngineLifecycleState? = nil
    ) -> TTSEngineFrontendState {
        TTSEngineFrontendState(
            isReady: isReady,
            lifecycleState: lifecycleState ?? self.lifecycleState,
            loadState: loadState,
            clonePreparationState: clonePreparationState,
            latestEvent: latestEvent ?? self.latestEvent,
            visibleErrorMessage: visibleErrorMessage
        )
    }

    private static func defaultLifecycleState(
        isReady: Bool,
        visibleErrorMessage: String?
    ) -> EngineLifecycleState {
        if isReady {
            return .connected
        }
        if let visibleErrorMessage,
           !visibleErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failed
        }
        return .idle
    }
}

@MainActor
public protocol TTSEngine: ObservableObject {
    var modelRegistry: any ModelRegistry { get }
    var loadState: EngineLoadState { get }
    var clonePreparationState: ClonePreparationState { get }
    var latestEvent: GenerationEvent? { get }
    var isReady: Bool { get }
    var visibleErrorMessage: String? { get }

    func supportDecision(for request: GenerationRequest) -> GenerationSupportDecision
    func start()
    func stop()
    func initialize(appSupportDirectory: URL) async throws
    func ping() async throws -> Bool
    func loadModel(id: String) async throws
    func unloadModel() async throws
    func prepareAudio(_ request: AudioPreparationRequest) async throws -> AudioNormalizationResult
    func ensureModelLoadedIfNeeded(id: String) async
    func prewarmModelIfNeeded(for request: GenerationRequest) async
    func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws
    func cancelClonePreparationIfNeeded() async
    func generate(_ request: GenerationRequest) async throws -> GenerationResult
    func listPreparedVoices() async throws -> [PreparedVoice]
    func enrollPreparedVoice(name: String, audioPath: String, transcript: String?) async throws -> PreparedVoice
    func deletePreparedVoice(id: String) async throws
    func importReferenceAudio(from sourceURL: URL) throws -> ImportedReferenceAudio
    func exportGeneratedAudio(from sourceURL: URL, to destinationURL: URL) throws -> ExportedDocument
    func clearGenerationActivity()
    func clearVisibleError()
}

@MainActor
public protocol TTSEngineRuntimeControlling: TTSEngine {
    func prefetchInteractiveReadinessIfNeeded(
        for request: GenerationRequest
    ) async -> InteractivePrefetchDiagnostics?
    func setVisibleError(_ message: String?)
    func setAllowsProactiveWarmOperations(_ allow: Bool)
    func trimMemory(level: NativeMemoryTrimLevel, reason: String) async
}
