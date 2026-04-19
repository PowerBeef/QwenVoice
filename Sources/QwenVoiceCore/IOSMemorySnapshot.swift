import Darwin
import Foundation
import Metal

public enum IOSMemoryPressureBand: String, Codable, Hashable, Sendable {
    case healthy
    case guarded
    case critical
}

public enum NativeMemoryTrimLevel: String, Codable, Hashable, Sendable {
    case softTrim
    case hardTrim
    case fullUnload
}

public struct IOSMemorySnapshot: Hashable, Codable, Sendable {
    public let totalDeviceRAMBytes: UInt64
    public let availableHeadroomBytes: UInt64?
    public let residentBytes: UInt64?
    public let physFootprintBytes: UInt64?
    public let compressedBytes: UInt64?
    public let gpuAllocatedBytes: UInt64?
    public let gpuRecommendedWorkingSetBytes: UInt64?
    public let hasUnifiedMemory: Bool?

    public init(
        totalDeviceRAMBytes: UInt64,
        availableHeadroomBytes: UInt64?,
        residentBytes: UInt64?,
        physFootprintBytes: UInt64?,
        compressedBytes: UInt64?,
        gpuAllocatedBytes: UInt64?,
        gpuRecommendedWorkingSetBytes: UInt64?,
        hasUnifiedMemory: Bool?
    ) {
        self.totalDeviceRAMBytes = totalDeviceRAMBytes
        self.availableHeadroomBytes = availableHeadroomBytes
        self.residentBytes = residentBytes
        self.physFootprintBytes = physFootprintBytes
        self.compressedBytes = compressedBytes
        self.gpuAllocatedBytes = gpuAllocatedBytes
        self.gpuRecommendedWorkingSetBytes = gpuRecommendedWorkingSetBytes
        self.hasUnifiedMemory = hasUnifiedMemory
    }

    public var residentMB: Double? {
        Self.bytesToMB(residentBytes)
    }

    public var physFootprintMB: Double? {
        Self.bytesToMB(physFootprintBytes)
    }

    public var compressedMB: Double? {
        Self.bytesToMB(compressedBytes)
    }

    public var availableHeadroomMB: Double? {
        Self.bytesToMB(availableHeadroomBytes)
    }

    public var gpuAllocatedMB: Double? {
        Self.bytesToMB(gpuAllocatedBytes)
    }

    public var gpuRecommendedWorkingSetMB: Double? {
        Self.bytesToMB(gpuRecommendedWorkingSetBytes)
    }

    public static func capture(device: MTLDevice? = MTLCreateSystemDefaultDevice()) -> IOSMemorySnapshot {
        let metrics = taskMemoryMetrics()
        return IOSMemorySnapshot(
            totalDeviceRAMBytes: ProcessInfo.processInfo.physicalMemory,
            availableHeadroomBytes: availableProcessMemory(),
            residentBytes: metrics.residentBytes,
            physFootprintBytes: metrics.physFootprintBytes,
            compressedBytes: metrics.compressedBytes,
            gpuAllocatedBytes: device.map { UInt64($0.currentAllocatedSize) },
            gpuRecommendedWorkingSetBytes: device.map { $0.recommendedMaxWorkingSetSize },
            hasUnifiedMemory: device?.hasUnifiedMemory
        )
    }

    private static func taskMemoryMetrics() -> (
        residentBytes: UInt64?,
        physFootprintBytes: UInt64?,
        compressedBytes: UInt64?
    ) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integerPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    integerPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return (nil, nil, nil)
        }

        return (
            residentBytes: info.resident_size,
            physFootprintBytes: info.phys_footprint,
            compressedBytes: info.compressed
        )
    }

    private static func availableProcessMemory() -> UInt64? {
        var headroom: UInt64 = 0
        guard QVoiceGetOSProcAvailableMemory(&headroom) else {
            return nil
        }
#if targetEnvironment(simulator)
        guard headroom > 0 else {
            return nil
        }
#endif
        return headroom
    }

    private static func bytesToMB(_ bytes: UInt64?) -> Double? {
        guard let bytes else { return nil }
        return Double(bytes) / 1_048_576
    }
}

public struct IOSMemoryBudgetPolicy: Hashable, Codable, Sendable {
    public let healthyHeadroomBytes: UInt64
    public let guardedHeadroomBytes: UInt64
    public let criticalGPUWorkingSetUsageRatio: Double

    public init(
        healthyHeadroomBytes: UInt64,
        guardedHeadroomBytes: UInt64,
        criticalGPUWorkingSetUsageRatio: Double
    ) {
        self.healthyHeadroomBytes = healthyHeadroomBytes
        self.guardedHeadroomBytes = guardedHeadroomBytes
        self.criticalGPUWorkingSetUsageRatio = criticalGPUWorkingSetUsageRatio
    }

    public static let iPhoneShippingDefault = IOSMemoryBudgetPolicy(
        healthyHeadroomBytes: 768 * 1_048_576,
        guardedHeadroomBytes: 384 * 1_048_576,
        criticalGPUWorkingSetUsageRatio: 0.80
    )

    public func band(for snapshot: IOSMemorySnapshot) -> IOSMemoryPressureBand {
        if let gpuAllocated = snapshot.gpuAllocatedBytes,
           let gpuRecommendedWorkingSet = snapshot.gpuRecommendedWorkingSetBytes,
           gpuRecommendedWorkingSet > 0,
           Double(gpuAllocated) / Double(gpuRecommendedWorkingSet) >= criticalGPUWorkingSetUsageRatio {
            return .critical
        }

        guard let headroom = snapshot.availableHeadroomBytes else {
            return .healthy
        }

        if headroom < guardedHeadroomBytes {
            return .critical
        }
        if headroom < healthyHeadroomBytes {
            return .guarded
        }
        return .healthy
    }

    public func allowsProactiveWarmOperations(for band: IOSMemoryPressureBand) -> Bool {
        band == .healthy
    }

    public func allowsModelAdmission(for band: IOSMemoryPressureBand) -> Bool {
        band != .critical
    }

    public func postGenerationTrimLevel(for band: IOSMemoryPressureBand) -> NativeMemoryTrimLevel? {
        switch band {
        case .healthy:
            return nil
        case .guarded:
            return .hardTrim
        case .critical:
            return .fullUnload
        }
    }

    public func trimLevelForPressureEvent(
        snapshot: IOSMemorySnapshot,
        isBackgroundTransition: Bool
    ) -> NativeMemoryTrimLevel {
        if isBackgroundTransition {
            return .fullUnload
        }

        switch band(for: snapshot) {
        case .healthy:
            return .softTrim
        case .guarded:
            return .hardTrim
        case .critical:
            return .fullUnload
        }
    }
}
