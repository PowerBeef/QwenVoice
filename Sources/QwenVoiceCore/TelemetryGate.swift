import Foundation

/// Process-portable runtime gate for durable generation telemetry.
///
/// `TelemetryGate` is the Core-visible equivalent every process can read, so
/// telemetry persistence is gated at runtime
/// (never compiled out, no `#if DEBUG`): dev and shipped binaries run identical paths.
///
/// Resolution sources:
/// - `QWENVOICE_DEBUG` env var (`1` / `true` / `on` / `yes`) — mirrors `DebugMode`'s env
///   key, so `scripts/build.sh run` lights up every process it launches.
/// - `QWENVOICE_NATIVE_TELEMETRY_MODE` set to `light` / `lightweight` (back-compat).
/// - A handshake override (`applyHandshakeMode(_:)`): the app process resolves its own
///   environment mode and passes it to engine processes over the IPC `initialize`
///   handshake. The host applies it on receipt, so `verbose` reaches the engine too.
public enum TelemetryGate {
    private static let environmentKey = "QWENVOICE_DEBUG"
    private static let telemetryModeKey = "QWENVOICE_NATIVE_TELEMETRY_MODE"

    /// Resolved once per process from the environment.
    public static let isEnabled: Bool = resolve()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handshakeOverride = false
    nonisolated(unsafe) private static var handshakeMode: NativeTelemetryMode?

    /// Master on/off for durable telemetry persistence in this process.
    /// True if the environment enabled it, or a host learned the toggle over IPC.
    public static var resolvedEnabled: Bool {
        if isEnabled { return true }
        lock.lock()
        defer { lock.unlock() }
        return handshakeOverride
    }

    /// Called by an engine-process host with the app's resolved telemetry **mode**.
    /// The environment (`QWENVOICE_NATIVE_TELEMETRY_MODE`) does not cross the process
    /// boundary, so `verbose` (raw per-sample sidecar) would otherwise never reach the
    /// engine — this carries it. One-way latch; `.off` is ignored.
    public static func applyHandshakeMode(_ mode: NativeTelemetryMode) {
        guard mode != .off else { return }
        lock.lock()
        defer { lock.unlock() }
        handshakeOverride = true
        handshakeMode = mode
    }

    /// The mode learned over the handshake (engine processes), or nil app-side.
    public static var handshakeResolvedMode: NativeTelemetryMode? {
        lock.lock()
        defer { lock.unlock() }
        return handshakeMode
    }

    /// The telemetry **mode** as seen from the **app process** — the env mode if set
    /// explicitly, else `.lightweight` when the explicit process gate
    /// is on, else `.off`. The client ships this over the handshake.
    public static var appProcessIntendedMode: NativeTelemetryMode {
        let envMode = NativeTelemetryMode.current()
        if envMode != .off { return envMode }
        return appProcessIntendedEnabled ? .lightweight : .off
    }

    /// The telemetry decision as seen from the app process. It is shipped to
    /// engine hosts on the initialize handshake because environment values do
    /// not automatically cross an XPC process boundary.
    public static var appProcessIntendedEnabled: Bool {
        isEnabled
    }

    private static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let debug = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            ["1", "true", "on", "yes"].contains(debug) {
            return true
        }
        switch environment[telemetryModeKey]?.lowercased() {
        case "light", "lightweight", "verbose", "full", "deep":
            return true
        default:
            return false
        }
    }
}
