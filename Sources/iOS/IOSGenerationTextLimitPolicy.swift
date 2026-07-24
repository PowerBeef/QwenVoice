import Foundation
import QwenVoiceCore

struct IOSGenerationTextLimitPolicy {
    /// Single-take spoken-script ceiling. Matches the delivery-validated 900-character
    /// boundary shared with the macOS long-form router: the engine's 2,048-token cap
    /// (~170 s of audio) comfortably covers ~900 characters, and the raise is gated on
    /// an on-device memory-qualified proof at this length (2026-07-24). Raising it
    /// further requires new device evidence; scripts beyond it need the iOS long-form arc.
    private static let sharedScriptLimit = 900

    /// Voice Design BRIEF (the voice DESCRIPTION) limit — deliberately decoupled from the
    /// spoken-script limit above. Sourced from the shared catalog so the iOS sheet and the
    /// macOS inline editor stay in lockstep.
    static let descriptionLimit = VoiceDesignBriefCatalog.descriptionLimit

    /// Delivery instruction / custom tone limit. The instruction is passed to the model as an
    /// emotion/delivery style string.
    ///
    /// Research (Qwen3-TTS hosted API) allows up to 1,600 tokens for `instructions`, and the
    /// open-weights examples are short phrases. 500 characters gives users 2–3 dense,
    /// multidimensional sentences (emotion + pace + pitch + timbre) while discouraging
    /// paragraph-length prompts. It also leaves room for the English diction reinforcement
    /// clause appended during prompt assembly.
    static let deliveryInstructionLimit = 500

    struct State: Equatable {
        let count: Int
        let limit: Int
        let trimmedIsEmpty: Bool

        var remainingCount: Int {
            max(limit - count, 0)
        }

        var isOverLimit: Bool {
            count > limit
        }

        var counterText: String {
            "\(count)/\(limit)"
        }

        var helperMessage: String {
            if isOverLimit {
                return warningMessage
            }
            if remainingCount == 0 {
                return "At the on-device limit for this mode."
            }
            return "\(remainingCount) characters remaining for on-device generation."
        }

        var warningMessage: String {
            "Shorten the script to \(limit) characters or less for on-device generation."
        }

        var readinessTitle: String {
            "Shorten script to \(limit) chars"
        }
    }

    static func state(for text: String, mode: GenerationMode) -> State {
        State(
            count: text.count,
            limit: limit(for: mode),
            trimmedIsEmpty: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    static func clamped(_ text: String, mode: GenerationMode) -> String {
        let limit = limit(for: mode)
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }

    static func limit(for mode: GenerationMode) -> Int {
        sharedScriptLimit
    }
}
