import Foundation
@preconcurrency import MLX
@preconcurrency import MLXAudioCore
@preconcurrency import MLXAudioTTS
import QwenVoiceEngineSupport

struct NativeSpeechGenerationInfo: Sendable {
    let promptTokenCount: Int
    let generationTokenCount: Int
    let prefillTime: TimeInterval
    let generateTime: TimeInterval
    let peakMemoryUsage: Double

    init(
        promptTokenCount: Int,
        generationTokenCount: Int,
        prefillTime: TimeInterval,
        generateTime: TimeInterval,
        peakMemoryUsage: Double
    ) {
        self.promptTokenCount = promptTokenCount
        self.generationTokenCount = generationTokenCount
        self.prefillTime = prefillTime
        self.generateTime = generateTime
        self.peakMemoryUsage = peakMemoryUsage
    }

    init(_ upstream: AudioGenerationInfo) {
        self.init(
            promptTokenCount: upstream.promptTokenCount,
            generationTokenCount: upstream.generationTokenCount,
            prefillTime: upstream.prefillTime,
            generateTime: upstream.generateTime,
            peakMemoryUsage: upstream.peakMemoryUsage
        )
    }
}

enum NativeSpeechGenerationEvent: Sendable {
    case audio([Float])
    case info(NativeSpeechGenerationInfo)
}

final class NativeSpeechGenerationModel: @unchecked Sendable {
    private let sampleRateProvider: @Sendable () -> Int
    private let genericPrewarmHandler: @Sendable (String, String?, MLXArray?, String?, String?) async throws -> Void
    private let genericStreamHandler: @Sendable (String, String?, MLXArray?, String?, String?, Double) -> AsyncThrowingStream<NativeSpeechGenerationEvent, Error>
    private let latestPreparationDiagnosticsProvider: @Sendable () -> [String: Int]
    private let latestPreparationBooleanFlagsProvider: @Sendable () -> [String: Bool]
    private let resetPreparationDiagnosticsHandler: @Sendable () -> Void
    private let customPrewarmHandler: (@Sendable (String, String, String, String?) async throws -> Void)?
    private let customStreamHandler: (@Sendable (String, String, String, String?, Double) -> AsyncThrowingStream<NativeSpeechGenerationEvent, Error>)?
    private let designPrewarmHandler: (@Sendable (String, String, String) async throws -> Void)?
    private let designStreamHandler: (@Sendable (String, String, String, Double) -> AsyncThrowingStream<NativeSpeechGenerationEvent, Error>)?
    private let clonePromptCreator: (@Sendable (MLXArray, String?, Bool) throws -> Qwen3TTSVoiceClonePrompt)?
    private let clonePrewarmHandler: (@Sendable (String, String, Qwen3TTSVoiceClonePrompt) async throws -> Void)?
    private let cloneStreamHandler: (@Sendable (String, String, Qwen3TTSVoiceClonePrompt, Double) -> AsyncThrowingStream<NativeSpeechGenerationEvent, Error>)?

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
        let baseBox = BaseModelBox(base: base)
        self.sampleRateProvider = { baseBox.base.sampleRate }
        self.genericPrewarmHandler = { text, voice, refAudio, refText, language in
            try await baseBox.base.prepareForGeneration(
                text: text,
                voice: voice,
                refAudio: refAudio,
                refText: refText,
                language: language,
                generationParameters: baseBox.base.defaultGenerationParameters
            )
        }
        self.genericStreamHandler = { text, voice, refAudio, refText, language, streamingInterval in
            Self.map(
                stream: baseBox.base.generateStream(
                    text: text,
                    voice: voice,
                    refAudio: refAudio,
                    refText: refText,
                    language: language,
                    generationParameters: baseBox.base.defaultGenerationParameters,
                    streamingInterval: streamingInterval
                )
            )
        }
        self.latestPreparationDiagnosticsProvider = {
            (baseBox.base as? any SpeechGenerationModelDiagnosticsProvider)?.latestPreparationTimingsMS ?? [:]
        }
        self.latestPreparationBooleanFlagsProvider = {
            (baseBox.base as? any SpeechGenerationModelDiagnosticsProvider)?.latestPreparationBooleanFlags ?? [:]
        }
        self.resetPreparationDiagnosticsHandler = {
            (baseBox.base as? any SpeechGenerationModelDiagnosticsProvider)?.resetPreparationDiagnostics()
        }

        if let optimized = base as? any Qwen3OptimizedSpeechGenerationModel {
            let optimizedBox = OptimizedModelBox(base: optimized)
            self.customPrewarmHandler = { text, language, speaker, instruct in
                try await optimizedBox.base.prepareCustomVoice(
                    text: text,
                    language: language,
                    speaker: speaker,
                    instruct: instruct,
                    generationParameters: baseBox.base.defaultGenerationParameters
                )
            }
            self.customStreamHandler = { text, language, speaker, instruct, streamingInterval in
                Self.map(
                    stream: optimizedBox.base.generateCustomVoiceStream(
                        text: text,
                        language: language,
                        speaker: speaker,
                        instruct: instruct,
                        generationParameters: baseBox.base.defaultGenerationParameters,
                        streamingInterval: streamingInterval
                    )
                )
            }
            self.designPrewarmHandler = { text, language, voiceDescription in
                try await optimizedBox.base.prepareVoiceDesign(
                    text: text,
                    language: language,
                    voiceDescription: voiceDescription,
                    generationParameters: baseBox.base.defaultGenerationParameters
                )
            }
            self.designStreamHandler = { text, language, voiceDescription, streamingInterval in
                Self.map(
                    stream: optimizedBox.base.generateVoiceDesignStream(
                        text: text,
                        language: language,
                        voiceDescription: voiceDescription,
                        generationParameters: baseBox.base.defaultGenerationParameters,
                        streamingInterval: streamingInterval
                    )
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
                    generationParameters: baseBox.base.defaultGenerationParameters
                )
            }
            self.cloneStreamHandler = { text, language, voiceClonePrompt, streamingInterval in
                Self.map(
                    stream: optimizedBox.base.generateVoiceCloneStream(
                        text: text,
                        language: language,
                        voiceClonePrompt: voiceClonePrompt,
                        generationParameters: baseBox.base.defaultGenerationParameters,
                        streamingInterval: streamingInterval
                    )
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
        fullGenericPrewarmHandler: @escaping @Sendable (String, String?, MLXArray?, String?, String?) async throws -> Void = { _, _, _, _, _ in },
        fullGenericStreamHandler: @escaping @Sendable (String, String?, MLXArray?, String?, String?, Double) -> AsyncThrowingStream<NativeSpeechGenerationEvent, Error> = { _, _, _, _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.finish(throwing: NSError(domain: "QwenVoiceNative", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "No test stream configured for NativeSpeechGenerationModel."
                ]))
            }
        },
        latestPreparationDiagnosticsProvider: @escaping @Sendable () -> [String: Int] = { [:] },
        latestPreparationBooleanFlagsProvider: @escaping @Sendable () -> [String: Bool] = { [:] },
        customPrewarmHandler: (@Sendable (String, String, String, String?) async throws -> Void)? = nil,
        customStreamHandler: (@Sendable (String, String, String, String?, Double) -> AsyncThrowingStream<NativeSpeechGenerationEvent, Error>)? = nil,
        designPrewarmHandler: (@Sendable (String, String, String) async throws -> Void)? = nil,
        designStreamHandler: (@Sendable (String, String, String, Double) -> AsyncThrowingStream<NativeSpeechGenerationEvent, Error>)? = nil,
        clonePromptCreator: (@Sendable (MLXArray, String?, Bool) throws -> Qwen3TTSVoiceClonePrompt)? = nil,
        clonePrewarmHandler: (@Sendable (String, String, Qwen3TTSVoiceClonePrompt) async throws -> Void)? = nil,
        cloneStreamHandler: (@Sendable (String, String, Qwen3TTSVoiceClonePrompt, Double) -> AsyncThrowingStream<NativeSpeechGenerationEvent, Error>)? = nil
    ) {
        self.sampleRateProvider = { sampleRate }
        self.genericPrewarmHandler = fullGenericPrewarmHandler
        self.genericStreamHandler = fullGenericStreamHandler
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

    convenience init(
        sampleRate: Int = 24_000,
        genericPrewarmHandler: @escaping @Sendable (String, String?, String?) async throws -> Void = { _, _, _ in },
        genericStreamHandler: @escaping @Sendable (String, String?, String?, Double) -> AsyncThrowingStream<NativeSpeechGenerationEvent, Error> = { _, _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.finish(throwing: NSError(domain: "QwenVoiceNative", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "No test stream configured for NativeSpeechGenerationModel."
                ]))
            }
        },
        latestPreparationDiagnosticsProvider: @escaping @Sendable () -> [String: Int] = { [:] },
        latestPreparationBooleanFlagsProvider: @escaping @Sendable () -> [String: Bool] = { [:] },
        customPrewarmHandler: (@Sendable (String, String, String, String?) async throws -> Void)? = nil,
        customStreamHandler: (@Sendable (String, String, String, String?, Double) -> AsyncThrowingStream<NativeSpeechGenerationEvent, Error>)? = nil,
        designPrewarmHandler: (@Sendable (String, String, String) async throws -> Void)? = nil,
        designStreamHandler: (@Sendable (String, String, String, Double) -> AsyncThrowingStream<NativeSpeechGenerationEvent, Error>)? = nil
    ) {
        self.init(
            sampleRate: sampleRate,
            fullGenericPrewarmHandler: { text, voice, _, _, language in
                try await genericPrewarmHandler(text, voice, language)
            },
            fullGenericStreamHandler: { text, voice, _, _, language, streamingInterval in
                genericStreamHandler(text, voice, language, streamingInterval)
            },
            latestPreparationDiagnosticsProvider: latestPreparationDiagnosticsProvider,
            latestPreparationBooleanFlagsProvider: latestPreparationBooleanFlagsProvider,
            customPrewarmHandler: customPrewarmHandler,
            customStreamHandler: customStreamHandler,
            designPrewarmHandler: designPrewarmHandler,
            designStreamHandler: designStreamHandler
        )
    }

    static func placeholder() -> NativeSpeechGenerationModel {
        NativeSpeechGenerationModel()
    }

    var sampleRate: Int { sampleRateProvider() }
    var supportsDedicatedCustomVoice: Bool { customStreamHandler != nil }
    var supportsOptimizedVoiceDesign: Bool { designPrewarmHandler != nil && designStreamHandler != nil }
    var supportsOptimizedVoiceClone: Bool {
        clonePromptCreator != nil && clonePrewarmHandler != nil && cloneStreamHandler != nil
    }
    var latestPreparationTimingsMS: [String: Int] { latestPreparationDiagnosticsProvider() }
    var latestPreparationBooleanFlags: [String: Bool] { latestPreparationBooleanFlagsProvider() }

    func resetPreparationDiagnostics() {
        resetPreparationDiagnosticsHandler()
    }

    func prepareForGeneration(
        text: String,
        voice: String?,
        refAudio: MLXArray? = nil,
        refText: String? = nil,
        language: String?
    ) async throws {
        try await genericPrewarmHandler(text, voice, refAudio, refText, language)
    }

    func generateStream(
        text: String,
        voice: String?,
        refAudio: MLXArray? = nil,
        refText: String? = nil,
        language: String?,
        streamingInterval: Double
    ) -> AsyncThrowingStream<NativeSpeechGenerationEvent, Error> {
        genericStreamHandler(text, voice, refAudio, refText, language, streamingInterval)
    }

    func prepareCustomVoice(
        text: String,
        language: String,
        speaker: String,
        instruct: String?
    ) async throws {
        if let customPrewarmHandler {
            try await customPrewarmHandler(text, language, speaker, instruct)
            return
        }
        try await prepareForGeneration(
            text: text,
            voice: Self.fallbackCustomVoice(speaker: speaker, instruct: instruct),
            language: language
        )
    }

    func generateCustomVoiceStream(
        text: String,
        language: String,
        speaker: String,
        instruct: String?,
        streamingInterval: Double
    ) -> AsyncThrowingStream<NativeSpeechGenerationEvent, Error> {
        if let customStreamHandler {
            return customStreamHandler(text, language, speaker, instruct, streamingInterval)
        }
        return generateStream(
            text: text,
            voice: Self.fallbackCustomVoice(speaker: speaker, instruct: instruct),
            language: language,
            streamingInterval: streamingInterval
        )
    }

    func prepareVoiceDesign(
        text: String,
        language: String,
        voiceDescription: String
    ) async throws {
        if let designPrewarmHandler {
            try await designPrewarmHandler(text, language, voiceDescription)
            return
        }
        try await prepareForGeneration(text: text, voice: voiceDescription, language: language)
    }

    func generateVoiceDesignStream(
        text: String,
        language: String,
        voiceDescription: String,
        streamingInterval: Double
    ) -> AsyncThrowingStream<NativeSpeechGenerationEvent, Error> {
        if let designStreamHandler {
            return designStreamHandler(text, language, voiceDescription, streamingInterval)
        }
        return generateStream(
            text: text,
            voice: voiceDescription,
            language: language,
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

    func prepareVoiceClone(
        text: String,
        language: String,
        voiceClonePrompt: Qwen3TTSVoiceClonePrompt
    ) async throws {
        if let clonePrewarmHandler {
            try await clonePrewarmHandler(text, language, voiceClonePrompt)
            return
        }
        try await prepareForGeneration(text: text, voice: nil, language: language)
    }

    func generateVoiceCloneStream(
        text: String,
        language: String,
        voiceClonePrompt: Qwen3TTSVoiceClonePrompt,
        streamingInterval: Double
    ) -> AsyncThrowingStream<NativeSpeechGenerationEvent, Error> {
        if let cloneStreamHandler {
            return cloneStreamHandler(text, language, voiceClonePrompt, streamingInterval)
        }
        return generateStream(text: text, voice: nil, language: language, streamingInterval: streamingInterval)
    }

    private static func fallbackCustomVoice(speaker: String, instruct: String?) -> String {
        let trimmedInstruction = instruct?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedInstruction.isEmpty else {
            return speaker
        }
        return "\(speaker), \(trimmedInstruction)"
    }

    private static func map(
        stream: AsyncThrowingStream<AudioGeneration, Error>
    ) -> AsyncThrowingStream<NativeSpeechGenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in stream {
                        switch event {
                        case .token:
                            continue
                        case .info(let info):
                            continuation.yield(.info(NativeSpeechGenerationInfo(info)))
                        case .audio(let audio):
                            continuation.yield(.audio(audio.asArray(Float.self)))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
