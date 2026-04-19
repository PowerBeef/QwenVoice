import Combine
import Foundation

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
