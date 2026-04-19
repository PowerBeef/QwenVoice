import Combine
import Foundation

@MainActor
enum RuntimeReleaseAction: Equatable {
    case none
    case deferred(reason: String)
    case execute(reason: String, wasDeferred: Bool)
}

@MainActor
enum MemoryPressureReliefAction: Equatable {
    case none
    case deferred(reason: String)
    case execute(reason: String)
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
        hasActiveGeneration: Bool
    ) -> MemoryPressureReliefAction {
        if hasActiveGeneration {
            pendingCacheReliefReason = reason
            return .deferred(reason: reason)
        }

        return .execute(reason: reason)
    }

    func executeDeferredCacheReliefIfReady(
        hasActiveGeneration: Bool
    ) -> MemoryPressureReliefAction {
        guard !hasActiveGeneration, let pendingCacheReliefReason else {
            return .none
        }

        self.pendingCacheReliefReason = nil
        return .execute(reason: pendingCacheReliefReason)
    }
}
