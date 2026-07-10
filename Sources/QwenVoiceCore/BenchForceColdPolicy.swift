import Foundation

/// Debug-only benchmark hook: force an explicit model unload immediately before the next
/// generation so telemetry records `warmState=cold`. Honored only when durable telemetry
/// is enabled (`TelemetryGate`), matching the trust model for other bench env vars.
public enum BenchForceColdPolicy {
    private static let environmentKey = "QWENVOICE_BENCH_FORCE_COLD"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var consumed = false

    public static var shouldUnloadBeforeGeneration: Bool {
        guard TelemetryGate.resolvedEnabled else { return false }
        let value = ProcessInfo.processInfo.environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let value, ["1", "true", "on", "yes"].contains(value) else { return false }

        // A cold benchmark launch must unload exactly once. The same process then
        // owns the warm repetitions; re-reading a permanently set environment key
        // for every request would silently turn the entire block into cold takes.
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { return false }
        consumed = true
        return true
    }
}
