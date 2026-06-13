import Foundation
import QwenVoiceCore

/// iOS counterpart to macOS `GenerationVariationPreference` (GitHub #47): the
/// Settings → "Variation" preference — how much takes vary when you regenerate
/// the same text (Expressive / Balanced / Consistent). Persisted in
/// `UserDefaults.standard` (the iOS prefs store; macOS uses the debug-aware
/// `AppDefaults.store`) and stamped onto every iOS `GenerationRequest` by the
/// three Studio mode views so iOS reaches parity with macOS.
public enum IOSGenerationVariationPreference {
    public static let key = "vocello.ios.generationVariation"
    public static let defaultValue = Qwen3SamplingVariation.expressive.rawValue

    /// The variation to stamp on a request, or `nil` for `expressive` (the
    /// official-checkpoint sampling). Returning nil keeps default requests
    /// byte-identical to before — the engine treats nil and `.expressive`
    /// identically.
    public static func requestValue() -> Qwen3SamplingVariation? {
        let raw = UserDefaults.standard.string(forKey: key) ?? defaultValue
        let variation = Qwen3SamplingVariation(rawValue: raw) ?? .expressive
        return variation == .expressive ? nil : variation
    }
}
