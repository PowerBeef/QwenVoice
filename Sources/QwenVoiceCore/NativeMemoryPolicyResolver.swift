import Foundation
import MLX

public enum NativeMemoryPolicyResolver {
    private static let oneGB = 1_024 * 1_024 * 1_024

    public static func deviceClass(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        isIPhone: Bool = {
            #if os(iOS)
            return true
            #else
            return false
            #endif
        }()
    ) -> NativeDeviceMemoryClass {
        if isIPhone {
            return .iPhonePro
        }
        if physicalMemoryBytes <= UInt64(10 * oneGB) {
            return .floor8GBMac
        }
        if physicalMemoryBytes <= UInt64(24 * oneGB) {
            return .mid16GBMac
        }
        return .highMemoryMac
    }

    public static func policy(
        deviceClass: NativeDeviceMemoryClass = deviceClass(),
        mode: GenerationMode,
        isBatch: Bool
    ) -> NativeMemoryPolicy {
        switch deviceClass {
        case .floor8GBMac:
            return NativeMemoryPolicy(
                name: "floor_8gb_mac_\(mode.rawValue)_\(isBatch ? "batch" : "single")",
                deviceClass: deviceClass,
                cacheLimitBytes: 256 * 1_024 * 1_024,
                clearCacheAfterGeneration: !isBatch,
                unloadAfterIdleSeconds: 120
            )
        case .mid16GBMac:
            return NativeMemoryPolicy(
                name: "mid_16gb_mac_\(mode.rawValue)_\(isBatch ? "batch" : "single")",
                deviceClass: deviceClass,
                cacheLimitBytes: 512 * 1_024 * 1_024,
                clearCacheAfterGeneration: false,
                unloadAfterIdleSeconds: 300
            )
        case .highMemoryMac:
            return NativeMemoryPolicy(
                name: "high_memory_mac_\(mode.rawValue)_\(isBatch ? "batch" : "single")",
                deviceClass: deviceClass,
                cacheLimitBytes: 1_024 * 1_024 * 1_024,
                clearCacheAfterGeneration: false,
                unloadAfterIdleSeconds: nil
            )
        case .iPhonePro:
            return NativeMemoryPolicy(
                name: "iphone_pro_\(mode.rawValue)_\(isBatch ? "batch" : "single")",
                deviceClass: deviceClass,
                cacheLimitBytes: 128 * 1_024 * 1_024,
                clearCacheAfterGeneration: true,
                unloadAfterIdleSeconds: 30
            )
        }
    }

    public static func apply(_ policy: NativeMemoryPolicy) {
        Memory.cacheLimit = policy.cacheLimitBytes
        if let memoryLimitBytes = policy.memoryLimitBytes {
            Memory.memoryLimit = memoryLimitBytes
        }
    }

    public static func snapshot() -> NativeMLXMemorySnapshot {
        let snapshot = Memory.snapshot()
        return NativeMLXMemorySnapshot(
            activeMB: bytesToMB(snapshot.activeMemory),
            cacheMB: bytesToMB(snapshot.cacheMemory),
            peakMB: bytesToMB(snapshot.peakMemory)
        )
    }

    public static func resetPeakMemory() {
        Memory.peakMemory = 0
    }

    private static func bytesToMB(_ bytes: Int) -> Double {
        Double(bytes) / Double(1_024 * 1_024)
    }
}
