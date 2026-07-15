import Foundation

/// Filesystem isolation for local engine benchmarks.
///
/// A benchmark without an explicit `--data-dir` always uses the debug-owned
/// Application Support root. This is independent of telemetry mode: turning
/// telemetry off must never make path resolution fall back to the production
/// app directory before the benchmark clears its diagnostics.
public enum LocalBenchmarkDataPolicy {
    public static func resolvedDataDirectory(
        explicitOverride: String?,
        applicationSupportBase: URL
    ) -> URL {
        if let explicitOverride,
           !explicitOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(
                fileURLWithPath: (explicitOverride as NSString).expandingTildeInPath,
                isDirectory: true
            ).standardizedFileURL
        }
        return applicationSupportBase
            .appendingPathComponent("QwenVoice-Debug", isDirectory: true)
            .standardizedFileURL
    }

    public static func mayClearDiagnostics(
        in dataDirectory: URL,
        productionDataDirectory: URL,
        force: Bool
    ) -> Bool {
        force || dataDirectory.standardizedFileURL.resolvingSymlinksInPath().path
            != productionDataDirectory.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
