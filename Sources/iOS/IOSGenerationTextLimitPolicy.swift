import Foundation
import QwenVoiceCore

struct IOSGenerationTextLimitPolicy {
    private static let sharedScriptLimit = 150

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
