import Foundation

public typealias ExtensionRemoteErrorCode = RemoteErrorCode
public typealias ExtensionRemoteErrorPayload = RemoteErrorPayload
public typealias ExtensionEngineCodec = QwenVoiceWireCodec

public struct ExtensionEngineRequestEnvelope: Codable, Equatable, Sendable {
    public let id: UUID
    public let command: ExtensionEngineCommand

    public init(id: UUID, command: ExtensionEngineCommand) {
        self.id = id
        self.command = command
    }
}

public enum ExtensionEngineCommand: Codable, Equatable, Sendable {
    case initialize(appSupportDirectoryPath: String)
    case ping
    case loadModel(id: String)
    case unloadModel
    case prepareAudio(request: AudioPreparationRequest)
    case ensureModelLoadedIfNeeded(id: String)
    case prewarmModelIfNeeded(request: GenerationRequest)
    case prefetchInteractiveReadinessIfNeeded(request: GenerationRequest)
    case ensureCloneReferencePrimed(modelID: String, reference: CloneReference)
    case cancelClonePreparationIfNeeded
    case generate(request: GenerationRequest)
    case listPreparedVoices
    case enrollPreparedVoice(name: String, audioPath: String, transcript: String?)
    case deletePreparedVoice(id: String)
    case clearGenerationActivity
    case clearVisibleError
    case trimMemory(level: NativeMemoryTrimLevel, reason: String)
}

public struct ExtensionEngineReplyEnvelope: Codable, Equatable, Sendable {
    public let id: UUID
    public let reply: ExtensionEngineReply

    public init(id: UUID, reply: ExtensionEngineReply) {
        self.id = id
        self.reply = reply
    }
}

public enum ExtensionEngineReply: Codable, Equatable, Sendable {
    case void
    case bool(Bool)
    case capabilities(EngineCapabilities)
    case audioNormalizationResult(AudioNormalizationResult)
    case interactivePrefetchDiagnostics(InteractivePrefetchDiagnostics)
    case generationResult(GenerationResult)
    case preparedVoice(PreparedVoice)
    case preparedVoices([PreparedVoice])
    case snapshot(TTSEngineSnapshot)
    case failure(ExtensionRemoteErrorPayload)
}

public enum ExtensionEngineEventEnvelope: Codable, Equatable, Sendable {
    case snapshot(TTSEngineSnapshot)
    case generationChunk(GenerationEvent)
}

@objc public protocol VocelloEngineClientEventXPCProtocol {
    func handleEvent(_ payload: Data)
}

@objc public protocol VocelloEngineExtensionXPCProtocol {
    func perform(_ payload: Data, withReply reply: @escaping (Data) -> Void)
}
