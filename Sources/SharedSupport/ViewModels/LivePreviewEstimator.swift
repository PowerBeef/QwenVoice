import Foundation

#if canImport(QwenVoiceCore)
import QwenVoiceCore
#endif

/// Forecasts the audio duration and engine RTF for an upcoming
/// generation, so `AudioPlayerViewModel.shouldStartLivePlayback` can
/// compute a "smooth playback" prebuffer that covers the production
/// deficit. Single source of truth for the empirical constants —
/// future tuning lives here.
///
/// Constants are sourced from the May 2026 desktop-UI benchmark
/// (`scripts/bench_ui_generation.sh`) on the M1 Mac mini 8 GB:
///   - Custom Voice (warm, medium/long): RTF ≈ 1.65×
///   - Voice Design (warm, medium/long): RTF ≈ 1.50×
///   - Voice Cloning (warm, medium/long): no clean baseline yet —
///     use the Custom Voice estimate as a conservative fallback;
///     update once cloning bench data is captured.
/// Words-to-audio rate of ~0.40 audio s / word matches ~150 wpm
/// English speech, validated across short / medium / long tiers in
/// both Custom Voice and Voice Design.
enum LivePreviewEstimator {
    /// Approximate audio duration for the given English word count.
    /// Conservative (slightly over-estimates) so the predictive
    /// prebuffer leans toward "smooth" rather than "almost smooth."
    static func estimatedAudioSeconds(forWordCount wordCount: Int) -> TimeInterval {
        guard wordCount > 0 else { return 0 }
        return Double(wordCount) * 0.40
    }

    /// Convenience for callers that have raw text. Splits on
    /// whitespace and counts non-empty tokens.
    static func estimatedAudioSeconds(forText text: String) -> TimeInterval {
        let words = text
            .split(whereSeparator: { $0.isWhitespace })
            .filter { !$0.isEmpty }
            .count
        return estimatedAudioSeconds(forWordCount: words)
    }

    #if canImport(QwenVoiceCore)
    /// Empirical engine RTF for the given mode (warm, medium/long).
    /// Returns nil for modes where the production deficit isn't a
    /// concern in practice.
    static func estimatedRTF(for mode: GenerationMode) -> Double? {
        switch mode {
        case .custom: return 1.65
        case .design: return 1.50
        case .clone:  return 1.65
        }
    }
    #endif
}
