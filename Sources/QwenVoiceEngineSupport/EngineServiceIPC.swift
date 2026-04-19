import Foundation
import QwenVoiceCore

public let QwenVoiceEngineServiceBundleIdentifier = "com.qwenvoice.app.engine-service"

public typealias RemoteErrorCode = QwenVoiceCore.RemoteErrorCode
public typealias RemoteErrorPayload = QwenVoiceCore.RemoteErrorPayload
public typealias EngineCapabilities = QwenVoiceCore.EngineCapabilities
public typealias EngineLifecycleState = QwenVoiceCore.EngineLifecycleState
public typealias EngineServiceCodec = QwenVoiceCore.QwenVoiceWireCodec

public struct EngineRequestEnvelope: Codable, Equatable, Sendable {
    public let id: UUID
    public let command: EngineCommand

    public init(id: UUID, command: EngineCommand) {
        self.id = id
        self.command = command
    }
}

public enum EngineCommand: Codable, Equatable, Sendable {
    case initialize(appSupportDirectoryPath: String)
    case ping
    case loadModel(id: String)
    case unloadModel
    case ensureModelLoadedIfNeeded(id: String)
    case prewarmModelIfNeeded(request: GenerationRequest)
    case ensureCloneReferencePrimed(modelID: String, reference: CloneReference)
    case cancelClonePreparationIfNeeded
    case generate(request: GenerationRequest)
    case generateBatch(commandID: UUID, requests: [GenerationRequest])
    case cancelActiveGeneration
    case listPreparedVoices
    case enrollPreparedVoice(name: String, audioPath: String, transcript: String?)
    case deletePreparedVoice(id: String)
    case clearGenerationActivity
    case clearVisibleError
}

public struct EngineReplyEnvelope: Codable, Equatable, Sendable {
    public let id: UUID
    public let reply: EngineReply

    public init(id: UUID, reply: EngineReply) {
        self.id = id
        self.reply = reply
    }
}

public enum EngineReply: Codable, Equatable, Sendable {
    case void
    case bool(Bool)
    case capabilities(EngineCapabilities)
    case generationResult(GenerationResult)
    case generationResults([GenerationResult])
    case preparedVoice(PreparedVoice)
    case preparedVoices([PreparedVoice])
    case snapshot(TTSEngineSnapshot)
    case failure(RemoteErrorPayload)
}

public enum EngineEventEnvelope: Codable, Equatable, Sendable {
    case snapshot(TTSEngineSnapshot)
    case batchProgress(EngineBatchProgressUpdate)
    case generationChunk(GenerationEvent)
}

@objc public protocol QwenVoiceEngineClientEventXPCProtocol {
    func handleEvent(_ payload: Data)
}

@objc public protocol QwenVoiceEngineServiceXPCProtocol {
    func perform(_ payload: Data, withReply reply: @escaping (Data) -> Void)
}
