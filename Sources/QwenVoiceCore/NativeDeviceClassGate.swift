import Foundation

/// Process-portable override for the resolved `NativeDeviceMemoryClass`.
///
/// `NativeMemoryPolicyResolver.deviceClass()` normally reads real
/// `ProcessInfo.physicalMemory`, so a high-memory dev Mac always resolves to
/// `highMemoryMac` — where the memory-pressure monitor never starts and the
/// constrained-tier policy (tight caches, post-batch hard trim, idle unload) is
/// never exercised. This gate lets a benchmark **force** a tier so those code
/// paths run (and pressure becomes measurable) without special hardware.
///
/// Mirrors `TelemetryGate`'s cross-process design (and, like it, is plain runtime
/// — **never `#if DEBUG`**, which is dead code in this single-Release-config repo):
/// - The **app process** reads `QWENVOICE_FORCE_MEMORY_CLASS` from the environment.
/// - The environment does not cross to the engine process (XPC service / iOS
///   extension), so the app ships its forced class over the `initialize` IPC
///   handshake and the engine host latches it via `applyHandshakeForcedClass(_:)`.
///
/// Off by default: unset env + no handshake ⇒ `resolvedForcedClass == nil` ⇒
/// `deviceClass()` returns the real, physical-memory-derived tier (no behavior
/// change).
public enum NativeDeviceClassGate {
    private static let environmentKey = "QWENVOICE_FORCE_MEMORY_CLASS"

    /// The forced class as seen from the **app process**: parsed from the
    /// environment once per process. `nil` when unset/unrecognized.
    public static let appProcessForcedClass: NativeDeviceMemoryClass? = {
        parse(RuntimeDebugGate.value(for: environmentKey))
    }()

    /// Wire-friendly raw value the app ships over the handshake: the forced class
    /// rawValue, or `""` when unset.
    public static var appProcessForcedClassRawValue: String {
        appProcessForcedClass?.rawValue ?? ""
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handshakeForcedClass: NativeDeviceMemoryClass?

    /// Called by an engine-process host with the app's forced class (the `""`
    /// sentinel — or an unrecognized value — is ignored). One-way latch.
    public static func applyHandshakeForcedClass(_ raw: String) {
        guard let forced = parse(raw) else { return }
        lock.lock()
        defer { lock.unlock() }
        handshakeForcedClass = forced
    }

    /// The effective forced class for this process: the env value (app process)
    /// or the handshake latch (engine process). `nil` ⇒ use the real tier.
    public static var resolvedForcedClass: NativeDeviceMemoryClass? {
        if let appProcessForcedClass { return appProcessForcedClass }
        lock.lock()
        defer { lock.unlock() }
        return handshakeForcedClass
    }

    /// Accepts the `NativeDeviceMemoryClass` rawValues
    /// (`floor_8gb_mac` / `mid_16gb_mac` / `high_memory_mac` / `iphone_pro`) plus a
    /// few friendly aliases. Case/whitespace-insensitive. Returns `nil` for empty
    /// or unrecognized input.
    static func parse(_ raw: String?) -> NativeDeviceMemoryClass? {
        guard let trimmed = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !trimmed.isEmpty else {
            return nil
        }
        if let exact = NativeDeviceMemoryClass(rawValue: trimmed) {
            return exact
        }
        switch trimmed {
        case "8gb", "floor", "floor8gbmac":
            return .floor8GBMac
        case "16gb", "mid", "mid16gbmac":
            return .mid16GBMac
        case "high", "highmemorymac":
            return .highMemoryMac
        case "iphone", "iphonepro":
            return .iPhonePro
        default:
            return nil
        }
    }
}
