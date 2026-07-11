import Foundation
import QwenVoiceCore

/// Copies App-Group `diagnostics/<layer>/generations.jsonl` into the app's own
/// container at `Library/Caches/Vocello/diagnostics/<layer>/generations.jsonl`.
///
/// devicectl can pull appDataContainer but NOT the App Group, so on-device
/// bench/gate lanes read telemetry from the Caches mirror (see
/// `scripts/ios_device.sh pull` and `IOSDeviceDiagnosticsRunner`).
enum IOSPullableDiagnosticsMirror {
    /// App-Group diagnostics dir where the in-process engine writes JSONL rows.
    private static var appGroupDiagnosticsRoot: URL {
        AppPaths.appSupportDir.appendingPathComponent("diagnostics", isDirectory: true)
    }

    /// devicectl-pullable export root (`Library/Caches/Vocello/diagnostics`).
    static var pullableRoot: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Vocello", isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
    }

    /// Mirror engine/app JSONL telemetry after each debug generation so the
    /// XCUITest benchmark validator can pull and gate without a diagnostics sentinel.
    static func syncEngineTelemetryIfEnabled() {
        guard TelemetryGate.resolvedEnabled else { return }
        guard let pullableRoot else { return }
        syncEngineTelemetry(from: appGroupDiagnosticsRoot, into: pullableRoot)
    }

    static func syncEngineTelemetry(from sourceRoot: URL, into pullableRoot: URL) {
        let fileManager = FileManager.default
        for layer in ["engine", "engine-service", "app"] {
            let from = sourceRoot.appendingPathComponent(layer, isDirectory: true)
                .appendingPathComponent("generations.jsonl", isDirectory: false)
            guard fileManager.fileExists(atPath: from.path) else { continue }
            let to = pullableRoot.appendingPathComponent(layer, isDirectory: true)
                .appendingPathComponent("generations.jsonl", isDirectory: false)
            do {
                try fileManager.createDirectory(
                    at: to.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: to.path) {
                    try fileManager.removeItem(at: to)
                }
                try fileManager.copyItem(at: from, to: to)
            } catch {
                print("[IOSPullableDiagnosticsMirror] could not mirror \(layer) telemetry: \(error.localizedDescription)")
            }
        }
    }
}
