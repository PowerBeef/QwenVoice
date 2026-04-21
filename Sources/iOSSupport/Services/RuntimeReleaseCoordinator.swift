import Combine
import Foundation

@MainActor
enum RuntimeReleaseAction: Equatable {
    case none
    case deferred(reason: String)
    case execute(reason: String, wasDeferred: Bool)
}

/// Severity signaled alongside a cache-relief request. `warning` may be
/// deferred while a generation is active; `critical` must run immediately
/// because the generation itself may be the source of the pressure.
@MainActor
enum MemoryPressureSeverity: Equatable {
    case warning
    case critical
}

@MainActor
enum MemoryPressureReliefAction: Equatable {
    case none
    case deferred(reason: String)
    case execute(reason: String, cancelActiveGeneration: Bool)
}

@MainActor
final class RuntimeReleaseCoordinator: ObservableObject {
    @Published private(set) var pendingReason: String?
    @Published private(set) var pendingCacheReliefReason: String?
    @Published private(set) var isReleaseInFlight = false

    func requestRelease(reason: String, hasActiveGeneration: Bool) -> RuntimeReleaseAction {
        if hasActiveGeneration || isReleaseInFlight {
            pendingReason = reason
            return .deferred(reason: reason)
        }

        isReleaseInFlight = true
        return .execute(reason: reason, wasDeferred: false)
    }

    func executeDeferredReleaseIfReady(hasActiveGeneration: Bool) -> RuntimeReleaseAction {
        guard !hasActiveGeneration, !isReleaseInFlight, let pendingReason else {
            return .none
        }

        self.pendingReason = nil
        isReleaseInFlight = true
        return .execute(reason: pendingReason, wasDeferred: true)
    }

    func completeRelease(hasActiveGeneration: Bool) -> RuntimeReleaseAction {
        isReleaseInFlight = false
        return executeDeferredReleaseIfReady(hasActiveGeneration: hasActiveGeneration)
    }

    func requestCacheRelief(
        reason: String,
        severity: MemoryPressureSeverity = .warning,
        hasActiveGeneration: Bool
    ) -> MemoryPressureReliefAction {
        switch severity {
        case .critical:
            // Critical pressure cannot wait for generation to finish — the
            // generation is frequently the cause. Clear any pending deferred
            // relief and run the trim path immediately, requesting that the
            // active generation be cancelled in the same step (Tier 1.6).
            pendingCacheReliefReason = nil
            return .execute(
                reason: reason,
                cancelActiveGeneration: hasActiveGeneration
            )
        case .warning:
            if hasActiveGeneration {
                pendingCacheReliefReason = reason
                return .deferred(reason: reason)
            }
            return .execute(reason: reason, cancelActiveGeneration: false)
        }
    }

    func executeDeferredCacheReliefIfReady(
        hasActiveGeneration: Bool
    ) -> MemoryPressureReliefAction {
        guard !hasActiveGeneration, let pendingCacheReliefReason else {
            return .none
        }

        self.pendingCacheReliefReason = nil
        return .execute(reason: pendingCacheReliefReason, cancelActiveGeneration: false)
    }
}
