import Foundation
@preconcurrency import MLX
@preconcurrency import MLXAudioCore
@preconcurrency import MLXAudioTTS

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
            try await box.base.prepareForGeneration(
                text: text,
                voice: voice,
                refAudio: refAudio,
                refText: refText,
                language: nil,
                generationParameters: box.base.defaultGenerationParameters
            )
        }
        self.streamHandler = { text, voice, refAudio, refText, streamingInterval in
            box.base.generateStream(
                text: text,
                voice: voice,
                refAudio: refAudio,
                refText: refText,
                language: nil,
                generationParameters: box.base.defaultGenerationParameters,
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
                try await optimizedBox.base.prepareCustomVoice(
                    text: text,
                    language: language,
                    speaker: speaker,
                    instruct: instruct,
                    generationParameters: box.base.defaultGenerationParameters
                )
            }
            self.customStreamHandler = { text, language, speaker, instruct, streamingInterval in
                optimizedBox.base.generateCustomVoiceStream(
                    text: text,
                    language: language,
                    speaker: speaker,
                    instruct: instruct,
                    generationParameters: box.base.defaultGenerationParameters,
                    streamingInterval: streamingInterval
                )
            }
            self.designPrewarmHandler = { text, language, voiceDescription in
                try await optimizedBox.base.prepareVoiceDesign(
                    text: text,
                    language: language,
                    voiceDescription: voiceDescription,
                    generationParameters: box.base.defaultGenerationParameters
                )
            }
            self.designStreamHandler = { text, language, voiceDescription, streamingInterval in
                optimizedBox.base.generateVoiceDesignStream(
                    text: text,
                    language: language,
                    voiceDescription: voiceDescription,
                    generationParameters: box.base.defaultGenerationParameters,
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
                try await optimizedBox.base.prepareVoiceClone(
                    text: text,
                    language: language,
                    voiceClonePrompt: voiceClonePrompt,
                    generationParameters: box.base.defaultGenerationParameters
                )
            }
            self.cloneStreamHandler = { text, language, voiceClonePrompt, streamingInterval in
                optimizedBox.base.generateVoiceCloneStream(
                    text: text,
                    language: language,
                    voiceClonePrompt: voiceClonePrompt,
                    generationParameters: box.base.defaultGenerationParameters,
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

    init(
        sampleRate: Int = 24_000,
        prewarmHandler: @escaping @Sendable (String, String?) async throws -> Void = { _, _ in },
        streamHandler: @escaping @Sendable (String, String?, Double) -> AsyncThrowingStream<AudioGeneration, Error> = { _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: MLXTTSEngineError.generationFailed(
                        "No test stream configured for UnsafeSpeechGenerationModel."
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
            try await prewarm(text: text, voice: Self.fallbackCustomVoice(speaker: speaker, instruct: instruct))
            return
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
        return generateStream(
            text: text,
            voice: Self.fallbackCustomVoice(speaker: speaker, instruct: instruct),
            streamingInterval: streamingInterval
        )
    }

    func prewarmVoiceDesign(
        text: String,
        language: String,
        voiceDescription: String
    ) async throws {
        guard let designPrewarmHandler else {
            try await prewarm(text: text, voice: voiceDescription)
            return
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
        return generateStream(
            text: text,
            voice: voiceDescription,
            streamingInterval: streamingInterval
        )
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

    private static func fallbackCustomVoice(speaker: String, instruct: String?) -> String {
        let trimmedSpeaker = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstruction = instruct?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedInstruction.isEmpty else {
            return trimmedSpeaker
        }
        return "\(trimmedSpeaker), \(trimmedInstruction)"
    }
}
