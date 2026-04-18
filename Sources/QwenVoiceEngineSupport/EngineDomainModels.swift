import Foundation

public enum EngineLoadState: Equatable, Sendable, Codable {
    case idle
    case starting
    case loaded(modelID: String)
    case running(modelID: String?, label: String?, fraction: Double?)
    case failed(message: String)

    public var currentModelID: String? {
        switch self {
        case .loaded(let modelID):
            return modelID
        case .running(let modelID, _, _):
            return modelID
        case .idle, .starting, .failed:
            return nil
        }
    }
}

public enum ClonePreparationState: Equatable, Sendable, Codable {
    case idle
    case preparing(key: String?)
    case primed(key: String?)
    case failed(key: String?, message: String?)

    public var key: String? {
        switch self {
        case .idle:
            return nil
        case .preparing(let key), .primed(let key), .failed(let key, _):
            return key
        }
    }

    public var errorMessage: String? {
        if case .failed(_, let message) = self {
            return message
        }
        return nil
    }

    public var isPreparingOrPrimed: Bool {
        switch self {
        case .preparing, .primed:
            return true
        case .idle, .failed:
            return false
        }
    }

    public var isPrimed: Bool {
        if case .primed = self {
            return true
        }
        return false
    }
}

public struct CloneReference: Equatable, Sendable, Codable {
    public let audioPath: String
    public let transcript: String?
    public let preparedVoiceID: String?

    public init(audioPath: String, transcript: String? = nil, preparedVoiceID: String? = nil) {
        self.audioPath = audioPath
        self.transcript = transcript
        self.preparedVoiceID = preparedVoiceID
    }
}

public struct PreparedVoice: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let name: String
    public let audioPath: String
    public let hasTranscript: Bool

    public init(id: String, name: String, audioPath: String, hasTranscript: Bool) {
        self.id = id
        self.name = name
        self.audioPath = audioPath
        self.hasTranscript = hasTranscript
    }
}

public struct NativeTelemetryStageMark: Hashable, Codable, Sendable {
    public let tMS: Int
    public let stage: String
    public let metadata: [String: String]

    public init(tMS: Int, stage: String, metadata: [String: String] = [:]) {
        self.tMS = tMS
        self.stage = stage
        self.metadata = metadata
    }
}

public struct BenchmarkSample: Equatable, Sendable, Codable {
    public let tokenCount: Int?
    public let processingTimeSeconds: Double?
    public let peakMemoryUsage: Double?
    public let streamingUsed: Bool
    public let preparedCloneUsed: Bool?
    public let cloneCacheHit: Bool?
    public let firstChunkMs: Int?
    public let timingsMS: [String: Int]
    public let booleanFlags: [String: Bool]
    public let stringFlags: [String: String]
    public let telemetryStageMarks: [NativeTelemetryStageMark]

    public init(
        tokenCount: Int? = nil,
        processingTimeSeconds: Double? = nil,
        peakMemoryUsage: Double? = nil,
        streamingUsed: Bool,
        preparedCloneUsed: Bool? = nil,
        cloneCacheHit: Bool? = nil,
        firstChunkMs: Int? = nil,
        timingsMS: [String: Int] = [:],
        booleanFlags: [String: Bool] = [:],
        stringFlags: [String: String] = [:],
        telemetryStageMarks: [NativeTelemetryStageMark] = []
    ) {
        self.tokenCount = tokenCount
        self.processingTimeSeconds = processingTimeSeconds
        self.peakMemoryUsage = peakMemoryUsage
        self.streamingUsed = streamingUsed
        self.preparedCloneUsed = preparedCloneUsed
        self.cloneCacheHit = cloneCacheHit
        self.firstChunkMs = firstChunkMs
        self.timingsMS = timingsMS
        self.booleanFlags = booleanFlags
        self.stringFlags = stringFlags
        self.telemetryStageMarks = telemetryStageMarks
    }
}

public struct GenerationEvent: Equatable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable {
        case streamChunk
    }

    public let kind: Kind
    public let requestID: Int
    public let mode: String
    public let title: String
    public let chunkPath: String?
    public let isFinal: Bool
    public let chunkDurationSeconds: Double?
    public let cumulativeDurationSeconds: Double?
    public let streamSessionDirectory: String?

    public init(
        kind: Kind,
        requestID: Int,
        mode: String,
        title: String,
        chunkPath: String? = nil,
        isFinal: Bool,
        chunkDurationSeconds: Double? = nil,
        cumulativeDurationSeconds: Double? = nil,
        streamSessionDirectory: String? = nil
    ) {
        self.kind = kind
        self.requestID = requestID
        self.mode = mode
        self.title = title
        self.chunkPath = chunkPath
        self.isFinal = isFinal
        self.chunkDurationSeconds = chunkDurationSeconds
        self.cumulativeDurationSeconds = cumulativeDurationSeconds
        self.streamSessionDirectory = streamSessionDirectory
    }
}

public struct GenerationRequest: Equatable, Sendable, Codable {
    public enum Payload: Equatable, Sendable, Codable {
        case custom(speakerID: String, deliveryStyle: String?)
        case design(voiceDescription: String, deliveryStyle: String?)
        case clone(reference: CloneReference)
    }

    public let modelID: String
    public let text: String
    public let outputPath: String
    public let shouldStream: Bool
    public let batchIndex: Int?
    public let batchTotal: Int?
    public let streamingTitle: String?
    public let payload: Payload

    public init(
        modelID: String,
        text: String,
        outputPath: String,
        shouldStream: Bool = false,
        batchIndex: Int? = nil,
        batchTotal: Int? = nil,
        streamingTitle: String? = nil,
        payload: Payload
    ) {
        self.modelID = modelID
        self.text = text
        self.outputPath = outputPath
        self.shouldStream = shouldStream
        self.batchIndex = batchIndex
        self.batchTotal = batchTotal
        self.streamingTitle = streamingTitle
        self.payload = payload
    }

    public var modeIdentifier: String {
        switch payload {
        case .custom:
            return "custom"
        case .design:
            return "design"
        case .clone:
            return "clone"
        }
    }
}

public struct GenerationResult: Equatable, Sendable, Codable {
    public let audioPath: String
    public let durationSeconds: Double
    public let streamSessionDirectory: String?
    public let benchmarkSample: BenchmarkSample?

    public init(
        audioPath: String,
        durationSeconds: Double,
        streamSessionDirectory: String?,
        benchmarkSample: BenchmarkSample?
    ) {
        self.audioPath = audioPath
        self.durationSeconds = durationSeconds
        self.streamSessionDirectory = streamSessionDirectory
        self.benchmarkSample = benchmarkSample
    }

    public var usedStreaming: Bool {
        benchmarkSample?.streamingUsed ?? false
    }
}

public struct TTSEngineSnapshot: Equatable, Sendable, Codable {
    public let isReady: Bool
    public let loadState: EngineLoadState
    public let clonePreparationState: ClonePreparationState
    public let visibleErrorMessage: String?

    public init(
        isReady: Bool,
        loadState: EngineLoadState,
        clonePreparationState: ClonePreparationState,
        visibleErrorMessage: String?
    ) {
        self.isReady = isReady
        self.loadState = loadState
        self.clonePreparationState = clonePreparationState
        self.visibleErrorMessage = visibleErrorMessage
    }
}

public struct EngineBatchProgressUpdate: Equatable, Sendable, Codable {
    public let commandID: UUID
    public let fraction: Double?
    public let message: String

    public init(commandID: UUID, fraction: Double?, message: String) {
        self.commandID = commandID
        self.fraction = fraction
        self.message = message
    }
}
