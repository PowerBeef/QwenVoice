import Foundation
import QwenVoiceCore
import Speech

/// Opt-in content-accuracy check: transcribe a generated take with Apple's
/// **on-device** Speech recognizer and compare to the input text (word error
/// rate). Catches garbled / wrong / dropped words — an objective slice of audio
/// quality, complementing the engine's reference-free defect detector.
///
/// **Off by default.** It adds latency and needs the Speech permission + an
/// on-device language model, so it runs only when `QWENVOICE_TRANSCRIPT_CHECK` is
/// set (`1`/`true`/`on`/`yes`). It never blocks or fails a generation: any
/// unavailability (no permission, no on-device model, headless) is logged and
/// skipped. Results append to `diagnostics/app/content-checks.jsonl`
/// (`{generationID, werPercent, transcript}` per line), size-capped like the other
/// diagnostics, and read by `scripts/summarize_generation_telemetry.py`.
///
/// NOT a revival of the retired Python audio-QC harness: no model download (the OS
/// provides the on-device model), no script harness, gated at runtime.
enum SpeechContentCheck {
    private static let environmentKey = "QWENVOICE_TRANSCRIPT_CHECK"

    static let isEnabled: Bool = {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else { return false }
        return ["1", "true", "on", "yes"].contains(raw)
    }()

    struct Result: Codable, Sendable {
        let generationID: String
        let werPercent: Double
        let referenceWordCount: Int
        let transcript: String
    }

    /// Fire-and-forget: transcribe + score + append. Safe to call unconditionally;
    /// no-ops when disabled or unavailable.
    static func run(
        generationID: UUID?,
        audioPath: String,
        referenceText: String,
        appSupportDirectory: URL
    ) async {
        guard isEnabled, let generationID else { return }
        let reference = normalize(referenceText)
        guard !reference.isEmpty else { return }

        guard ensureAuthorized() else {
            print("[SpeechContentCheck] skipped: Speech Recognition not authorized — enable it in System Settings → Privacy & Security → Speech Recognition (this check never prompts on its own)")
            return
        }
        // Use a fixed en-US recognizer for the (English) benchmark corpus rather
        // than `SFSpeechRecognizer()` (system locale) — on a non-English Mac the
        // default recognizer would try to transcribe English audio with the wrong
        // language model. Fall back to the system-locale recognizer if en-US is
        // unavailable.
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            ?? SFSpeechRecognizer(),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            print("[SpeechContentCheck] skipped: on-device recognition unavailable (locale \(SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.locale.identifier ?? "n/a"))")
            return
        }

        guard let transcript = await transcribe(
            url: URL(fileURLWithPath: audioPath),
            recognizer: recognizer
        ) else {
            print("[SpeechContentCheck] skipped: transcription produced no result")
            return
        }

        let refWords = reference.split(separator: " ").map(String.init)
        let hypWords = normalize(transcript).split(separator: " ").map(String.init)
        let distance = wordEditDistance(refWords, hypWords)
        let wer = refWords.isEmpty ? 0 : Double(distance) / Double(refWords.count) * 100

        let result = Result(
            generationID: generationID.uuidString,
            werPercent: (wer * 100).rounded() / 100,
            referenceWordCount: refWords.count,
            transcript: transcript
        )
        append(result, appSupportDirectory: appSupportDirectory)
    }

    // MARK: - Speech

    /// Only proceed when Speech Recognition is ALREADY authorized. A background
    /// QC check that piggybacks on generation must never trigger the system
    /// permission dialog — that's intrusive (it pops mid-generation) and, on
    /// locally ad-hoc-signed dev builds, TCC resets per rebuild so it would
    /// re-prompt after every build. The user enables Speech Recognition for the
    /// app once in System Settings → Privacy & Security; until then the check
    /// skips silently. Never calls `requestAuthorization`.
    private static func ensureAuthorized() -> Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    private static func transcribe(url: URL, recognizer: SFSpeechRecognizer) async -> String? {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return await withCheckedContinuation { continuation in
            // Guard against a double-resume if the recognizer ever delivers both a
            // final result and an error.
            let resumed = ResumeOnce()
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if resumed.claim() { continuation.resume(returning: nil) }
                    _ = error
                    return
                }
                guard let result, result.isFinal else { return }
                if resumed.claim() {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    /// One-shot latch so the continuation resumes exactly once.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    // MARK: - Scoring

    /// Lowercase, strip punctuation to spaces, collapse whitespace.
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                return Character(scalar)
            }
            return " "
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    /// Levenshtein edit distance over word tokens (substitutions/insertions/deletions).
    static func wordEditDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = Swift.min(
                    previous[j] + 1,        // deletion
                    current[j - 1] + 1,     // insertion
                    previous[j - 1] + cost  // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: - Sink

    private static func append(_ result: Result, appSupportDirectory: URL) {
        let directory = appSupportDirectory
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent("app", isDirectory: true)
        let url = directory.appendingPathComponent("content-checks.jsonl", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(result)
            data.append(0x0A)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
            GenerationTelemetryJSONLSink.pruneJSONLFromFront(
                at: url,
                maxBytes: GenerationTelemetryJSONLSink.maxLogBytes
            )
        } catch {
            print("[SpeechContentCheck] could not append result for '\(result.generationID)': \(error.localizedDescription)")
        }
    }
}
