import Foundation

/// Lightweight, non-blocking guidance for the Custom Tone / delivery-instruction
/// editor. Research-backed: Qwen3-TTS instructions work best when they are
/// specific, multidimensional, and avoid vague terms or imitation requests.
enum IOSDeliveryInstructionGuidance {

    /// Vague words that the official docs flag as weak. If any are present we
    /// surface a concrete alternative suggestion.
    private static let weakWords: [String: [String]] = [
        "nice": ["warm", "smooth", "clear"],
        "normal": ["natural", "even", "conversational"],
        "good": ["clear", "confident", "warm"],
        "better": ["clearer", "warmer", "more energetic"],
        "interesting": ["engaging", "expressive", "dynamic"],
        "fun": ["playful", "lively", "upbeat"],
        "bad": ["rough", "tense", "strained"],
        "happy": ["cheerful", "upbeat", "warm"],
        "sad": ["somber", "melancholy", "subdued"],
    ]

    private static let imitationPhrases = [
        "sound like", "just like", "exactly like", "imitate",
    ]

    /// Minimum length that tends to produce reliable delivery control.
    private static let shortInstructionThreshold = 10

    /// Returns a tip if the instruction contains vague or weak wording.
    static func weakWordSuggestion(for text: String) -> String? {
        let lowercased = text.lowercased()
        for (word, alternatives) in weakWords {
            let boundary = CharacterSet.alphanumerics.inverted
            let components = lowercased.components(separatedBy: boundary)
            if components.contains(word) {
                let joined = alternatives.joined(separator: ", ")
                return "Try a more concrete word like \(joined)."
            }
        }
        return nil
    }

    /// Returns a warning if the instruction asks for celebrity / voice imitation.
    static func imitationWarning(for text: String) -> String? {
        let lowercased = text.lowercased()
        let containsImitationPhrase = imitationPhrases.contains { lowercased.contains($0) }
        guard containsImitationPhrase else { return nil }
        return "Voice imitation of real people is not supported."
    }

    /// Returns a nudge if the instruction is too short to be descriptive.
    static func shortInstructionNudge(for text: String) -> String? {
        let meaningful = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard meaningful.count < shortInstructionThreshold else { return nil }
        return "Add a little more detail: emotion, timbre, pace, or style."
    }

    /// Returns the most relevant guidance message, if any. Priority: imitation
    /// warning, then weak-word suggestion, then short-instruction nudge.
    static func message(for text: String) -> String? {
        imitationWarning(for: text)
            ?? weakWordSuggestion(for: text)
            ?? shortInstructionNudge(for: text)
    }

    /// Whether the instruction looks concrete enough to not need a nudge.
    static func looksSolid(for text: String) -> Bool {
        message(for: text) == nil
    }
}
