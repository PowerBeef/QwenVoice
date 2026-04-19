import Foundation

public enum ExtensionRemoteErrorCode: String, Codable, Equatable, Sendable {
    case generic
    case cancelled
}

public struct ExtensionRemoteErrorPayload: Error, Codable, Equatable, Sendable, LocalizedError {
    public let message: String
    public let domain: String?
    public let code: ExtensionRemoteErrorCode

    public init(
        message: String,
        domain: String? = nil,
        code: ExtensionRemoteErrorCode = .generic
    ) {
        self.message = message
        self.domain = domain
        self.code = code
    }

    public var errorDescription: String? {
        message
    }

    public static func make(for error: Error) -> ExtensionRemoteErrorPayload {
        if let payload = error as? ExtensionRemoteErrorPayload {
            return payload
        }

        let nsError = error as NSError
        return ExtensionRemoteErrorPayload(
            message: nsError.localizedDescription,
            domain: nsError.domain,
            code: error is CancellationError ? .cancelled : .generic
        )
    }
}

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

public struct ExtensionEngineReplyEnvelope: Codable, Sendable {
    public let id: UUID
    public let reply: ExtensionEngineReply

    public init(id: UUID, reply: ExtensionEngineReply) {
        self.id = id
        self.reply = reply
    }
}

public enum ExtensionEngineReply: Codable, Sendable {
    case void
    case bool(Bool)
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

public enum ExtensionEngineCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(T.self, from: data)
    }
}

@objc public protocol VocelloEngineClientEventXPCProtocol {
    func handleEvent(_ payload: Data)
}

@objc public protocol VocelloEngineExtensionXPCProtocol {
    func perform(_ payload: Data, withReply reply: @escaping (Data) -> Void)
}
