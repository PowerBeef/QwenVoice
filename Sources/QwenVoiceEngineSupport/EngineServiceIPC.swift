import Foundation
import QwenVoiceCore

public let QwenVoiceEngineServiceBundleIdentifier = "com.qwenvoice.app.engine-service"

public typealias RemoteErrorCode = QwenVoiceCore.RemoteErrorCode
public typealias RemoteErrorPayload = QwenVoiceCore.RemoteErrorPayload
public typealias EngineCapabilities = QwenVoiceCore.EngineCapabilities
public typealias EngineLifecycleState = QwenVoiceCore.EngineLifecycleState
public typealias InteractivePrefetchDiagnostics = QwenVoiceCore.InteractivePrefetchDiagnostics
public typealias EngineServiceCodec = QwenVoiceCore.QwenVoiceWireCodec

public struct EngineRequestEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = QwenVoiceWireSchema.currentVersion
    public let schemaVersion: Int
    public let id: UUID
    public let command: EngineCommand

    public init(
        id: UUID,
        command: EngineCommand,
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
        self.command = try container.decode(EngineCommand.self, forKey: .command)
    }
}

public enum EngineCommand: Codable, Equatable, Sendable {
    case initialize(appSupportDirectoryPath: String)
    case ping
    case loadModel(id: String)
    case unloadModel
    case ensureModelLoadedIfNeeded(id: String)
    case prewarmModelIfNeeded(request: GenerationRequest)
    case prefetchInteractiveReadinessIfNeeded(
        request: GenerationRequest,
        customPrewarmDepth: String?
    )
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
    public static let currentSchemaVersion = QwenVoiceWireSchema.currentVersion
    public let schemaVersion: Int
    public let id: UUID
    public let reply: EngineReply

    public init(
        id: UUID,
        reply: EngineReply,
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
        self.reply = try container.decode(EngineReply.self, forKey: .reply)
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
    case interactivePrefetchDiagnostics(InteractivePrefetchDiagnostics)
    case snapshot(TTSEngineSnapshot)
    case failure(RemoteErrorPayload)
}

public enum EngineEventEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = QwenVoiceWireSchema.currentVersion

    case snapshot(TTSEngineSnapshot)
    case batchProgress(EngineBatchProgressUpdate)
    case generationChunk(GenerationEvent)

    public var schemaVersion: Int {
        Self.currentSchemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case snapshot
        case batchProgress
        case generationChunk
    }

    private enum LegacyEngineEventEnvelope: Codable {
        case snapshot(TTSEngineSnapshot)
        case batchProgress(EngineBatchProgressUpdate)
        case generationChunk(GenerationEvent)

        var modern: EngineEventEnvelope {
            switch self {
            case .snapshot(let snapshot):
                return .snapshot(snapshot)
            case .batchProgress(let progress):
                return .batchProgress(progress)
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
            if container.contains(.batchProgress) {
                self = .batchProgress(try container.decode(EngineBatchProgressUpdate.self, forKey: .batchProgress))
                return
            }
            if container.contains(.generationChunk) {
                self = .generationChunk(try container.decode(GenerationEvent.self, forKey: .generationChunk))
                return
            }
        } catch {
            if !container.contains(.schemaVersion) {
                self = try LegacyEngineEventEnvelope(from: decoder).modern
                return
            }
            throw error
        }

        if !container.contains(.schemaVersion) {
            self = try LegacyEngineEventEnvelope(from: decoder).modern
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Missing EngineEventEnvelope payload."
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        switch self {
        case .snapshot(let snapshot):
            try container.encode(snapshot, forKey: .snapshot)
        case .batchProgress(let progress):
            try container.encode(progress, forKey: .batchProgress)
        case .generationChunk(let event):
            try container.encode(event, forKey: .generationChunk)
        }
    }
}

@objc public protocol QwenVoiceEngineClientEventXPCProtocol {
    func handleEvent(_ payload: Data)
}

@objc public protocol QwenVoiceEngineServiceXPCProtocol {
    func perform(_ payload: Data, withReply reply: @escaping (Data) -> Void)
}
