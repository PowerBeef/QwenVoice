@_exported import MLX
@_exported import MLXAudioCore
@_exported import MLXAudioTTS

import Foundation

public enum QwenVoiceBackendProvenance {
    public static let upstreamRepository = "https://github.com/Blaizzy/mlx-audio-swift"
    public static let upstreamTag = "v0.1.2"
    public static let upstreamCommit = "fcbd04daa1bfebe881932f630af2ba6ce9af3274"
    public static let officialQwen3Repository = "https://github.com/QwenLM/Qwen3-TTS"
}

public struct Qwen3GenerationConfiguration: Codable, Equatable, Sendable {
    public let maxNewTokens: Int
    public let minNewTokens: Int
    public let temperature: Float
    public let topK: Int
    public let topP: Float
    public let repetitionPenalty: Float

    public init(
        maxNewTokens: Int = 2_048,
        minNewTokens: Int = 2,
        temperature: Float = 0.9,
        topK: Int = 50,
        topP: Float = 1.0,
        repetitionPenalty: Float = 1.05
    ) {
        self.maxNewTokens = maxNewTokens
        self.minNewTokens = minNewTokens
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
    }

    public static let officialQualityDefault = Qwen3GenerationConfiguration()
}

public enum QwenVoiceGenerationFinishReason: String, Codable, Hashable, Sendable {
    case eos
    case maxTokens = "max_tokens"
    case cancelled
    case failed
}

public protocol QwenVoiceSynthesisBackend: AnyObject, Sendable {
    var sampleRate: Int { get }
    func cancelActiveGeneration() async throws
}
