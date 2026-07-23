import Foundation

enum LongTextGenerationRouter {
    /// Single-take texts up to this length generate directly; longer scripts
    /// route to the long-form v4 planner. Matches the retired character
    /// segmenter's historical threshold so routing behavior is unchanged.
    static let directGenerationCharacterLimit = 900

    static func shouldRouteToLongFormBatch(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count > directGenerationCharacterLimit
    }
}
