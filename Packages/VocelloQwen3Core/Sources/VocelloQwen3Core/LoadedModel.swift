import Foundation
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioTTS
@preconcurrency import MLXLMCommon

/// Load-time policy owned by the Vocello facade. Raw loader options do not
/// cross the package boundary.
public struct VocelloQwen3LoadBehavior: Codable, Hashable, Sendable {
    public let trustPreparedCheckpoint: Bool
    public let preparedDirectoryAlreadyValidated: Bool
    public let loadSpeakerEncoder: Bool?
    public let loadSpeechTokenizerEncoder: Bool?
    public let skipSpeechTokenizerEval: Bool

    public init(
        trustPreparedCheckpoint: Bool = false,
        preparedDirectoryAlreadyValidated: Bool = false,
        loadSpeakerEncoder: Bool? = nil,
        loadSpeechTokenizerEncoder: Bool? = nil,
        skipSpeechTokenizerEval: Bool = false
    ) {
        self.trustPreparedCheckpoint = trustPreparedCheckpoint
        self.preparedDirectoryAlreadyValidated = preparedDirectoryAlreadyValidated
        self.loadSpeakerEncoder = loadSpeakerEncoder
        self.loadSpeechTokenizerEncoder = loadSpeechTokenizerEncoder
        self.skipSpeechTokenizerEval = skipSpeechTokenizerEval
    }

    var compatibilityValue: QwenPreparedLoadBehavior {
        QwenPreparedLoadBehavior(
            trustPreparedCheckpoint: trustPreparedCheckpoint,
            preparedDirectoryAlreadyValidated: preparedDirectoryAlreadyValidated,
            loadSpeakerEncoder: loadSpeakerEncoder,
            loadSpeechTokenizerEncoder: loadSpeechTokenizerEncoder,
            skipSpeechTokenizerEval: skipSpeechTokenizerEval
        )
    }
}

public enum VocelloQwen3GenerationFinishReason: String, Codable, Hashable, Sendable {
    case endOfSequence = "end_of_sequence"
    case maximumTokens = "maximum_tokens"
    case cancelled
    case failed
}

public struct VocelloQwen3GenerationInfo: Codable, Hashable, Sendable {
    public let promptTokenCount: Int
    public let generationTokenCount: Int
    public let prefillTime: TimeInterval
    public let generateTime: TimeInterval
    public let tokensPerSecond: Double
    public let peakMemoryUsage: Double

    init(_ value: AudioGenerationInfo) {
        promptTokenCount = value.promptTokenCount
        generationTokenCount = value.generationTokenCount
        prefillTime = value.prefillTime
        generateTime = value.generateTime
        tokensPerSecond = value.tokensPerSecond
        peakMemoryUsage = value.peakMemoryUsage
    }
}

public struct VocelloQwen3KVCacheDiagnostics: Codable, Hashable, Sendable {
    public let cacheType: String
    public let effectiveSeqLength: Int
    public let layerCount: Int
    public let headCount: Int
    public let kvHeadCount: Int
    public let headDim: Int
    public let dtypeBytes: Int
    public let estimatedFootprintMB: Double

    init(_ value: KVCacheDiagnostics) {
        cacheType = value.cacheType
        effectiveSeqLength = value.effectiveSeqLength
        layerCount = value.layerCount
        headCount = value.headCount
        kvHeadCount = value.kvHeadCount
        headDim = value.headDim
        dtypeBytes = value.dtypeBytes
        estimatedFootprintMB = value.estimatedFootprintMB
    }
}

public struct VocelloQwen3MimiDecoderTimings: Codable, Hashable, Sendable {
    public let quantizerMS: Double
    public let preConvMS: Double
    public let preTransformerMS: Double
    public let upsampleMS: Double
    public let initConvMS: Double
    public let decoderBlocksMS: Double
    public let outputSnakeMS: Double
    public let outputConvMS: Double
    public let totalMS: Double

    init(_ value: MimiDecoderStepTimings) {
        quantizerMS = value.quantizerMS
        preConvMS = value.preConvMS
        preTransformerMS = value.preTransformerMS
        upsampleMS = value.upsampleMS
        initConvMS = value.initConvMS
        decoderBlocksMS = value.decoderBlocksMS
        outputSnakeMS = value.outputSnakeMS
        outputConvMS = value.outputConvMS
        totalMS = value.totalMS
    }
}

public struct VocelloQwen3ChunkTimings: Codable, Hashable, Sendable {
    public let talkerForwardMS: Double
    public let codePredictorMS: Double
    public let audioDecoderMS: Double
    public let streamStepEvalMS: Double
    public let streamStepEvalEnqueueMS: Double
    public let streamStepEvalWaitMS: Double
    public let streamStepEOSReadMS: Double
    public let audioChunkEvalMS: Double
    public let kvCacheDiagnostics: VocelloQwen3KVCacheDiagnostics?
    public let mimiDecoderBreakdownMS: VocelloQwen3MimiDecoderTimings?

    init(_ value: ChunkSubstageTimings) {
        talkerForwardMS = value.talkerForwardMS
        codePredictorMS = value.codePredictorMS
        audioDecoderMS = value.audioDecoderMS
        streamStepEvalMS = value.streamStepEvalMS
        streamStepEvalEnqueueMS = value.streamStepEvalEnqueueMS
        streamStepEvalWaitMS = value.streamStepEvalWaitMS
        streamStepEOSReadMS = value.streamStepEOSReadMS
        audioChunkEvalMS = value.audioChunkEvalMS
        kvCacheDiagnostics = value.kvCacheDiagnostics.map(VocelloQwen3KVCacheDiagnostics.init)
        mimiDecoderBreakdownMS = value.mimiDecoderBreakdownMS.map(VocelloQwen3MimiDecoderTimings.init)
    }
}

/// Product-facing stream signal. Audio is materialized exactly where the old
/// product adapter materialized it, but the MLX tensor itself remains private.
public enum VocelloQwen3GenerationSignal: Sendable {
    case token(Int)
    case info(VocelloQwen3GenerationInfo)
    case audio([Float])
    case chunkTimings(VocelloQwen3ChunkTimings)
}

public struct VocelloQwen3GenerationCompletion: Sendable {
    public let audio: [Float]
    public let info: VocelloQwen3GenerationInfo?
    public let finishReason: VocelloQwen3GenerationFinishReason

    init(_ value: AudioGenerationCompletion) {
        audio = value.audio.asArray(Float.self)
        info = value.info.map(VocelloQwen3GenerationInfo.init)
        switch value.finishReason {
        case .eos: finishReason = .endOfSequence
        case .maxTokens: finishReason = .maximumTokens
        case .cancelled: finishReason = .cancelled
        case .failed: finishReason = .failed
        }
    }
}

public struct VocelloQwen3CloneArtifactMetadata: Codable, Hashable, Sendable {
    public let modelID: String?
    public let language: String?
    public let sourceAudioFingerprint: String?
    public let transcriptHash: String?
    public let hasTranscript: Bool?
    public let xVectorOnlyMode: Bool?
    public let runtimeProfileSignature: String?
    public let createdAt: String?

    public init(
        modelID: String? = nil,
        language: String? = nil,
        sourceAudioFingerprint: String? = nil,
        transcriptHash: String? = nil,
        hasTranscript: Bool? = nil,
        xVectorOnlyMode: Bool? = nil,
        runtimeProfileSignature: String? = nil,
        createdAt: String? = nil
    ) {
        self.modelID = modelID
        self.language = language
        self.sourceAudioFingerprint = sourceAudioFingerprint
        self.transcriptHash = transcriptHash
        self.hasTranscript = hasTranscript
        self.xVectorOnlyMode = xVectorOnlyMode
        self.runtimeProfileSignature = runtimeProfileSignature
        self.createdAt = createdAt
    }

    public func fillingCreatedAtIfNeeded() -> Self {
        guard createdAt == nil else { return self }
        return Self(
            modelID: modelID,
            language: language,
            sourceAudioFingerprint: sourceAudioFingerprint,
            transcriptHash: transcriptHash,
            hasTranscript: hasTranscript,
            xVectorOnlyMode: xVectorOnlyMode,
            runtimeProfileSignature: runtimeProfileSignature,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    fileprivate var compatibilityValue: Qwen3TTSVoiceClonePrompt.ArtifactMetadata {
        Qwen3TTSVoiceClonePrompt.ArtifactMetadata(
            modelID: modelID,
            language: language,
            sourceAudioFingerprint: sourceAudioFingerprint,
            transcriptHash: transcriptHash,
            hasTranscript: hasTranscript,
            xVectorOnlyMode: xVectorOnlyMode,
            qwen3RuntimeProfileSignature: runtimeProfileSignature,
            createdAt: createdAt
        )
    }

    fileprivate init(_ value: Qwen3TTSVoiceClonePrompt.ArtifactMetadata) {
        self.init(
            modelID: value.modelID,
            language: value.language,
            sourceAudioFingerprint: value.sourceAudioFingerprint,
            transcriptHash: value.transcriptHash,
            hasTranscript: value.hasTranscript,
            xVectorOnlyMode: value.xVectorOnlyMode,
            runtimeProfileSignature: value.qwen3RuntimeProfileSignature,
            createdAt: value.createdAt
        )
    }
}

/// Opaque clone conditioning. Tensor layout and the legacy artifact reader are
/// kept inside the owned package so product targets never depend on them.
public struct VocelloQwen3ClonePrompt: @unchecked Sendable {
    fileprivate let compatibilityValue: Qwen3TTSVoiceClonePrompt

    public var referenceText: String? { compatibilityValue.refText }
    public var xVectorOnlyMode: Bool { compatibilityValue.xVectorOnlyMode }
    public var inContextLearningMode: Bool { compatibilityValue.iclMode }
    public var artifactMetadata: VocelloQwen3CloneArtifactMetadata? {
        compatibilityValue.artifactMetadata.map(VocelloQwen3CloneArtifactMetadata.init)
    }

    fileprivate init(_ value: Qwen3TTSVoiceClonePrompt) {
        compatibilityValue = value
    }

    public func withArtifactMetadata(
        _ metadata: VocelloQwen3CloneArtifactMetadata?
    ) -> Self {
        Self(compatibilityValue.withArtifactMetadata(metadata?.compatibilityValue))
    }

    public func writeAtomically(to directory: URL) throws {
        try compatibilityValue.writeAtomically(to: directory)
    }

    public static func load(
        from directory: URL,
        expectedMetadata: VocelloQwen3CloneArtifactMetadata? = nil
    ) throws -> Self {
        Self(try Qwen3TTSVoiceClonePrompt.load(
            from: directory,
            expectedMetadata: expectedMetadata?.compatibilityValue
        ))
    }
}

public struct VocelloQwen3CompatibilityDiagnostics: Sendable {
    public let timingsMilliseconds: [String: Int]
    public let booleanFlags: [String: Bool]
    public let stringFlags: [String: String]

    public init(
        timingsMilliseconds: [String: Int] = [:],
        booleanFlags: [String: Bool] = [:],
        stringFlags: [String: String] = [:]
    ) {
        self.timingsMilliseconds = timingsMilliseconds
        self.booleanFlags = booleanFlags
        self.stringFlags = stringFlags
    }
}

/// Opaque, single-owner loaded model. All upstream-shaped protocols and MLX
/// tensors remain private to this package target.
public final class VocelloQwen3LoadedModel: @unchecked Sendable {
    private final class ModelBox: @unchecked Sendable {
        let base: any SpeechGenerationModel
        let optimized: any Qwen3OptimizedSpeechGenerationModel

        init(_ base: any SpeechGenerationModel) throws {
            guard let optimized = base as? any Qwen3OptimizedSpeechGenerationModel else {
                throw VocelloQwen3ContractError.incompatibleLoadedModel
            }
            self.base = base
            self.optimized = optimized
        }
    }

    private let box: ModelBox
    public let identity: VocelloQwen3ModelIdentity
    public let capabilities: VocelloQwen3CapabilitySet

    init(
        compatibilityModel: any SpeechGenerationModel,
        identity: VocelloQwen3ModelIdentity,
        capabilities: VocelloQwen3CapabilitySet
    ) throws {
        box = try ModelBox(compatibilityModel)
        self.identity = identity
        self.capabilities = capabilities
    }

    public var sampleRate: Int { box.base.sampleRate }

    public var loadDiagnostics: VocelloQwen3CompatibilityDiagnostics {
        let provider = box.base as? any SpeechGenerationModelDiagnosticsProvider
        return VocelloQwen3CompatibilityDiagnostics(
            timingsMilliseconds: provider?.loadTimingsMS ?? [:],
            booleanFlags: provider?.loadBooleanFlags ?? [:]
        )
    }

    public var latestPreparationDiagnostics: VocelloQwen3CompatibilityDiagnostics {
        let provider = box.base as? any SpeechGenerationModelDiagnosticsProvider
        return VocelloQwen3CompatibilityDiagnostics(
            timingsMilliseconds: provider?.latestPreparationTimingsMS ?? [:],
            booleanFlags: provider?.latestPreparationBooleanFlags ?? [:],
            stringFlags: provider?.latestPreparationStringFlags ?? [:]
        )
    }

    public func resetPreparationDiagnostics() {
        (box.base as? any SpeechGenerationModelDiagnosticsProvider)?.resetPreparationDiagnostics()
    }

    private func parameters(_ policy: VocelloQwen3SamplingConfiguration) throws -> GenerateParameters {
        let policy = try policy.validatedForCompatibilityAdapter()
        var parameters = box.base.defaultGenerationParameters
        parameters.maxTokens = policy.maxNewTokens
        parameters.temperature = policy.temperature
        parameters.topP = policy.topP
        parameters.repetitionPenalty = policy.repetitionPenalty
        return parameters
    }

    func streamFinishReason(maximumTokens: Int, observedTokens: Int) -> VocelloQwen3FinishReason {
        let provider = box.base as? any SpeechGenerationModelDiagnosticsProvider
        switch provider?.latestPreparationStringFlags["generation_end_reason"] {
        case "token_cap", "max_tokens":
            return .maximumTokens
        case "eos":
            return .endOfSequence
        default:
            // Compatibility implementations predating the typed diagnostic
            // still get a deterministic result without falsely calling an
            // observed token cap end-of-sequence.
            return observedTokens >= maximumTokens ? .maximumTokens : .endOfSequence
        }
    }

    public func prewarmCustomVoice(
        text: String,
        language: String,
        speaker: String,
        instruction: String?,
        sampling: VocelloQwen3SamplingConfiguration,
        depth: String?
    ) async throws {
        let parameters = try parameters(sampling)
        if let configurable = box.optimized as? any Qwen3CustomVoicePrewarmDepthControlling {
            try await configurable.prepareCustomVoice(
                text: text,
                language: language,
                speaker: speaker,
                instruct: instruction,
                generationParameters: parameters,
                customPrewarmDepth: depth
            )
        } else {
            try await box.optimized.prepareCustomVoice(
                text: text,
                language: language,
                speaker: speaker,
                instruct: instruction,
                generationParameters: parameters
            )
        }
    }

    public func customVoiceStream(
        text: String,
        language: String,
        speaker: String,
        instruction: String?,
        sampling: VocelloQwen3SamplingConfiguration,
        streamingInterval: Double,
        enableChunkTimings: Bool
    ) throws -> AsyncThrowingStream<VocelloQwen3GenerationSignal, Error> {
        map(box.optimized.generateCustomVoiceStream(
            text: text,
            language: language,
            speaker: speaker,
            instruct: instruction,
            generationParameters: try parameters(sampling),
            streamingInterval: streamingInterval,
            customVoiceProfile: nil,
            streamStepEvalPolicy: nil,
            generationSpeedProfile: nil,
            memoryClearCadence: nil,
            enableChunkTimings: enableChunkTimings
        ))
    }

    public func generateCustomVoice(
        text: String,
        language: String,
        speaker: String,
        instruction: String?,
        sampling: VocelloQwen3SamplingConfiguration
    ) async throws -> VocelloQwen3GenerationCompletion {
        VocelloQwen3GenerationCompletion(try await box.optimized.generateCustomVoice(
            text: text,
            language: language,
            speaker: speaker,
            instruct: instruction,
            generationParameters: try parameters(sampling)
        ))
    }

    public func prewarmVoiceDesign(
        text: String,
        language: String,
        description: String,
        sampling: VocelloQwen3SamplingConfiguration
    ) async throws {
        try await box.optimized.prepareVoiceDesign(
            text: text,
            language: language,
            voiceDescription: description,
            generationParameters: try parameters(sampling)
        )
    }

    public func voiceDesignStream(
        text: String,
        language: String,
        description: String,
        sampling: VocelloQwen3SamplingConfiguration,
        streamingInterval: Double,
        enableChunkTimings: Bool
    ) throws -> AsyncThrowingStream<VocelloQwen3GenerationSignal, Error> {
        map(box.optimized.generateVoiceDesignStream(
            text: text,
            language: language,
            voiceDescription: description,
            generationParameters: try parameters(sampling),
            streamingInterval: streamingInterval,
            streamStepEvalPolicy: nil,
            generationSpeedProfile: nil,
            memoryClearCadence: nil,
            enableChunkTimings: enableChunkTimings
        ))
    }

    public func generateVoiceDesign(
        text: String,
        language: String,
        description: String,
        sampling: VocelloQwen3SamplingConfiguration
    ) async throws -> VocelloQwen3GenerationCompletion {
        VocelloQwen3GenerationCompletion(try await box.optimized.generateVoiceDesign(
            text: text,
            language: language,
            voiceDescription: description,
            generationParameters: try parameters(sampling)
        ))
    }

    public func makeClonePrompt(
        referenceSamples: [Float],
        referenceText: String?,
        xVectorOnlyMode: Bool
    ) throws -> VocelloQwen3ClonePrompt {
        VocelloQwen3ClonePrompt(try box.optimized.createVoiceClonePrompt(
            refAudio: MLXArray(referenceSamples),
            refText: referenceText,
            xVectorOnlyMode: xVectorOnlyMode
        ))
    }

    public func prewarmVoiceClone(
        text: String,
        language: String,
        prompt: VocelloQwen3ClonePrompt,
        sampling: VocelloQwen3SamplingConfiguration
    ) async throws {
        try await box.optimized.prepareVoiceClone(
            text: text,
            language: language,
            voiceClonePrompt: prompt.compatibilityValue,
            generationParameters: try parameters(sampling)
        )
    }

    public func voiceCloneStream(
        text: String,
        language: String,
        prompt: VocelloQwen3ClonePrompt,
        sampling: VocelloQwen3SamplingConfiguration,
        streamingInterval: Double,
        enableChunkTimings: Bool
    ) throws -> AsyncThrowingStream<VocelloQwen3GenerationSignal, Error> {
        map(box.optimized.generateVoiceCloneStream(
            text: text,
            language: language,
            voiceClonePrompt: prompt.compatibilityValue,
            generationParameters: try parameters(sampling),
            streamingInterval: streamingInterval,
            streamStepEvalPolicy: nil,
            generationSpeedProfile: nil,
            memoryClearCadence: nil,
            enableChunkTimings: enableChunkTimings
        ))
    }

    public func generateVoiceClone(
        text: String,
        language: String,
        prompt: VocelloQwen3ClonePrompt,
        sampling: VocelloQwen3SamplingConfiguration
    ) async throws -> VocelloQwen3GenerationCompletion {
        VocelloQwen3GenerationCompletion(try await box.optimized.generateVoiceClone(
            text: text,
            language: language,
            voiceClonePrompt: prompt.compatibilityValue,
            generationParameters: try parameters(sampling)
        ))
    }

    private func map(
        _ source: AsyncThrowingStream<AudioGeneration, Error>
    ) -> AsyncThrowingStream<VocelloQwen3GenerationSignal, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in source {
                        try Task.checkCancellation()
                        switch event {
                        case .token(let token): continuation.yield(.token(token))
                        case .info(let info): continuation.yield(.info(VocelloQwen3GenerationInfo(info)))
                        case .audio(let audio): continuation.yield(.audio(audio.asArray(Float.self)))
                        case .chunkTimings(let timings):
                            continuation.yield(.chunkTimings(VocelloQwen3ChunkTimings(timings)))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
