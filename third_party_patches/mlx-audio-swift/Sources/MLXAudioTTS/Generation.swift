@preconcurrency import MLX
import MLXAudioCore
@preconcurrency import MLXLMCommon
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

public protocol SpeechGenerationModel: AnyObject {
    var sampleRate: Int { get }
    var defaultGenerationParameters: GenerateParameters { get }

    func prepareForGeneration(
        text: String,
        voice: String?,
        refAudio: MLXArray?,
        refText: String?,
        language: String?,
        generationParameters: GenerateParameters
    ) async throws

    func generate(
        text: String,
        voice: String?,
        refAudio: MLXArray?,
        refText: String?,
        language: String?,
        generationParameters: GenerateParameters
    ) async throws -> MLXArray

    func generateStream(
        text: String,
        voice: String?,
        refAudio: MLXArray?,
        refText: String?,
        language: String?,
        generationParameters: GenerateParameters
    ) -> AsyncThrowingStream<AudioGeneration, Error>

    func generateStream(
        text: String,
        voice: String?,
        refAudio: MLXArray?,
        refText: String?,
        language: String?,
        generationParameters: GenerateParameters,
        streamingInterval: Double
    ) -> AsyncThrowingStream<AudioGeneration, Error>
}

public enum AudioGenerationFinishReason: String, Sendable {
    case eos
    case maxTokens = "max_tokens"
    case cancelled
    case failed
}

public struct AudioGenerationCompletion: Sendable {
    public let audio: MLXArray
    public let info: AudioGenerationInfo?
    public let finishReason: AudioGenerationFinishReason

    public init(
        audio: MLXArray,
        info: AudioGenerationInfo?,
        finishReason: AudioGenerationFinishReason
    ) {
        self.audio = audio
        self.info = info
        self.finishReason = finishReason
    }
}

public protocol Qwen3OptimizedSpeechGenerationModel: AnyObject {
    func prepareCustomVoice(
        text: String,
        language: String,
        speaker: String,
        instruct: String?,
        generationParameters: GenerateParameters
    ) async throws

    func generateCustomVoiceStream(
        text: String,
        language: String,
        speaker: String,
        instruct: String?,
        generationParameters: GenerateParameters,
        streamingInterval: Double,
        customVoiceProfile: String?,
        streamStepEvalPolicy: String?,
        generationSpeedProfile: String?,
        memoryClearCadence: Int?
    ) -> AsyncThrowingStream<AudioGeneration, Error>

    func generateCustomVoice(
        text: String,
        language: String,
        speaker: String,
        instruct: String?,
        generationParameters: GenerateParameters
    ) async throws -> AudioGenerationCompletion

    func prepareVoiceDesign(
        text: String,
        language: String,
        voiceDescription: String,
        generationParameters: GenerateParameters
    ) async throws

    func generateVoiceDesignStream(
        text: String,
        language: String,
        voiceDescription: String,
        generationParameters: GenerateParameters,
        streamingInterval: Double,
        streamStepEvalPolicy: String?,
        generationSpeedProfile: String?,
        memoryClearCadence: Int?
    ) -> AsyncThrowingStream<AudioGeneration, Error>

    func generateVoiceDesign(
        text: String,
        language: String,
        voiceDescription: String,
        generationParameters: GenerateParameters
    ) async throws -> AudioGenerationCompletion

    func createVoiceClonePrompt(
        refAudio: MLXArray,
        refText: String?,
        xVectorOnlyMode: Bool
    ) throws -> Qwen3TTSVoiceClonePrompt

    func prepareVoiceClone(
        text: String,
        language: String,
        voiceClonePrompt: Qwen3TTSVoiceClonePrompt,
        generationParameters: GenerateParameters
    ) async throws

    func generateVoiceCloneStream(
        text: String,
        language: String,
        voiceClonePrompt: Qwen3TTSVoiceClonePrompt,
        generationParameters: GenerateParameters,
        streamingInterval: Double,
        streamStepEvalPolicy: String?,
        generationSpeedProfile: String?,
        memoryClearCadence: Int?
    ) -> AsyncThrowingStream<AudioGeneration, Error>

    func generateVoiceClone(
        text: String,
        language: String,
        voiceClonePrompt: Qwen3TTSVoiceClonePrompt,
        generationParameters: GenerateParameters
    ) async throws -> AudioGenerationCompletion
}

public protocol Qwen3CustomVoicePrewarmDepthControlling: AnyObject {
    func prepareCustomVoice(
        text: String,
        language: String,
        speaker: String,
        instruct: String?,
        generationParameters: GenerateParameters,
        customPrewarmDepth: String?
    ) async throws
}

public extension SpeechGenerationModel {
    func prepareForGeneration(
        text: String,
        voice: String?,
        refAudio: MLXArray?,
        refText: String?,
        language: String?,
        generationParameters: GenerateParameters
    ) async throws {
        let warmupMaxTokens = min(generationParameters.maxTokens ?? 1, 1)
        _ = try await generate(
            text: text,
            voice: voice,
            refAudio: refAudio,
            refText: refText,
            language: language,
            generationParameters: GenerateParameters(
                maxTokens: warmupMaxTokens,
                temperature: 0,
                topP: 1.0,
                repetitionPenalty: 1.0
            )
        )
    }

    func generate(
        text: String,
        voice: String?,
        refAudio: MLXArray?,
        refText: String?,
        language: String?,
        generationParameters: GenerateParameters? = nil
    ) async throws -> MLXArray {
        try await generate(text: text, voice: voice, refAudio: refAudio, refText: refText, language: language, generationParameters: generationParameters ?? defaultGenerationParameters)
    }

    func generateSamplesStream(
        text: String,
        voice: String?,
        refAudio: MLXArray?,
        refText: String?,
        language: String?,
        generationParameters: GenerateParameters? = nil,
        streamingInterval: Double = 2.0
    ) -> AsyncThrowingStream<[Float], Error> {
        let stream = generateStream(
            text: text,
            voice: voice,
            refAudio: refAudio,
            refText: refText,
            language: language,
            generationParameters: generationParameters ?? defaultGenerationParameters,
            streamingInterval: streamingInterval
        )
        return proxyAudioStream(stream, extract: {
            guard case .audio(let samples) = $0 else { return nil }
            return samples.asArray(Float.self)
        })
    }

#if canImport(AVFoundation)
    @MainActor
    func generatePCMBufferStream(
        text: String,
        voice: String?,
        refAudio: MLXArray?,
        refText: String?,
        language: String?,
        generationParameters: GenerateParameters? = nil,
        streamingInterval: Double = 2.0
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let sampleStream = generateSamplesStream(
            text: text,
            voice: voice,
            refAudio: refAudio,
            refText: refText,
            language: language,
            generationParameters: generationParameters,
            streamingInterval: streamingInterval
        )

        let (stream, continuation) = AsyncThrowingStream<AVAudioPCMBuffer, Error>.makeStream()
        let sampleRate = self.sampleRate

        let producerTask = Task { @MainActor in
            do {
                for try await samples in sampleStream {
                    try Task.checkCancellation()
                    let buffer = try makePCMBuffer(samples: samples, sampleRate: sampleRate)
                    try Task.checkCancellation()
                    continuation.yield(buffer)
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in producerTask.cancel() }

        return stream
    }
#endif

    func generateStream(
        text: String,
        voice: String?,
        refAudio: MLXArray?,
        refText: String?,
        language: String?,
        generationParameters: GenerateParameters,
        streamingInterval: Double = 2.0
    ) -> AsyncThrowingStream<AudioGeneration, Error> {
        _ = streamingInterval
        return generateStream(
            text: text,
            voice: voice,
            refAudio: refAudio,
            refText: refText,
            language: language,
            generationParameters: generationParameters
        )
    }
}

private func proxyAudioStream<T: Sendable, U: Sendable>(
    _ upstream: AsyncThrowingStream<T, Error>,
    extract: @Sendable @escaping (T) -> U?
) -> AsyncThrowingStream<U, Error> {
    AsyncThrowingStream<U, Error> { continuation in
        let task = Task { @Sendable in
            do {
                for try await value in upstream {
                    guard let extracted = extract(value) else { continue }
                    continuation.yield(extracted)
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
    }
}

#if canImport(AVFoundation)
@MainActor
private func makePCMBuffer(samples: [Float], sampleRate: Int) throws -> AVAudioPCMBuffer {
    let frameCount = AVAudioFrameCount(samples.count)
    guard
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
        let channel = buffer.floatChannelData?[0]
    else {
        throw AudioGenerationError.audioDecodingFailed("Failed to create AVAudioPCMBuffer")
    }

    buffer.frameLength = frameCount
    for i in 0 ..< samples.count {
        channel[i] = samples[i]
    }
    return buffer
}
#endif
