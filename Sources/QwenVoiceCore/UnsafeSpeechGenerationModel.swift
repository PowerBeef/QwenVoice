import Foundation
@preconcurrency import QwenVoiceBackendCore
@_spi(VocelloQwen3LegacyCompatibility) @preconcurrency import VocelloQwen3Core

/// Host-boundary resolver for immutable request-local sampling policy.
/// Environment values are read only through `RuntimeDebugGate`; the resulting
/// value crosses the package boundary once and no process-global request state
/// remains in the runtime.
enum Qwen3TalkerSamplingOverride {
    static let envTemperature: Float? = floatValue("QWENVOICE_TALKER_TEMP")
    static let envTopP: Float? = floatValue("QWENVOICE_TALKER_TOPP")
    static let envTopK: Int? = intValue("QWENVOICE_TALKER_TOPK")
    static let envMinP: Float? = nonnegativeFloatValue("QWENVOICE_TALKER_MINP")
    static let envSubtalkerTemperature: Float? = floatValue("QWENVOICE_SUBTALKER_TEMP")
    static let envSubtalkerTopP: Float? = floatValue("QWENVOICE_SUBTALKER_TOPP")
    static let envSubtalkerTopK: Int? = intValue("QWENVOICE_SUBTALKER_TOPK")

    private static func floatValue(_ key: String) -> Float? {
        guard let raw = RuntimeDebugGate.value(for: key),
              let value = Float(raw), value > 0 else { return nil }
        return value
    }

    private static func nonnegativeFloatValue(_ key: String) -> Float? {
        guard let raw = RuntimeDebugGate.value(for: key),
              let value = Float(raw), value >= 0 else { return nil }
        return value
    }

    private static func intValue(_ key: String) -> Int? {
        guard let raw = RuntimeDebugGate.value(for: key),
              let value = Int(raw), value > 0 else { return nil }
        return value
    }

    static func samplingConfiguration(
        requestedSeed: UInt64?,
        variation: Qwen3SamplingVariation?
    ) -> VocelloQwen3SamplingConfiguration {
        let official = Qwen3GenerationConfiguration.officialQualityDefault
        var temperature = official.temperature
        var topP = official.topP
        switch variation {
        case .balanced:
            temperature = 0.8
            topP = 0.95
        case .consistent:
            temperature = 0.7
            topP = 0.9
        case .expressive, nil:
            break
        }
        if let envTemperature { temperature = envTemperature }
        if let envTopP { topP = envTopP }
        let talker = VocelloQwen3SamplingStage(
            temperature: temperature,
            topP: topP,
            topK: envTopK ?? official.topK,
            minP: envMinP ?? 0
        )
        let subtalker = VocelloQwen3SamplingStage(
            temperature: envSubtalkerTemperature ?? talker.temperature,
            topP: envSubtalkerTopP ?? talker.topP,
            topK: envSubtalkerTopK ?? talker.topK,
            minP: talker.minP
        )
        let effectiveSeed = requestedSeed ?? UInt64.random(in: UInt64.min ... UInt64.max)
        return VocelloQwen3SamplingConfiguration(
            algorithmVersion: VocelloQwen3SamplingConfiguration.currentAlgorithmVersion,
            effectiveSeed: effectiveSeed,
            talker: talker,
            subtalker: subtalker,
            repetitionPenalty: official.repetitionPenalty,
            maxNewTokens: official.maxNewTokens,
            requestedSeed: requestedSeed
        )
    }
}

/// Product-side single-owner guard around the opaque first-party loaded model.
/// The unchecked annotation is registered in `config/concurrency-safety.json`;
/// no raw MLXAudio protocol or model instance crosses this boundary.
final class UnsafeSpeechGenerationModel: @unchecked Sendable {
    private let model: VocelloQwen3LoadedModel
    private let requestSampling: VocelloQwen3SamplingConfiguration?
    private let requestMemory: VocelloQwen3MemoryConfiguration?

    init(
        model: VocelloQwen3LoadedModel,
        requestSampling: VocelloQwen3SamplingConfiguration? = nil,
        requestMemory: VocelloQwen3MemoryConfiguration? = nil
    ) {
        self.model = model
        self.requestSampling = requestSampling
        self.requestMemory = requestMemory
    }

    static func qwen3Optimized(model: VocelloQwen3LoadedModel) -> UnsafeSpeechGenerationModel {
        UnsafeSpeechGenerationModel(model: model)
    }

    func bound(
        to sampling: VocelloQwen3SamplingConfiguration,
        memory: VocelloQwen3MemoryConfiguration
    ) -> UnsafeSpeechGenerationModel {
        UnsafeSpeechGenerationModel(
            model: model,
            requestSampling: sampling,
            requestMemory: memory
        )
    }

    var samplingConfiguration: VocelloQwen3SamplingConfiguration {
        requestSampling ?? Qwen3TalkerSamplingOverride.samplingConfiguration(
            requestedSeed: nil,
            variation: nil
        )
    }

    var memoryConfiguration: VocelloQwen3MemoryConfiguration {
        requestMemory ?? .compatibilityDefault
    }

    var sampleRate: Int { model.sampleRate }
    var loadDiagnosticsTimingsMS: [String: Int] { model.loadDiagnostics.timingsMilliseconds }
    var loadDiagnosticBooleanFlags: [String: Bool] { model.loadDiagnostics.booleanFlags }
    var latestPreparationTimingsMS: [String: Int] {
        model.latestPreparationDiagnostics.timingsMilliseconds
    }
    var latestPreparationBooleanFlags: [String: Bool] {
        model.latestPreparationDiagnostics.booleanFlags
    }
    var latestPreparationStringFlags: [String: String] {
        model.latestPreparationDiagnostics.stringFlags
    }

    func resetPreparationDiagnostics() { model.resetPreparationDiagnostics() }

    var supportsDedicatedCustomVoice: Bool { model.capabilities.contains(.customVoice) }
    var supportsOptimizedCustomVoice: Bool { model.capabilities.contains(.customVoice) }
    var supportsOptimizedVoiceDesign: Bool { model.capabilities.contains(.voiceDesign) }
    var supportsOptimizedVoiceClone: Bool { model.capabilities.contains(.voiceClone) }

    func prewarmCustomVoice(
        text: String,
        language: String,
        speaker: String,
        instruct: String?,
        customPrewarmDepth: String? = nil
    ) async throws {
        try await model.prewarmCustomVoice(
            text: text,
            language: language,
            speaker: speaker,
            instruction: instruct,
            sampling: samplingConfiguration,
            memory: memoryConfiguration,
            depth: customPrewarmDepth
        )
    }

    func generateCustomVoiceStream(
        text: String,
        language: String,
        speaker: String,
        instruct: String?,
        streamingInterval: Double
    ) -> AsyncThrowingStream<VocelloQwen3GenerationSignal, Error> {
        do {
            return try model.customVoiceStream(
                text: text,
                language: language,
                speaker: speaker,
                instruction: instruct,
                sampling: samplingConfiguration,
                memory: memoryConfiguration,
                streamingInterval: streamingInterval,
                enableChunkTimings: TelemetryGate.resolvedEnabled
            )
        } catch {
            return failedStream(error)
        }
    }

    func generateCustomVoice(
        text: String,
        language: String,
        speaker: String,
        instruct: String?
    ) async throws -> VocelloQwen3GenerationCompletion {
        try await model.generateCustomVoice(
            text: text,
            language: language,
            speaker: speaker,
            instruction: instruct,
            sampling: samplingConfiguration,
            memory: memoryConfiguration
        )
    }

    func prewarmVoiceDesign(
        text: String,
        language: String,
        voiceDescription: String
    ) async throws {
        try await model.prewarmVoiceDesign(
            text: text,
            language: language,
            description: voiceDescription,
            sampling: samplingConfiguration,
            memory: memoryConfiguration
        )
    }

    func generateVoiceDesignStream(
        text: String,
        language: String,
        voiceDescription: String,
        streamingInterval: Double
    ) -> AsyncThrowingStream<VocelloQwen3GenerationSignal, Error> {
        do {
            return try model.voiceDesignStream(
                text: text,
                language: language,
                description: voiceDescription,
                sampling: samplingConfiguration,
                memory: memoryConfiguration,
                streamingInterval: streamingInterval,
                enableChunkTimings: TelemetryGate.resolvedEnabled
            )
        } catch {
            return failedStream(error)
        }
    }

    func generateVoiceDesign(
        text: String,
        language: String,
        voiceDescription: String
    ) async throws -> VocelloQwen3GenerationCompletion {
        try await model.generateVoiceDesign(
            text: text,
            language: language,
            description: voiceDescription,
            sampling: samplingConfiguration,
            memory: memoryConfiguration
        )
    }

    func createVoiceClonePrompt(
        refAudio: [Float],
        refText: String?,
        xVectorOnlyMode: Bool
    ) throws -> VocelloQwen3ClonePrompt? {
        try model.makeClonePrompt(
            referenceSamples: refAudio,
            referenceText: refText,
            xVectorOnlyMode: xVectorOnlyMode
        )
    }

    func prewarmVoiceClone(
        text: String,
        language: String,
        voiceClonePrompt: VocelloQwen3ClonePrompt
    ) async throws {
        try await model.prewarmVoiceClone(
            text: text,
            language: language,
            prompt: voiceClonePrompt,
            sampling: samplingConfiguration,
            memory: memoryConfiguration
        )
    }

    func generateVoiceCloneStream(
        text: String,
        language: String,
        voiceClonePrompt: VocelloQwen3ClonePrompt,
        streamingInterval: Double
    ) -> AsyncThrowingStream<VocelloQwen3GenerationSignal, Error> {
        do {
            return try model.voiceCloneStream(
                text: text,
                language: language,
                prompt: voiceClonePrompt,
                sampling: samplingConfiguration,
                memory: memoryConfiguration,
                streamingInterval: streamingInterval,
                enableChunkTimings: TelemetryGate.resolvedEnabled
            )
        } catch {
            return failedStream(error)
        }
    }

    func generateVoiceClone(
        text: String,
        language: String,
        voiceClonePrompt: VocelloQwen3ClonePrompt
    ) async throws -> VocelloQwen3GenerationCompletion {
        try await model.generateVoiceClone(
            text: text,
            language: language,
            prompt: voiceClonePrompt,
            sampling: samplingConfiguration,
            memory: memoryConfiguration
        )
    }

    private func failedStream(
        _ error: Error
    ) -> AsyncThrowingStream<VocelloQwen3GenerationSignal, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
}
