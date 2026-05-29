import Foundation

/// Runtime "secret debug toggle" that replaces compile-time `#if DEBUG` for the
/// single shipped Release package. The debug capabilities it gates (telemetry,
/// probing) are wired behind `DebugMode.isEnabled` rather than compiled out, so
/// dev and release run the same binary.
///
/// Activation (either):
/// - `QWENVOICE_DEBUG` env var set to `1` / `true` / `on` / `yes` (dev + scripts), or
/// - a persisted `UserDefaults` flag flipped by the hidden version-tap gesture (field builds).
///
/// `isEnabled` is resolved **once per process** at launch (it gates the data-folder
/// selection in `AppPaths`, which is resolved early). The gesture flips the persisted
/// flag; path-dependent effects apply on the next launch.
enum DebugMode {
    static let userDefaultsKey = "QwenVoice.DebugModeEnabled"
    private static let environmentKey = "QWENVOICE_DEBUG"

    static let isEnabled: Bool = resolve()

    private static func resolve() -> Bool {
        let env = ProcessInfo.processInfo.environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let env, ["1", "true", "on", "yes"].contains(env) { return true }
        return UserDefaults.standard.bool(forKey: userDefaultsKey)
    }

    /// The live persisted flag (reflects the gesture immediately, unlike `isEnabled`).
    static var persistedFlag: Bool {
        UserDefaults.standard.bool(forKey: userDefaultsKey)
    }

    /// Flip the persisted flag. Used by the hidden gesture. Returns the new value.
    /// Path-dependent effects (data folder) apply on the next launch.
    @discardableResult
    static func togglePersistedFlag() -> Bool {
        let newValue = !persistedFlag
        UserDefaults.standard.set(newValue, forKey: userDefaultsKey)
        return newValue
    }
}
