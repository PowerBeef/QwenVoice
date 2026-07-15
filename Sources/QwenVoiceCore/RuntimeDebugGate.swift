import Foundation

/// The single process-local gate for environment variables that may alter
/// production runtime behavior. Shipped binaries keep the diagnostic code so
/// release builds can be exercised, but an individual tuning/path variable is
/// inert unless `QWENVOICE_DEBUG` is explicitly enabled for that process.
public enum RuntimeDebugGate {
    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment["QWENVOICE_DEBUG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }
        return ["1", "true", "on", "yes"].contains(raw)
    }

    public static func value(
        for key: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard isEnabled(environment: environment) else { return nil }
        return environment[key]
    }
}
