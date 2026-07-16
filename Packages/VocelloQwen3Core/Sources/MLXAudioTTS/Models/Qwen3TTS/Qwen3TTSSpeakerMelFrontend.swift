import Foundation
@preconcurrency import MLX
import MLXAudioCore

/// Qwen3-TTS speaker-encoder waveform frontend.
///
/// This is deliberately separate from MLXAudioCore's generic mel frontend:
/// Qwen's speaker encoder consumes magnitude mels with natural-log scaling,
/// while the generic helper produces a Whisper-style power/log10 feature.
struct Qwen3TTSSpeakerMelFrontend {
    static let featureVersion = "qwen-speaker-mel-v1"

    static let sampleRate = 24_000
    static let fftSize = 1_024
    static let hopLength = 256
    static let reflectPadding = 384
    static let melBinCount = 128
    static let minimumFrequency: Float = 0
    static let maximumFrequency: Float = 12_000

    private static let magnitudeEpsilon: Float = 1e-9
    private static let logFloor: Float = 1e-5

    /// Transforms mono `[T]` or batched `[B, T]` float audio into
    /// speaker-encoder features shaped `[B, frames, 128]`.
    func callAsFunction(_ audio: MLXArray) throws -> MLXArray {
        guard audio.ndim == 1 || audio.ndim == 2 else {
            throw AudioGenerationError.invalidInput(
                "Qwen speaker audio must have shape [T] or [B, T]."
            )
        }

        let batched = audio.ndim == 1 ? audio.reshaped(1, -1) : audio
        let sampleCount = batched.dim(1)
        guard sampleCount > Self.reflectPadding else {
            throw AudioGenerationError.invalidInput(
                "Qwen speaker audio must contain more than \(Self.reflectPadding) samples for reflect padding."
            )
        }

        let waveform = batched.asType(.float32)
        let left = waveform[0..., 1 ..< (Self.reflectPadding + 1)][0..., .stride(by: -1)]
        let right = waveform[0..., (-(Self.reflectPadding + 1)) ..< (-1)][0..., .stride(by: -1)]
        let padded = concatenated([left, waveform, right], axis: 1)

        let paddedSampleCount = padded.dim(1)
        let frameCount = 1 + (paddedSampleCount - Self.fftSize) / Self.hopLength
        guard frameCount > 0 else {
            throw AudioGenerationError.invalidInput(
                "Qwen speaker audio is too short to form an FFT frame."
            )
        }

        let frames = asStrided(
            padded,
            [padded.dim(0), frameCount, Self.fftSize],
            strides: [paddedSampleCount, Self.hopLength, 1]
        )
        let windowed = frames * Self.periodicHannWindow()
        let spectrum = MLXFFT.rfft(windowed, n: Self.fftSize, axis: -1)
        let spectrumAbsolute = MLX.abs(spectrum)
        let magnitude = MLX.sqrt(spectrumAbsolute.square() + Self.magnitudeEpsilon)

        let filterbank = melFilters(
            sampleRate: Self.sampleRate,
            nFft: Self.fftSize,
            nMels: Self.melBinCount,
            fMin: Self.minimumFrequency,
            fMax: Self.maximumFrequency,
            norm: "slaney",
            melScale: .slaney
        )
        let mel = matmul(magnitude, filterbank)
        return MLX.log(MLX.maximum(mel, MLXArray(Self.logFloor)))
    }

    static func periodicHannWindow() -> MLXArray {
        let denominator = Float(fftSize)
        let values = (0 ..< fftSize).map { index in
            Float(0.5) - Float(0.5) * cos(2 * Float.pi * Float(index) / denominator)
        }
        return MLXArray(values)
    }
}
