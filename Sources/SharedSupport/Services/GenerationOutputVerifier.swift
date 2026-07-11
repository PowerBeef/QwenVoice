import Foundation
import QwenVoiceCore

/// Post-generation output verification for benchmark/device-diagnostics lanes — transcribes a WAV
/// in-process (Speech, on-device) and scores language match + word error rate vs the
/// source script. Avoids CLI Speech TCC issues documented in benchmarks/OPTIMIZATION.md.
enum GenerationOutputVerifier {
    struct Result: Codable, Sendable, Equatable {
        var transcript: String
        var detectedLanguage: String
        var expectedLanguage: String
        var languageMatchScore: Double
        var wordErrorRate: Double
        var languagePass: Bool
        var accuracyPass: Bool
        var pass: Bool
        var skipReason: String?
    }

    static func verify(
        audioURL: URL,
        expectedScript: String,
        expectedLanguage: Qwen3SupportedLanguage,
        maxWordErrorRate: Double = VoiceClipTranscriber.outputVerificationDefaultMaxWordErrorRate
    ) async -> Result {
        let expectedToken = expectedLanguage.rawValue

        switch VoiceClipTranscriber.availability() {
        case .denied, .siriDisabled:
            return skipped(expectedLanguage: expectedToken, reason: "speech_recognition_unavailable")
        case .notDetermined, .available:
            break
        }

        guard let transcript = await VoiceClipTranscriber.transcribeForVerification(
            url: audioURL,
            expectedLanguage: expectedLanguage
        ) else {
            return failed(
                expectedLanguage: expectedToken,
                reason: "transcription_failed",
                transcript: "",
                detectedLanguage: Qwen3SupportedLanguage.auto.rawValue
            )
        }

        let detected = PromptLanguageDetector.detect(transcript)
        let detectedToken = detected == .auto ? expectedToken : detected.rawValue
        let languageScore = VoiceClipTranscriber.languageMatchScore(
            text: transcript,
            expected: expectedLanguage
        )
        let languagePass = languageScore >= VoiceClipTranscriber.outputVerificationLanguagePassScore
        let wer = VoiceClipTranscriber.wordErrorRate(
            reference: expectedScript,
            hypothesis: transcript
        )
        let accuracyPass = wer <= maxWordErrorRate
        let pass = languagePass && accuracyPass

        return Result(
            transcript: transcript,
            detectedLanguage: detectedToken,
            expectedLanguage: expectedToken,
            languageMatchScore: languageScore,
            wordErrorRate: wer,
            languagePass: languagePass,
            accuracyPass: accuracyPass,
            pass: pass,
            skipReason: nil
        )
    }

    private static func skipped(expectedLanguage: String, reason: String) -> Result {
        Result(
            transcript: "",
            detectedLanguage: Qwen3SupportedLanguage.auto.rawValue,
            expectedLanguage: expectedLanguage,
            languageMatchScore: 0,
            wordErrorRate: 1,
            languagePass: false,
            accuracyPass: false,
            pass: false,
            skipReason: reason
        )
    }

    private static func failed(
        expectedLanguage: String,
        reason: String,
        transcript: String,
        detectedLanguage: String
    ) -> Result {
        Result(
            transcript: transcript,
            detectedLanguage: detectedLanguage,
            expectedLanguage: expectedLanguage,
            languageMatchScore: 0,
            wordErrorRate: 1,
            languagePass: false,
            accuracyPass: false,
            pass: false,
            skipReason: reason
        )
    }
}
