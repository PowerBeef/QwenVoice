import Foundation
@preconcurrency import MLX
@preconcurrency import MLXAudioCore
@preconcurrency import MLXAudioTTS
@preconcurrency import MLXLMCommon

enum Qwen3BenchmarkGenerationParameterOverrides {
    static func resolve(
        defaultParameters: GenerateParameters,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GenerateParameters {
        guard environment["QWENVOICE_AUDIO_QC_LIVE"] == "1" else {
            return defaultParameters
        }

        let maxTokens = int(environment["QWENVOICE_QWEN3_BENCHMARK_MAX_TOKENS"])
            ?? defaultParameters.maxTokens
        let temperature = float(environment["QWENVOICE_QWEN3_BENCHMARK_TEMPERATURE"])
            ?? defaultParameters.temperature
        let topP = float(environment["QWENVOICE_QWEN3_BENCHMARK_TOP_P"])
            ?? defaultParameters.topP
        let repetitionPenalty = float(environment["QWENVOICE_QWEN3_BENCHMARK_REPETITION_PENALTY"])
            ?? defaultParameters.repetitionPenalty

        guard maxTokens != defaultParameters.maxTokens
            || temperature != defaultParameters.temperature
            || topP != defaultParameters.topP
            || repetitionPenalty != defaultParameters.repetitionPenalty else {
            return defaultParameters
        }

        var parameters = defaultParameters
        parameters.maxTokens = maxTokens
        parameters.temperature = temperature
        parameters.topP = topP
        parameters.repetitionPenalty = repetitionPenalty
        return parameters
    }

    private static func int(_ value: String?) -> Int? {
        guard let value else { return nil }
        return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func float(_ value: String?) -> Float? {
        guard let value else { return nil }
        return Float(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum Qwen3CustomVoiceGenerationParameterPolicy {
    static let temperature: Float = 0.7
    static let topP: Float = 0.9

    static func productParameters(defaultParameters: GenerateParameters) -> GenerateParameters {
        var parameters = defaultParameters
        parameters.temperature = temperature
        parameters.topP = topP
        return parameters
    }

    static func resolve(
        defaultParameters: GenerateParameters,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GenerateParameters {
        Qwen3BenchmarkGenerationParameterOverrides.resolve(
            defaultParameters: productParameters(defaultParameters: defaultParameters),
            environment: environment
        )
    }
}

/// Thin wrapper around an `MLXAudioTTS.SpeechGenerationModel` that lets us
/// hand the model across actor boundaries inside the engine.
///
/// "Unsafe" here means the `@unchecked Sendable` suppression below — not raw
/// memory manipulation. The wrapped closures and the backing model instance
/// are single-owner by construction (the engine never shares them between
/// concurrent generations), so bypassing the strict-concurrency checker is
/// safe for the use sites inside this module. Do not extend this surface
/// without preserving the single-owner contract (Tier 6).
final class UnsafeSpeechGenerationModel: @unchecked Sendable {
    private let sampleRateProvider: @Sendable () -> Int
    private let prewarmHandler: @Sendable (String, String?, MLXArray?, String?) async throws -> Void
    private let streamHandler: @Sendable (String, String?, MLXArray?, String?, Double) -> AsyncThrowingStream<AudioGeneration, Error>
    private let loadDiagnosticsProvider: @Sendable () -> [String: Int]
    private let loadDiagnosticBooleanFlagsProvider: @Sendable () -> [String: Bool]
    private let latestPreparationDiagnosticsProvider: @Sendable () -> [String: Int]
    private let latestPreparationBooleanFlagsProvider: @Sendable () -> [String: Bool]
    private let resetPreparationDiagnosticsHandler: @Sendable () -> Void
    private let customPrewarmHandler: (@Sendable (String, String, String, String?) async throws -> Void)?
    private let customStreamHandler: (@Sendable (String, String, String, String?, Double) -> AsyncThrowingStream<AudioGeneration, Error>)?
    private let designPrewarmHandler: (@Sendable (String, String, String) async throws -> Void)?
    private let designStreamHandler: (@Sendable (String, String, String, Double) -> AsyncThrowingStream<AudioGeneration, Error>)?
    private let clonePromptCreator: (@Sendable (MLXArray, String?, Bool) throws -> Qwen3TTSVoiceClonePrompt)?
    private let clonePrewarmHandler: (@Sendable (String, String, Qwen3TTSVoiceClonePrompt) async throws -> Void)?
    private let cloneStreamHandler: (@Sendable (String, String, Qwen3TTSVoiceClonePrompt, Double) -> AsyncThrowingStream<AudioGeneration, Error>)?

    private final class BaseModelBox: @unchecked Sendable {
        let base: any SpeechGenerationModel

        init(base: any SpeechGenerationModel) {
            self.base = base
        }
    }

    private final class OptimizedModelBox: @unchecked Sendable {
        let base: any Qwen3OptimizedSpeechGenerationModel

        init(base: any Qwen3OptimizedSpeechGenerationModel) {
            self.base = base
        }
    }

    init(base: any SpeechGenerationModel) {
        let box = BaseModelBox(base: base)
        self.sampleRateProvider = { box.base.sampleRate }
        self.prewarmHandler = { text, voice, refAudio, refText in
            let parameters = Qwen3BenchmarkGenerationParameterOverrides.resolve(
                defaultParameters: box.base.defaultGenerationParameters
            )
            try await box.base.prepareForGeneration(
                text: text,
                voice: voice,
                refAudio: refAudio,
                refText: refText,
                language: nil,
                generationParameters: parameters
            )
        }
        self.streamHandler = { text, voice, refAudio, refText, streamingInterval in
            let parameters = Qwen3BenchmarkGenerationParameterOverrides.resolve(
                defaultParameters: box.base.defaultGenerationParameters
            )
            return box.base.generateStream(
                text: text,
                voice: voice,
                refAudio: refAudio,
                refText: refText,
                language: nil,
                generationParameters: parameters,
                streamingInterval: streamingInterval
            )
        }
        self.loadDiagnosticsProvider = {
            (box.base as? any SpeechGenerationModelDiagnosticsProvider)?.loadTimingsMS ?? [:]
        }
        self.loadDiagnosticBooleanFlagsProvider = {
            (box.base as? any SpeechGenerationModelDiagnosticsProvider)?.loadBooleanFlags ?? [:]
        }
        self.latestPreparationDiagnosticsProvider = {
            (box.base as? any SpeechGenerationModelDiagnosticsProvider)?.latestPreparationTimingsMS ?? [:]
        }
        self.latestPreparationBooleanFlagsProvider = {
            (box.base as? any SpeechGenerationModelDiagnosticsProvider)?.latestPreparationBooleanFlags ?? [:]
        }
        self.resetPreparationDiagnosticsHandler = {
            (box.base as? any SpeechGenerationModelDiagnosticsProvider)?.resetPreparationDiagnostics()
        }
        if let optimizedBase = base as? any Qwen3OptimizedSpeechGenerationModel {
            let optimizedBox = OptimizedModelBox(base: optimizedBase)
            self.customPrewarmHandler = { text, language, speaker, instruct in
                let parameters = Qwen3CustomVoiceGenerationParameterPolicy.resolve(
                    defaultParameters: box.base.defaultGenerationParameters
                )
                try await optimizedBox.base.prepareCustomVoice(
                    text: text,
                    language: language,
                    speaker: speaker,
                    instruct: instruct,
                    generationParameters: parameters
                )
            }
            self.customStreamHandler = { text, language, speaker, instruct, streamingInterval in
                let parameters = Qwen3CustomVoiceGenerationParameterPolicy.resolve(
                    defaultParameters: box.base.defaultGenerationParameters
                )
                return optimizedBox.base.generateCustomVoiceStream(
                    text: text,
                    language: language,
                    speaker: speaker,
                    instruct: instruct,
                    generationParameters: parameters,
                    streamingInterval: streamingInterval
                )
            }
            self.designPrewarmHandler = { text, language, voiceDescription in
                let parameters = Qwen3BenchmarkGenerationParameterOverrides.resolve(
                    defaultParameters: box.base.defaultGenerationParameters
                )
                try await optimizedBox.base.prepareVoiceDesign(
                    text: text,
                    language: language,
                    voiceDescription: voiceDescription,
                    generationParameters: parameters
                )
            }
            self.designStreamHandler = { text, language, voiceDescription, streamingInterval in
                let parameters = Qwen3BenchmarkGenerationParameterOverrides.resolve(
                    defaultParameters: box.base.defaultGenerationParameters
                )
                return optimizedBox.base.generateVoiceDesignStream(
                    text: text,
                    language: language,
                    voiceDescription: voiceDescription,
                    generationParameters: parameters,
                    streamingInterval: streamingInterval
                )
            }
            self.clonePromptCreator = { refAudio, refText, xVectorOnlyMode in
                try optimizedBox.base.createVoiceClonePrompt(
                    refAudio: refAudio,
                    refText: refText,
                    xVectorOnlyMode: xVectorOnlyMode
                )
            }
            self.clonePrewarmHandler = { text, language, voiceClonePrompt in
                let parameters = Qwen3BenchmarkGenerationParameterOverrides.resolve(
                    defaultParameters: box.base.defaultGenerationParameters
                )
                try await optimizedBox.base.prepareVoiceClone(
                    text: text,
                    language: language,
                    voiceClonePrompt: voiceClonePrompt,
                    generationParameters: parameters
                )
            }
            self.cloneStreamHandler = { text, language, voiceClonePrompt, streamingInterval in
                let parameters = Qwen3BenchmarkGenerationParameterOverrides.resolve(
                    defaultParameters: box.base.defaultGenerationParameters
                )
                return optimizedBox.base.generateVoiceCloneStream(
                    text: text,
                    language: language,
                    voiceClonePrompt: voiceClonePrompt,
                    generationParameters: parameters,
                    streamingInterval: streamingInterval
                )
            }
        } else {
            self.customPrewarmHandler = nil
            self.customStreamHandler = nil
            self.designPrewarmHandler = nil
            self.designStreamHandler = nil
            self.clonePromptCreator = nil
            self.clonePrewarmHandler = nil
            self.cloneStreamHandler = nil
        }
    }

    static func qwen3Optimized(base: any SpeechGenerationModel) throws -> UnsafeSpeechGenerationModel {
        guard base is any Qwen3OptimizedSpeechGenerationModel else {
            throw MLXTTSEngineError.unsupportedRequest(
                "QwenVoice's native backend supports only optimized Qwen3-TTS models."
            )
        }
        return UnsafeSpeechGenerationModel(base: base)
    }

    init(
        sampleRate: Int = 24_000,
        prewarmHandler: @escaping @Sendable (String, String?) async throws -> Void = { _, _ in },
        streamHandler: @escaping @Sendable (String, String?, Double) -> AsyncThrowingStream<AudioGeneration, Error> = { _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: MLXTTSEngineError.generationFailed(
                        "No stream configured for UnsafeSpeechGenerationModel."
                    )
                )
            }
        },
        latestPreparationDiagnosticsProvider: @escaping @Sendable () -> [String: Int] = { [:] },
        latestPreparationBooleanFlagsProvider: @escaping @Sendable () -> [String: Bool] = { [:] },
        customPrewarmHandler: (@Sendable (String, String, String, String?) async throws -> Void)? = nil,
        customStreamHandler: (@Sendable (String, String, String, String?, Double) -> AsyncThrowingStream<AudioGeneration, Error>)? = nil,
        designPrewarmHandler: (@Sendable (String, String, String) async throws -> Void)? = nil,
        designStreamHandler: (@Sendable (String, String, String, Double) -> AsyncThrowingStream<AudioGeneration, Error>)? = nil,
        clonePromptCreator: (@Sendable (MLXArray, String?, Bool) throws -> Qwen3TTSVoiceClonePrompt)? = nil,
        clonePrewarmHandler: (@Sendable (String, String, Qwen3TTSVoiceClonePrompt) async throws -> Void)? = nil,
        cloneStreamHandler: (@Sendable (String, String, Qwen3TTSVoiceClonePrompt, Double) -> AsyncThrowingStream<AudioGeneration, Error>)? = nil
    ) {
        self.sampleRateProvider = { sampleRate }
        self.prewarmHandler = { (text: String, voice: String?, _: MLXArray?, _: String?) async throws in
            try await prewarmHandler(text, voice)
        }
        self.streamHandler = { (text: String, voice: String?, _: MLXArray?, _: String?, streamingInterval: Double) in
            streamHandler(text, voice, streamingInterval)
        }
        self.loadDiagnosticsProvider = { [:] }
        self.loadDiagnosticBooleanFlagsProvider = { [:] }
        self.latestPreparationDiagnosticsProvider = latestPreparationDiagnosticsProvider
        self.latestPreparationBooleanFlagsProvider = latestPreparationBooleanFlagsProvider
        self.resetPreparationDiagnosticsHandler = {}
        self.customPrewarmHandler = customPrewarmHandler
        self.customStreamHandler = customStreamHandler
        self.designPrewarmHandler = designPrewarmHandler
        self.designStreamHandler = designStreamHandler
        self.clonePromptCreator = clonePromptCreator
        self.clonePrewarmHandler = clonePrewarmHandler
        self.cloneStreamHandler = cloneStreamHandler
    }

    init(
        sampleRate: Int = 24_000,
        fullPrewarmHandler: @escaping @Sendable (String, String?, MLXArray?, String?) async throws -> Void,
        fullStreamHandler: @escaping @Sendable (String, String?, MLXArray?, String?, Double) -> AsyncThrowingStream<AudioGeneration, Error>,
        latestPreparationDiagnosticsProvider: @escaping @Sendable () -> [String: Int] = { [:] },
        latestPreparationBooleanFlagsProvider: @escaping @Sendable () -> [String: Bool] = { [:] },
        customPrewarmHandler: (@Sendable (String, String, String, String?) async throws -> Void)? = nil,
        customStreamHandler: (@Sendable (String, String, String, String?, Double) -> AsyncThrowingStream<AudioGeneration, Error>)? = nil,
        designPrewarmHandler: (@Sendable (String, String, String) async throws -> Void)? = nil,
        designStreamHandler: (@Sendable (String, String, String, Double) -> AsyncThrowingStream<AudioGeneration, Error>)? = nil,
        clonePromptCreator: (@Sendable (MLXArray, String?, Bool) throws -> Qwen3TTSVoiceClonePrompt)? = nil,
        clonePrewarmHandler: (@Sendable (String, String, Qwen3TTSVoiceClonePrompt) async throws -> Void)? = nil,
        cloneStreamHandler: (@Sendable (String, String, Qwen3TTSVoiceClonePrompt, Double) -> AsyncThrowingStream<AudioGeneration, Error>)? = nil
    ) {
        self.sampleRateProvider = { sampleRate }
        self.prewarmHandler = fullPrewarmHandler
        self.streamHandler = fullStreamHandler
        self.loadDiagnosticsProvider = { [:] }
        self.loadDiagnosticBooleanFlagsProvider = { [:] }
        self.latestPreparationDiagnosticsProvider = latestPreparationDiagnosticsProvider
        self.latestPreparationBooleanFlagsProvider = latestPreparationBooleanFlagsProvider
        self.resetPreparationDiagnosticsHandler = {}
        self.customPrewarmHandler = customPrewarmHandler
        self.customStreamHandler = customStreamHandler
        self.designPrewarmHandler = designPrewarmHandler
        self.designStreamHandler = designStreamHandler
        self.clonePromptCreator = clonePromptCreator
        self.clonePrewarmHandler = clonePrewarmHandler
        self.cloneStreamHandler = cloneStreamHandler
    }

    var sampleRate: Int {
        sampleRateProvider()
    }

    var loadDiagnosticsTimingsMS: [String: Int] {
        loadDiagnosticsProvider()
    }

    var loadDiagnosticBooleanFlags: [String: Bool] {
        loadDiagnosticBooleanFlagsProvider()
    }

    var latestPreparationTimingsMS: [String: Int] {
        latestPreparationDiagnosticsProvider()
    }

    var latestPreparationBooleanFlags: [String: Bool] {
        latestPreparationBooleanFlagsProvider()
    }

    func resetPreparationDiagnostics() {
        resetPreparationDiagnosticsHandler()
    }

    var supportsDedicatedCustomVoice: Bool {
        customPrewarmHandler != nil && customStreamHandler != nil
    }

    var supportsOptimizedCustomVoice: Bool {
        supportsDedicatedCustomVoice
    }

    var supportsOptimizedVoiceDesign: Bool {
        designPrewarmHandler != nil && designStreamHandler != nil
    }

    var supportsOptimizedVoiceClone: Bool {
        clonePromptCreator != nil && clonePrewarmHandler != nil && cloneStreamHandler != nil
    }

    func prewarm(text: String, voice: String?) async throws {
        try await prewarmHandler(text, voice, nil, nil)
    }

    func prewarm(
        text: String,
        voice: String?,
        refAudio: MLXArray?,
        refText: String?
    ) async throws {
        try await prewarmHandler(text, voice, refAudio, refText)
    }

    func generateStream(
        text: String,
        voice: String?,
        streamingInterval: Double
    ) -> AsyncThrowingStream<AudioGeneration, Error> {
        streamHandler(text, voice, nil, nil, streamingInterval)
    }

    func generateStream(
        text: String,
        voice: String?,
        refAudio: MLXArray?,
        refText: String?,
        streamingInterval: Double
    ) -> AsyncThrowingStream<AudioGeneration, Error> {
        streamHandler(text, voice, refAudio, refText, streamingInterval)
    }

    func prewarmCustomVoice(
        text: String,
        language: String,
        speaker: String,
        instruct: String?
    ) async throws {
        guard let customPrewarmHandler else {
            throw MLXTTSEngineError.unsupportedRequest(
                "The active native model does not support optimized Qwen3 Custom Voice generation."
            )
        }
        try await customPrewarmHandler(text, language, speaker, instruct)
    }

    func generateCustomVoiceStream(
        text: String,
        language: String,
        speaker: String,
        instruct: String?,
        streamingInterval: Double
    ) -> AsyncThrowingStream<AudioGeneration, Error> {
        if let customStreamHandler {
            return customStreamHandler(text, language, speaker, instruct, streamingInterval)
        }
        return AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: MLXTTSEngineError.unsupportedRequest(
                    "The active native model does not support optimized Qwen3 Custom Voice generation."
                )
            )
        }
    }

    func prewarmVoiceDesign(
        text: String,
        language: String,
        voiceDescription: String
    ) async throws {
        guard let designPrewarmHandler else {
            throw MLXTTSEngineError.unsupportedRequest(
                "The active native model does not support optimized Qwen3 Voice Design generation."
            )
        }
        try await designPrewarmHandler(text, language, voiceDescription)
    }

    func generateVoiceDesignStream(
        text: String,
        language: String,
        voiceDescription: String,
        streamingInterval: Double
    ) -> AsyncThrowingStream<AudioGeneration, Error> {
        if let designStreamHandler {
            return designStreamHandler(text, language, voiceDescription, streamingInterval)
        }
        return AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: MLXTTSEngineError.unsupportedRequest(
                    "The active native model does not support optimized Qwen3 Voice Design generation."
                )
            )
        }
    }

    func createVoiceClonePrompt(
        refAudio: MLXArray,
        refText: String?,
        xVectorOnlyMode: Bool
    ) throws -> Qwen3TTSVoiceClonePrompt? {
        try clonePromptCreator?(refAudio, refText, xVectorOnlyMode)
    }

    func prewarmVoiceClone(
        text: String,
        language: String,
        voiceClonePrompt: Qwen3TTSVoiceClonePrompt
    ) async throws {
        guard let clonePrewarmHandler else {
            throw MLXTTSEngineError.unsupportedRequest(
                "The active native model does not support optimized Qwen voice-clone prompts."
            )
        }
        try await clonePrewarmHandler(text, language, voiceClonePrompt)
    }

    func generateVoiceCloneStream(
        text: String,
        language: String,
        voiceClonePrompt: Qwen3TTSVoiceClonePrompt,
        streamingInterval: Double
    ) -> AsyncThrowingStream<AudioGeneration, Error> {
        if let cloneStreamHandler {
            return cloneStreamHandler(text, language, voiceClonePrompt, streamingInterval)
        }
        return AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: MLXTTSEngineError.unsupportedRequest(
                    "The active native model does not support optimized Qwen voice-clone prompts."
                )
            )
        }
    }

}
