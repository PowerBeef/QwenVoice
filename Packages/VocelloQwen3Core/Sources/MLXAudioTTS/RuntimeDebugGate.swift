import Foundation

/// Package-internal counterpart of the product runtime gate. The implementation
/// target cannot import its facade without a dependency cycle, so it enforces
/// the same explicit `QWENVOICE_DEBUG` contract locally.
enum VocelloQwen3ImplementationDebugGate {
    static func value(
        for key: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let raw = environment["QWENVOICE_DEBUG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            ["1", "true", "on", "yes"].contains(raw) else {
            return nil
        }
        return environment[key]
    }
}
