import Foundation

public let QwenVoiceEngineServiceBundleIdentifier = "com.qwenvoice.app.engine-service"

public enum RemoteErrorCode: String, Codable, Equatable, Sendable {
    case generic
    case cancelled
}

public struct RemoteErrorPayload: Error, Codable, Equatable, Sendable, LocalizedError {
    public let message: String
    public let domain: String?
    public let code: RemoteErrorCode

    public init(
        message: String,
        domain: String? = nil,
        code: RemoteErrorCode = .generic
    ) {
        self.message = message
        self.domain = domain
        self.code = code
    }

    public var errorDescription: String? {
        message
    }

    public static func make(for error: Error) -> RemoteErrorPayload {
        if let remoteError = error as? RemoteErrorPayload {
            return remoteError
        }
        let nsError = error as NSError
        let code: RemoteErrorCode = error is CancellationError ? .cancelled : .generic
        return RemoteErrorPayload(
            message: nsError.localizedDescription,
            domain: nsError.domain,
            code: code
        )
    }
}

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

public enum EngineServiceCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(T.self, from: data)
    }
}

@objc public protocol QwenVoiceEngineClientEventXPCProtocol {
    func handleEvent(_ payload: Data)
}

@objc public protocol QwenVoiceEngineServiceXPCProtocol {
    func perform(_ payload: Data, withReply reply: @escaping (Data) -> Void)
}
