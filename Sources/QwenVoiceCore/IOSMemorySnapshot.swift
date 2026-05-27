import Darwin
import Foundation
import Metal

public enum IOSMemoryPressureBand: String, Codable, Hashable, Sendable {
    case healthy
    case guarded
    case critical

    public var severityRank: Int {
        switch self {
        case .healthy:
            return 0
        case .guarded:
            return 1
        case .critical:
            return 2
        }
    }
}

public enum NativeMemoryTrimLevel: String, Codable, Hashable, Sendable {
    case softTrim
    case hardTrim
    case fullUnload
}

public enum IOSMemoryProcessRole: String, Codable, Hashable, Sendable {
    case app
    case engineExtension
    case simulator
    case currentProcess
}

public struct IOSMemorySnapshot: Hashable, Codable, Sendable {
    public let processRole: IOSMemoryProcessRole
    public let pid: Int32
    public let capturedAtUptimeSeconds: Double
    public let totalDeviceRAMBytes: UInt64
    public let availableHeadroomBytes: UInt64?
    public let residentBytes: UInt64?
    public let physFootprintBytes: UInt64?
    public let compressedBytes: UInt64?
    public let gpuAllocatedBytes: UInt64?
    public let gpuRecommendedWorkingSetBytes: UInt64?
    public let hasUnifiedMemory: Bool?

    public init(
        processRole: IOSMemoryProcessRole = .currentProcess,
        pid: Int32 = getpid(),
        capturedAtUptimeSeconds: Double = ProcessInfo.processInfo.systemUptime,
        totalDeviceRAMBytes: UInt64,
        availableHeadroomBytes: UInt64?,
        residentBytes: UInt64?,
        physFootprintBytes: UInt64?,
        compressedBytes: UInt64?,
        gpuAllocatedBytes: UInt64?,
        gpuRecommendedWorkingSetBytes: UInt64?,
        hasUnifiedMemory: Bool?
    ) {
        self.processRole = processRole
        self.pid = pid
        self.capturedAtUptimeSeconds = capturedAtUptimeSeconds
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

    public var impliedProcessLimitBytes: UInt64? {
        guard let physFootprintBytes, let availableHeadroomBytes else {
            return nil
        }
        return physFootprintBytes + availableHeadroomBytes
    }

    public var impliedProcessLimitMB: Double? {
        Self.bytesToMB(impliedProcessLimitBytes)
    }

    public var gpuAllocatedMB: Double? {
        Self.bytesToMB(gpuAllocatedBytes)
    }

    public var gpuRecommendedWorkingSetMB: Double? {
        Self.bytesToMB(gpuRecommendedWorkingSetBytes)
    }

    public static func capture(
        role: IOSMemoryProcessRole = .currentProcess,
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) -> IOSMemorySnapshot {
        let metrics = taskMemoryMetrics()
        return IOSMemorySnapshot(
            processRole: role,
            pid: getpid(),
            capturedAtUptimeSeconds: ProcessInfo.processInfo.systemUptime,
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

public struct IOSMemoryContext: Hashable, Codable, Sendable {
    public let appSnapshot: IOSMemorySnapshot
    public let engineExtensionSnapshot: IOSMemorySnapshot?
    public let pressureBand: IOSMemoryPressureBand
    public let aggregatePressureBand: IOSMemoryPressureBand
    public let worstProcessRole: IOSMemoryProcessRole?
    public let reason: String
    public let source: String

    public init(
        appSnapshot: IOSMemorySnapshot,
        engineExtensionSnapshot: IOSMemorySnapshot?,
        pressureBand: IOSMemoryPressureBand,
        aggregatePressureBand: IOSMemoryPressureBand = .healthy,
        worstProcessRole: IOSMemoryProcessRole?,
        reason: String,
        source: String
    ) {
        self.appSnapshot = appSnapshot
        self.engineExtensionSnapshot = engineExtensionSnapshot
        self.pressureBand = pressureBand
        self.aggregatePressureBand = aggregatePressureBand
        self.worstProcessRole = worstProcessRole
        self.reason = reason
        self.source = source
    }

    public var snapshots: [IOSMemorySnapshot] {
        if let engineExtensionSnapshot {
            return [appSnapshot, engineExtensionSnapshot]
        }
        return [appSnapshot]
    }

    public var minimumHeadroomBytes: UInt64? {
        snapshots.compactMap(\.availableHeadroomBytes).min()
    }

    public var peakPhysFootprintBytes: UInt64? {
        snapshots.compactMap(\.physFootprintBytes).max()
    }

    public var peakResidentBytes: UInt64? {
        snapshots.compactMap(\.residentBytes).max()
    }

    public var peakGPUAllocatedBytes: UInt64? {
        snapshots.compactMap(\.gpuAllocatedBytes).max()
    }

    public var combinedResidentBytes: UInt64? {
        sumKnown(\.residentBytes)
    }

    public var combinedPhysFootprintBytes: UInt64? {
        sumKnown(\.physFootprintBytes)
    }

    public var combinedCompressedBytes: UInt64? {
        sumKnown(\.compressedBytes)
    }

    public var combinedGPUAllocatedBytes: UInt64? {
        sumKnown(\.gpuAllocatedBytes)
    }

    private func sumKnown(_ keyPath: KeyPath<IOSMemorySnapshot, UInt64?>) -> UInt64? {
        let values = snapshots.compactMap { $0[keyPath: keyPath] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }
}

public struct IOSMemoryBudgetPolicy: Hashable, Codable, Sendable {
    public let healthyHeadroomBytes: UInt64
    public let guardedHeadroomBytes: UInt64
    public let criticalGPUWorkingSetUsageRatio: Double
    public let aggregateGuardedFootprintBytes: UInt64?
    public let aggregateCriticalFootprintBytes: UInt64?

    public init(
        healthyHeadroomBytes: UInt64,
        guardedHeadroomBytes: UInt64,
        criticalGPUWorkingSetUsageRatio: Double,
        aggregateGuardedFootprintBytes: UInt64? = nil,
        aggregateCriticalFootprintBytes: UInt64? = nil
    ) {
        self.healthyHeadroomBytes = healthyHeadroomBytes
        self.guardedHeadroomBytes = guardedHeadroomBytes
        self.criticalGPUWorkingSetUsageRatio = criticalGPUWorkingSetUsageRatio
        self.aggregateGuardedFootprintBytes = aggregateGuardedFootprintBytes
        self.aggregateCriticalFootprintBytes = aggregateCriticalFootprintBytes
    }

    public static let iPhoneShippingDefault = IOSMemoryBudgetPolicy(
        healthyHeadroomBytes: 768 * 1_048_576,
        guardedHeadroomBytes: 384 * 1_048_576,
        criticalGPUWorkingSetUsageRatio: 0.80,
        aggregateGuardedFootprintBytes: 4_500 * 1_048_576,
        aggregateCriticalFootprintBytes: 5_200 * 1_048_576
    )

    public func band(for snapshot: IOSMemorySnapshot) -> IOSMemoryPressureBand {
        if let gpuAllocated = snapshot.gpuAllocatedBytes,
           let gpuRecommendedWorkingSet = snapshot.gpuRecommendedWorkingSetBytes,
           gpuRecommendedWorkingSet > 0,
           Double(gpuAllocated) / Double(gpuRecommendedWorkingSet) >= criticalGPUWorkingSetUsageRatio {
            return .critical
        }

        guard let headroom = snapshot.availableHeadroomBytes ?? fallbackHeadroom(from: snapshot) else {
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

    public func context(
        appSnapshot: IOSMemorySnapshot,
        engineExtensionSnapshot: IOSMemorySnapshot?,
        reason: String,
        source: String
    ) -> IOSMemoryContext {
        let aggregateBand = aggregateBand(
            appSnapshot: appSnapshot,
            engineExtensionSnapshot: engineExtensionSnapshot
        )
        let candidates = [appSnapshot, engineExtensionSnapshot].compactMap { snapshot -> (
            snapshot: IOSMemorySnapshot,
            band: IOSMemoryPressureBand
        )? in
            guard let snapshot else { return nil }
            return (snapshot, band(for: snapshot))
        }
        let worst = candidates.max { lhs, rhs in
            if lhs.band.severityRank != rhs.band.severityRank {
                return lhs.band.severityRank < rhs.band.severityRank
            }
            return pressureTieBreakerScore(for: lhs.snapshot) < pressureTieBreakerScore(for: rhs.snapshot)
        }

        return IOSMemoryContext(
            appSnapshot: appSnapshot,
            engineExtensionSnapshot: engineExtensionSnapshot,
            pressureBand: maxBand(worst?.band ?? .healthy, aggregateBand),
            aggregatePressureBand: aggregateBand,
            worstProcessRole: worst?.snapshot.processRole,
            reason: reason,
            source: source
        )
    }

    public func aggregateBand(for context: IOSMemoryContext) -> IOSMemoryPressureBand {
        aggregateBand(
            appSnapshot: context.appSnapshot,
            engineExtensionSnapshot: context.engineExtensionSnapshot
        )
    }

    private func aggregateBand(
        appSnapshot: IOSMemorySnapshot,
        engineExtensionSnapshot: IOSMemorySnapshot?
    ) -> IOSMemoryPressureBand {
        let footprints = [appSnapshot, engineExtensionSnapshot].compactMap { snapshot in
            snapshot?.physFootprintBytes
        }
        guard !footprints.isEmpty else { return .healthy }
        let combinedFootprint = footprints.reduce(0, +)
        if let aggregateCriticalFootprintBytes,
           combinedFootprint >= aggregateCriticalFootprintBytes {
            return .critical
        }
        if let aggregateGuardedFootprintBytes,
           combinedFootprint >= aggregateGuardedFootprintBytes {
            return .guarded
        }
        return .healthy
    }

    private func fallbackHeadroom(from snapshot: IOSMemorySnapshot) -> UInt64? {
        let usedBytes = snapshot.physFootprintBytes ?? snapshot.residentBytes
        guard let usedBytes, snapshot.totalDeviceRAMBytes > usedBytes else {
            return nil
        }
        return snapshot.totalDeviceRAMBytes - usedBytes
    }

    private func pressureTieBreakerScore(for snapshot: IOSMemorySnapshot) -> UInt64 {
        if let headroom = snapshot.availableHeadroomBytes {
            return snapshot.totalDeviceRAMBytes > headroom
                ? snapshot.totalDeviceRAMBytes - headroom
                : 0
        }
        return snapshot.physFootprintBytes ?? snapshot.residentBytes ?? 0
    }

    public func allowsProactiveWarmOperations(for band: IOSMemoryPressureBand) -> Bool {
        band == .healthy
    }

    public func allowsModelAdmission(for band: IOSMemoryPressureBand) -> Bool {
        band != .critical
    }

    public func engineExecutionBand(
        for context: IOSMemoryContext,
        includesAggregatePressure: Bool = true
    ) -> IOSMemoryPressureBand {
        var executionBand = band(for: context.appSnapshot)
        if let engineExtensionSnapshot = context.engineExtensionSnapshot {
            executionBand = maxBand(executionBand, band(for: engineExtensionSnapshot))
        }
        if includesAggregatePressure {
            executionBand = maxBand(executionBand, aggregateBand(for: context))
        }
        return executionBand
    }

    public func allowsModelAdmission(for context: IOSMemoryContext) -> Bool {
        allowsModelAdmission(
            for: engineExecutionBand(for: context, includesAggregatePressure: false)
        )
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

    public func trimLevelForPressureEvent(
        context: IOSMemoryContext,
        isBackgroundTransition: Bool
    ) -> NativeMemoryTrimLevel {
        if isBackgroundTransition {
            return .fullUnload
        }

        switch context.pressureBand {
        case .healthy:
            return .softTrim
        case .guarded:
            return .hardTrim
        case .critical:
            return .fullUnload
        }
    }

    /// Extension process headroom is critically low while aggregate pressure is not —
    /// typical when the engine extension lacks Apple's increased-memory entitlement.
    /// Returns `nil` when the extension snapshot is missing.
    public func likelyEntitlementBlocked(for context: IOSMemoryContext) -> Bool? {
        guard let engineExtensionSnapshot = context.engineExtensionSnapshot else {
            return nil
        }
        guard context.aggregatePressureBand != .critical else {
            return false
        }
        guard band(for: engineExtensionSnapshot) == .critical,
              let headroom = engineExtensionSnapshot.availableHeadroomBytes,
              headroom < guardedHeadroomBytes else {
            return false
        }
        return true
    }

    /// User-visible copy when `guardModelAdmission` blocks model load.
    public func modelAdmissionBlockMessage(
        for context: IOSMemoryContext,
        perProcessAdmissionBand: IOSMemoryPressureBand,
        allowsAggregateGuardedAdmission: Bool
    ) -> String {
        if context.aggregatePressureBand == .critical {
            return "Close other apps — Vocello is critically low on combined memory with the voice engine."
        }
        if context.aggregatePressureBand == .guarded, !allowsAggregateGuardedAdmission {
            return "Close apps using memory in the background. Vocello needs more combined memory for the app and voice engine before loading this model."
        }
        if !allowsModelAdmission(for: perProcessAdmissionBand) {
            if likelyEntitlementBlocked(for: context) == true {
                return "On-device generation needs more memory headroom for the voice engine. Close background apps and try again."
            }
            return "Vocello needs more available memory before loading this model. Close background apps and try again."
        }
        return "Vocello needs more available memory before loading this model. Close background apps and try again."
    }

    private func maxBand(
        _ lhs: IOSMemoryPressureBand,
        _ rhs: IOSMemoryPressureBand
    ) -> IOSMemoryPressureBand {
        lhs.severityRank >= rhs.severityRank ? lhs : rhs
    }
}
