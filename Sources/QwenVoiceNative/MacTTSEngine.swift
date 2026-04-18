@_exported import QwenVoiceEngineSupport
import Combine
import Foundation

public protocol MacTTSEngine: AnyObject, Sendable {
    var snapshot: TTSEngineSnapshot { get }
    var snapshotPublisher: AnyPublisher<TTSEngineSnapshot, Never> { get }

    func initialize(appSupportDirectory: URL) async throws
    func ping() async throws -> Bool
    func loadModel(id: String) async throws
    func unloadModel() async throws
    func ensureModelLoadedIfNeeded(id: String) async
    func prewarmModelIfNeeded(for request: GenerationRequest) async
    func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws
    func cancelClonePreparationIfNeeded() async
    func generate(_ request: GenerationRequest) async throws -> GenerationResult
    func generateBatch(
        _ requests: [GenerationRequest],
        progressHandler: (@Sendable (Double?, String) -> Void)?
    ) async throws -> [GenerationResult]
    func cancelActiveGeneration() async throws
    func listPreparedVoices() async throws -> [PreparedVoice]
    func enrollPreparedVoice(name: String, audioPath: String, transcript: String?) async throws -> PreparedVoice
    func deletePreparedVoice(id: String) async throws
    func clearGenerationActivity()
    func clearVisibleError()
}
