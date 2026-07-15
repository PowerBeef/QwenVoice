import Foundation

/// Stable Qwen3 synthesis modes owned by Vocello.
public enum VocelloQwen3SynthesisMode: String, CaseIterable, Codable, Hashable, Sendable {
    case customVoice = "custom_voice"
    case voiceDesign = "voice_design"
    case voiceClone = "voice_clone"
}

/// Runtime features that a prepared model bundle may advertise.
public enum VocelloQwen3Capability: String, CaseIterable, Codable, Hashable, Sendable {
    case streaming
    case customVoice = "custom_voice"
    case instructionControl = "instruction_control"
    case voiceDesign = "voice_design"
    case voiceClone = "voice_clone"
    case audioOnlyClone = "audio_only_clone"
    case typedDiagnostics = "typed_diagnostics"
}

/// Ordered, deterministic capability inventory for one model bundle.
public struct VocelloQwen3CapabilitySet: Codable, Hashable, Sendable {
    public let values: [VocelloQwen3Capability]

    public init(_ values: some Sequence<VocelloQwen3Capability>) {
        self.values = Array(Set(values)).sorted { $0.rawValue < $1.rawValue }
    }

    public func contains(_ capability: VocelloQwen3Capability) -> Bool {
        values.contains(capability)
    }

    public func supports(_ mode: VocelloQwen3SynthesisMode) -> Bool {
        switch mode {
        case .customVoice: contains(.customVoice)
        case .voiceDesign: contains(.voiceDesign)
        case .voiceClone: contains(.voiceClone)
        }
    }
}

/// Immutable model and artifact identity. The prepared directory is deliberately
/// kept on `VocelloQwen3PreparedModelBundle` and out of diagnostics.
public struct VocelloQwen3ModelIdentity: Codable, Hashable, Sendable {
    public let modelID: String
    public let repositoryID: String
    public let revision: String
    public let artifactVersion: String

    public init(
        modelID: String,
        repositoryID: String,
        revision: String,
        artifactVersion: String
    ) {
        self.modelID = modelID
        self.repositoryID = repositoryID
        self.revision = revision
        self.artifactVersion = artifactVersion
    }
}

/// A verified, prepared Qwen3 bundle ready for the owned runtime loader.
public struct VocelloQwen3PreparedModelBundle: Hashable, Sendable {
    public let identity: VocelloQwen3ModelIdentity
    public let preparedDirectory: URL
    public let modelType: String?
    public let trustedPreparedCheckpoint: Bool
    public let capabilities: VocelloQwen3CapabilitySet

    public init(
        identity: VocelloQwen3ModelIdentity,
        preparedDirectory: URL,
        modelType: String? = "qwen3_tts",
        trustedPreparedCheckpoint: Bool,
        capabilities: VocelloQwen3CapabilitySet
    ) {
        self.identity = identity
        self.preparedDirectory = preparedDirectory
        self.modelType = modelType
        self.trustedPreparedCheckpoint = trustedPreparedCheckpoint
        self.capabilities = capabilities
    }
}

/// Typed sampling policy. These values describe request policy; the compatibility
/// adapter remains responsible for constructing MLXLM's `GenerateParameters`.
public struct VocelloQwen3SamplingConfiguration: Codable, Hashable, Sendable {
    /// The effective Qwen3 talker top-K used by the current compatibility
    /// adapter. `GenerateParameters` has no top-K carrier, so a different
    /// request-local value fails closed instead of being silently ignored.
    public static let compatibilityDefaultTopK = 50

    public let maxNewTokens: Int
    public let temperature: Float
    public let topP: Float
    public let topK: Int
    public let repetitionPenalty: Float
    public let seed: UInt64?

    public init(
        maxNewTokens: Int,
        temperature: Float,
        topP: Float,
        topK: Int,
        repetitionPenalty: Float,
        seed: UInt64? = nil
    ) {
        self.maxNewTokens = maxNewTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repetitionPenalty = repetitionPenalty
        self.seed = seed
    }

    public func validated() throws -> Self {
        guard maxNewTokens > 0 else { throw VocelloQwen3ContractError.invalidMaxNewTokens }
        guard temperature >= 0 else { throw VocelloQwen3ContractError.invalidTemperature }
        guard topP > 0, topP <= 1 else { throw VocelloQwen3ContractError.invalidTopP }
        guard topK > 0 else { throw VocelloQwen3ContractError.invalidTopK }
        guard repetitionPenalty > 0 else { throw VocelloQwen3ContractError.invalidRepetitionPenalty }
        return self
    }

    func validatedForCompatibilityAdapter() throws -> Self {
        let validated = try validated()
        guard topK == Self.compatibilityDefaultTopK else {
            throw VocelloQwen3ContractError.unsupportedRequestTopK(topK)
        }
        guard seed == nil else {
            throw VocelloQwen3ContractError.unsupportedRequestSeed
        }
        return validated
    }
}

/// Per-request memory policy resolved by the host before it crosses the facade.
public struct VocelloQwen3MemoryConfiguration: Codable, Hashable, Sendable {
    public let clearCacheOnStreamChunk: Bool
    public let tokenMemoryClearCadence: Int
    public let talkerKVGeneratedWindow: Int?

    public init(
        clearCacheOnStreamChunk: Bool,
        tokenMemoryClearCadence: Int,
        talkerKVGeneratedWindow: Int? = nil
    ) {
        self.clearCacheOnStreamChunk = clearCacheOnStreamChunk
        self.tokenMemoryClearCadence = tokenMemoryClearCadence
        self.talkerKVGeneratedWindow = talkerKVGeneratedWindow
    }

    public func validated() throws -> Self {
        guard tokenMemoryClearCadence > 0 else {
            throw VocelloQwen3ContractError.invalidMemoryClearCadence
        }
        if let talkerKVGeneratedWindow, talkerKVGeneratedWindow <= 0 {
            throw VocelloQwen3ContractError.invalidTalkerKVWindow
        }
        return self
    }
}

public enum VocelloQwen3SynthesisInput: Codable, Hashable, Sendable {
    case customVoice(speakerID: String, deliveryInstruction: String?)
    case voiceDesign(description: String)
    case voiceClone(referenceID: String)

    public var mode: VocelloQwen3SynthesisMode {
        switch self {
        case .customVoice: .customVoice
        case .voiceDesign: .voiceDesign
        case .voiceClone: .voiceClone
        }
    }
}

/// Product request boundary. Reference audio/tensors are resolved separately by
/// the host so this value remains portable and deterministic.
public struct VocelloQwen3SynthesisRequest: Codable, Hashable, Sendable {
    public let generationID: UUID
    public let text: String
    public let language: String
    public let input: VocelloQwen3SynthesisInput
    public let sampling: VocelloQwen3SamplingConfiguration
    public let memory: VocelloQwen3MemoryConfiguration

    public init(
        generationID: UUID,
        text: String,
        language: String,
        input: VocelloQwen3SynthesisInput,
        sampling: VocelloQwen3SamplingConfiguration,
        memory: VocelloQwen3MemoryConfiguration
    ) {
        self.generationID = generationID
        self.text = text
        self.language = language
        self.input = input
        self.sampling = sampling
        self.memory = memory
    }

    public var mode: VocelloQwen3SynthesisMode { input.mode }

    public func validated(for capabilities: VocelloQwen3CapabilitySet) throws -> Self {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VocelloQwen3ContractError.emptyText
        }
        guard !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VocelloQwen3ContractError.emptyLanguage
        }
        guard capabilities.supports(mode) else {
            throw VocelloQwen3ContractError.unsupportedMode(mode)
        }
        _ = try sampling.validatedForCompatibilityAdapter()
        _ = try memory.validated()
        return self
    }
}

public enum VocelloQwen3CancellationReason: String, Codable, Hashable, Sendable {
    case user
    case memoryPressure = "memory_pressure"
    case superseded
    case shutdown
}

public enum VocelloQwen3FinishReason: String, Codable, Hashable, Sendable {
    case endOfSequence = "end_of_sequence"
    case maximumTokens = "maximum_tokens"
}

public enum VocelloQwen3FailureCode: String, Codable, Hashable, Sendable {
    case contractViolation = "contract_violation"
    case incompatibleModel = "incompatible_model"
    case memoryPressure = "memory_pressure"
    case runtime
    case unknown
}

public enum VocelloQwen3TerminalOutcome: Codable, Hashable, Sendable {
    case completed(VocelloQwen3FinishReason)
    case cancelled(VocelloQwen3CancellationReason)
    case failed(VocelloQwen3FailureCode)
}

public enum VocelloQwen3DiagnosticPhase: String, Codable, Hashable, Sendable {
    case modelPreparation = "model_preparation"
    case modelLoad = "model_load"
    case prewarm
    case synthesis
    case decode
    case finalization
}

public enum VocelloQwen3DiagnosticDisposition: String, Codable, Hashable, Sendable {
    case began
    case completed
    case cancelled
    case failed
    case observed
}

/// Privacy-safe typed runtime evidence. It intentionally has no raw message,
/// path, prompt, transcript, URL, or arbitrary metadata dictionary.
public struct VocelloQwen3DiagnosticEvent: Codable, Hashable, Sendable {
    public let generationID: UUID?
    public let phase: VocelloQwen3DiagnosticPhase
    public let disposition: VocelloQwen3DiagnosticDisposition
    public let elapsedMilliseconds: Int?
    public let generatedTokenCount: Int?
    public let audioFrameCount: Int?
    public let peakMemoryBytes: UInt64?
    public let failureCode: VocelloQwen3FailureCode?

    public init(
        generationID: UUID? = nil,
        phase: VocelloQwen3DiagnosticPhase,
        disposition: VocelloQwen3DiagnosticDisposition,
        elapsedMilliseconds: Int? = nil,
        generatedTokenCount: Int? = nil,
        audioFrameCount: Int? = nil,
        peakMemoryBytes: UInt64? = nil,
        failureCode: VocelloQwen3FailureCode? = nil
    ) {
        self.generationID = generationID
        self.phase = phase
        self.disposition = disposition
        self.elapsedMilliseconds = elapsedMilliseconds
        self.generatedTokenCount = generatedTokenCount
        self.audioFrameCount = audioFrameCount
        self.peakMemoryBytes = peakMemoryBytes
        self.failureCode = failureCode
    }
}

public typealias VocelloQwen3DiagnosticSink = @Sendable (VocelloQwen3DiagnosticEvent) async -> Void

public enum VocelloQwen3ContractError: Error, Equatable, Sendable {
    case incompatibleLoadedModel
    case missingClonePrompt
    case emptyText
    case emptyLanguage
    case unsupportedMode(VocelloQwen3SynthesisMode)
    case invalidMaxNewTokens
    case invalidTemperature
    case invalidTopP
    case invalidTopK
    case invalidRepetitionPenalty
    case unsupportedRequestTopK(Int)
    case unsupportedRequestSeed
    case invalidMemoryClearCadence
    case invalidTalkerKVWindow
}
