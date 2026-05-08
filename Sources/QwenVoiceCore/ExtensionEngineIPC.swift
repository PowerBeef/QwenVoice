import Foundation

public typealias ExtensionRemoteErrorCode = RemoteErrorCode
public typealias ExtensionRemoteErrorPayload = RemoteErrorPayload
public typealias ExtensionEngineCodec = QwenVoiceWireCodec

public struct ExtensionEngineRequestEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = QwenVoiceWireSchema.currentVersion
    public let schemaVersion: Int
    public let id: UUID
    public let command: ExtensionEngineCommand

    public init(
        id: UUID,
        command: ExtensionEngineCommand,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.command = command
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case command
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        try QwenVoiceWireSchema.validate(version: version, codingPath: decoder.codingPath)
        self.schemaVersion = version
        self.id = try container.decode(UUID.self, forKey: .id)
        self.command = try container.decode(ExtensionEngineCommand.self, forKey: .command)
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
    case prefetchInteractiveReadinessIfNeeded(
        request: GenerationRequest,
        customPrewarmDepth: String?
    )
    case ensureCloneReferencePrimed(modelID: String, reference: CloneReference)
    case cancelClonePreparationIfNeeded
    case cancelActiveGeneration
    case generate(request: GenerationRequest)
    case listPreparedVoices
    case enrollPreparedVoice(name: String, audioPath: String, transcript: String?)
    case deletePreparedVoice(id: String)
    case clearGenerationActivity
    case clearVisibleError
    case trimMemory(level: NativeMemoryTrimLevel, reason: String)
}

public struct ExtensionEngineReplyEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = QwenVoiceWireSchema.currentVersion
    public let schemaVersion: Int
    public let id: UUID
    public let reply: ExtensionEngineReply

    public init(
        id: UUID,
        reply: ExtensionEngineReply,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.reply = reply
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case reply
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        try QwenVoiceWireSchema.validate(version: version, codingPath: decoder.codingPath)
        self.schemaVersion = version
        self.id = try container.decode(UUID.self, forKey: .id)
        self.reply = try container.decode(ExtensionEngineReply.self, forKey: .reply)
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
    public static let currentSchemaVersion = QwenVoiceWireSchema.currentVersion

    case snapshot(TTSEngineSnapshot)
    case generationChunk(GenerationEvent)

    public var schemaVersion: Int {
        Self.currentSchemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case snapshot
        case generationChunk
    }

    private enum LegacyExtensionEngineEventEnvelope: Codable {
        case snapshot(TTSEngineSnapshot)
        case generationChunk(GenerationEvent)

        var modern: ExtensionEngineEventEnvelope {
            switch self {
            case .snapshot(let snapshot):
                return .snapshot(snapshot)
            case .generationChunk(let event):
                return .generationChunk(event)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        try QwenVoiceWireSchema.validate(version: version, codingPath: decoder.codingPath)

        do {
            if container.contains(.snapshot) {
                self = .snapshot(try container.decode(TTSEngineSnapshot.self, forKey: .snapshot))
                return
            }
            if container.contains(.generationChunk) {
                self = .generationChunk(try container.decode(GenerationEvent.self, forKey: .generationChunk))
                return
            }
        } catch {
            if !container.contains(.schemaVersion) {
                self = try LegacyExtensionEngineEventEnvelope(from: decoder).modern
                return
            }
            throw error
        }

        if !container.contains(.schemaVersion) {
            self = try LegacyExtensionEngineEventEnvelope(from: decoder).modern
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Missing ExtensionEngineEventEnvelope payload."
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        switch self {
        case .snapshot(let snapshot):
            try container.encode(snapshot, forKey: .snapshot)
        case .generationChunk(let event):
            try container.encode(event, forKey: .generationChunk)
        }
    }
}

@objc public protocol VocelloEngineClientEventXPCProtocol {
    func handleEvent(_ payload: Data)
}

@objc public protocol VocelloEngineExtensionXPCProtocol {
    func perform(_ payload: Data, withReply reply: @escaping (Data) -> Void)
}
