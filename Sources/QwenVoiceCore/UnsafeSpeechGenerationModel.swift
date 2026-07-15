import Foundation
import os
@preconcurrency import QwenVoiceBackendCore
@preconcurrency import VocelloQwen3Core

/// Per-request and debug-only sampling overrides. The resolved value crosses
/// the package boundary as a Vocello-owned policy, never as MLXLM parameters.
enum Qwen3TalkerSamplingOverride {
    private static let variationLock = OSAllocatedUnfairLock<Qwen3SamplingVariation?>(initialState: nil)

    static var requestVariation: Qwen3SamplingVariation? {
        get { variationLock.withLock { $0 } }
        set { variationLock.withLock { $0 = newValue } }
    }

    static let envTemperature: Float? = floatValue("QWENVOICE_TALKER_TEMP")
    static let envTopP: Float? = floatValue("QWENVOICE_TALKER_TOPP")

    private static func floatValue(_ key: String) -> Float? {
        guard let raw = RuntimeDebugGate.value(for: key),
              let value = Float(raw), value > 0 else { return nil }
        return value
    }

    static func samplingConfiguration() -> VocelloQwen3SamplingConfiguration {
        let official = Qwen3GenerationConfiguration.officialQualityDefault
        var temperature = official.temperature
        var topP = official.topP
        switch requestVariation {
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
        return VocelloQwen3SamplingConfiguration(
            maxNewTokens: official.maxNewTokens,
            temperature: temperature,
            topP: topP,
            topK: official.topK,
            repetitionPenalty: official.repetitionPenalty
        )
    }
}

/// Product-side single-owner guard around the opaque first-party loaded model.
/// The unchecked annotation is registered in `config/concurrency-safety.json`;
/// no raw MLXAudio protocol or model instance crosses this boundary.
final class UnsafeSpeechGenerationModel: @unchecked Sendable {
    private let model: VocelloQwen3LoadedModel

    init(model: VocelloQwen3LoadedModel) {
        self.model = model
    }

    static func qwen3Optimized(model: VocelloQwen3LoadedModel) -> UnsafeSpeechGenerationModel {
        UnsafeSpeechGenerationModel(model: model)
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
            sampling: Qwen3TalkerSamplingOverride.samplingConfiguration(),
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
                sampling: Qwen3TalkerSamplingOverride.samplingConfiguration(),
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
            sampling: Qwen3TalkerSamplingOverride.samplingConfiguration()
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
            sampling: Qwen3TalkerSamplingOverride.samplingConfiguration()
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
                sampling: Qwen3TalkerSamplingOverride.samplingConfiguration(),
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
            sampling: Qwen3TalkerSamplingOverride.samplingConfiguration()
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
            sampling: Qwen3TalkerSamplingOverride.samplingConfiguration()
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
                sampling: Qwen3TalkerSamplingOverride.samplingConfiguration(),
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
            sampling: Qwen3TalkerSamplingOverride.samplingConfiguration()
        )
    }

    private func failedStream(
        _ error: Error
    ) -> AsyncThrowingStream<VocelloQwen3GenerationSignal, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
}
