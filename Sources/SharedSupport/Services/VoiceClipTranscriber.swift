import AVFoundation
import Foundation
import NaturalLanguage
import QwenVoiceCore
import Speech

/// Best-effort **on-device** transcription + language detection of a finished reference WAV, used
/// to pre-fill the (editable, optional) transcript and to auto-set the Clone language when enrolling
/// a recorded voice.
///
/// Covers **all Qwen3-TTS languages** whose on-device recognition model is already installed on the
/// device (no downloads). For each candidate language it transcribes the clip on-device, then uses
/// `NLLanguageRecognizer` to score how strongly the resulting text is actually in that language —
/// a far more reliable signal than `SFSpeechRecognizer`'s (often-zero) confidence. The user's
/// preferred device languages are tried first, so the common case matches on the first pass.
///
/// Everything degrades to `nil` (no transcript, language `.auto`) so enrollment is never blocked,
/// and audio never leaves the device (`requiresOnDeviceRecognition`).
enum VoiceClipTranscriber {
    /// Why automatic transcription may currently be unavailable — drives the
    /// permission captions in the enrollment/clone UI instead of failing
    /// silently.
    enum TranscriptionAvailability: Equatable {
        /// Authorized — transcription can run.
        case available
        /// The user hasn't been asked yet; the system prompt appears on first use.
        case notDetermined
        /// The user (or a policy) denied speech recognition for this app —
        /// recoverable in System Settings → Privacy & Security → Speech Recognition.
        case denied
        /// macOS only: Siri is disabled, so the OS auto-denies speech-recognition
        /// authorization without ever showing a prompt. Recoverable by enabling
        /// Siri in System Settings, then granting the app.
        case siriDisabled
    }

    /// Cheap, prompt-free availability check for UI captions. (The expensive
    /// on-device-locale enumeration is NOT included — a missing model already
    /// degrades gracefully to "no transcript".)
    static func availability() -> TranscriptionAvailability {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return .available
        case .notDetermined:
            #if os(macOS)
            if !isSiriEnabled { return .siriDisabled }
            #endif
            return .notDetermined
        case .denied, .restricted:
            #if os(macOS)
            if !isSiriEnabled { return .siriDisabled }
            #endif
            return .denied
        @unknown default:
            return .denied
        }
    }

    #if os(macOS)
    /// On macOS, SFSpeechRecognizer authorization is auto-DENIED while Siri is
    /// off — an OS gate, no prompt is ever shown. Readable directly because the
    /// app is not sandboxed; defaults to true when unreadable so we never show
    /// a false warning.
    private static var isSiriEnabled: Bool {
        guard let value = UserDefaults(suiteName: "com.apple.assistant.support")?
            .object(forKey: "Assistant Enabled") as? NSNumber else { return true }
        return value.boolValue
    }
    #endif

    /// Score at/above which we accept a candidate's language as the detected one.
    private static let confidentLanguageScore = 0.5
    /// Score at/above which we stop trying further candidates (a clear match).
    private static let earlyExitScore = 0.85
    /// Below this, the transcript looks like noise → don't fill it.
    private static let minimumUsableScore = 0.2

    static func transcribe(url: URL) async -> (text: String, language: Qwen3SupportedLanguage)? {
        guard await requestAuthorization() else { return nil }

        var best: (text: String, language: Qwen3SupportedLanguage, score: Double, confidence: Float)?

        for candidate in candidateLocales() {
            guard let pass = await recognize(url: url, locale: candidate.locale) else { continue }
            let score = languageMatchScore(text: pass.text, expected: candidate.language)

            let isBetter: Bool
            if let best {
                isBetter = score != best.score ? score > best.score : pass.confidence > best.confidence
            } else {
                isBetter = true
            }
            if isBetter {
                best = (pass.text, candidate.language, score, pass.confidence)
            }
            if score >= earlyExitScore { break }
        }

        guard let best, best.score >= minimumUsableScore else { return nil }
        // Confident → use the detected language; weak → fill the transcript but leave language .auto.
        let language = best.score >= confidentLanguageScore ? best.language : .auto
        return (best.text, language)
    }

    /// One on-device-capable locale per Qwen language, the user's preferred languages first.
    private static func candidateLocales() -> [(locale: Locale, language: Qwen3SupportedLanguage)] {
        let preferred = Locale.preferredLanguages

        func regionRank(_ locale: Locale) -> Int {
            for (i, pref) in preferred.enumerated()
            where pref.caseInsensitiveCompare(locale.identifier) == .orderedSame {
                return i // exact preferred match
            }
            for (i, pref) in preferred.enumerated()
            where Locale(identifier: pref).language.languageCode?.identifier
                == locale.language.languageCode?.identifier {
                return 100 + i // same language as a preferred one
            }
            return 1000 // not a preferred language
        }

        // Keep one locale per Qwen language, preferring the user's region variant.
        var byLanguage: [Qwen3SupportedLanguage: (locale: Locale, rank: Int)] = [:]
        for locale in SFSpeechRecognizer.supportedLocales() {
            let language = Qwen3SupportedLanguage.normalized(locale.language.languageCode?.identifier)
            guard language != .auto else { continue }
            guard SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true else { continue }
            let rank = regionRank(locale)
            if let existing = byLanguage[language], existing.rank <= rank { continue }
            byLanguage[language] = (locale, rank)
        }

        return byLanguage
            .map { (language: $0.key, locale: $0.value.locale, rank: $0.value.rank) }
            .sorted { lhs, rhs in
                lhs.rank != rhs.rank ? lhs.rank < rhs.rank : lhs.language.rawValue < rhs.language.rawValue
            }
            .map { (locale: $0.locale, language: $0.language) }
    }

    /// NaturalLanguage probability mass that the text is in `expected` (handles script/region
    /// variants like zh-Hans/zh-Hant, pt-BR/pt-PT by collapsing to the base language code).
    private static func languageMatchScore(text: String, expected: Qwen3SupportedLanguage) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        var score = 0.0
        for (language, probability) in recognizer.languageHypotheses(withMaximum: 5) {
            let code = Locale(identifier: language.rawValue).language.languageCode?.identifier
                ?? language.rawValue
            if Qwen3SupportedLanguage.normalized(code) == expected {
                score += probability
            }
        }
        return score
    }

    private static func recognize(url: URL, locale: Locale) async -> (text: String, confidence: Float)? {
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { return nil }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        let once = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<(text: String, confidence: Float)?, Never>) in
            recognizer.recognitionTask(with: request) { result, error in
                if error != nil {
                    once.run { continuation.resume(returning: nil) }
                    return
                }
                guard let result, result.isFinal else { return }
                let transcription = result.bestTranscription
                let text = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                let segments = transcription.segments
                let confidence = segments.isEmpty
                    ? 0
                    : segments.map(\.confidence).reduce(0, +) / Float(segments.count)
                once.run {
                    continuation.resume(returning: text.isEmpty ? nil : (text, confidence))
                }
            }
        }
    }

    private static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

/// One-shot guard so the recognition callback (which may fire more than once) resumes the
/// continuation exactly once. Lock-guarded so it's safe to capture in the `@Sendable` handler.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func run(_ block: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        block()
    }
}
