import ExtensionFoundation
import Foundation
import Observation
import QwenVoiceCore

extension AppExtensionPoint {
    @Definition
    static var vocelloEngineService: AppExtensionPoint {
        Name("vocello-engine-service")
        Scope(restriction: .application)
        UserInterface(false)
        EnhancedSecurity(true)
    }
}

enum VocelloEngineIdentityResolverError: LocalizedError {
    case noAvailableExtension

    var errorDescription: String? {
        switch self {
        case .noAvailableExtension:
            return "Vocello couldn't find its bundled engine extension. Reinstall the app or rebuild the iPhone targets."
        }
    }
}

@MainActor
private final class VocelloEngineMonitorProvider {
    private let expectedBundleIdentifier: String
    private var monitor: AppExtensionPoint.Monitor?
    private var observationTask: Task<Void, Never>?
    private var subscribers: [UUID: @Sendable ([ExtensionEngineHostCandidate<AppExtensionIdentity>]) async -> Void] = [:]

    init(expectedBundleIdentifier: String) {
        self.expectedBundleIdentifier = expectedBundleIdentifier
    }

    func candidates() async throws -> [ExtensionEngineHostCandidate<AppExtensionIdentity>] {
        let monitor = try await ensureMonitor()
        let identities = monitor.identities
        guard !identities.isEmpty else {
            throw VocelloEngineIdentityResolverError.noAvailableExtension
        }

        let sorted = identities.sorted { lhs, rhs in
            if lhs.bundleIdentifier == expectedBundleIdentifier {
                return true
            }
            if rhs.bundleIdentifier == expectedBundleIdentifier {
                return false
            }
            return lhs.bundleIdentifier < rhs.bundleIdentifier
        }

        return sorted.map {
            ExtensionEngineHostCandidate(
                bundleIdentifier: $0.bundleIdentifier,
                identity: $0
            )
        }
    }

    func registerCandidateObserver(
        _ onCandidatesChanged: @escaping @Sendable ([ExtensionEngineHostCandidate<AppExtensionIdentity>]) async -> Void
    ) async throws {
        _ = try await ensureMonitor()
        let token = UUID()
        subscribers[token] = onCandidatesChanged
        startObservationIfNeeded()

        let snapshot = try await candidates()
        Task {
            await onCandidatesChanged(snapshot)
        }
    }

    private func ensureMonitor() async throws -> AppExtensionPoint.Monitor {
        if let monitor {
            return monitor
        }
        let resolvedMonitor = try await AppExtensionPoint.Monitor(
            appExtensionPoint: AppExtensionPoint.vocelloEngineService
        )
        monitor = resolvedMonitor
        return resolvedMonitor
    }

    private func startObservationIfNeeded() {
        guard observationTask == nil, let monitor else { return }

        observationTask = Task { [weak self, monitor] in
            let updates = Observations { monitor.identities }
            for await _ in updates {
                guard let self else { return }
                let snapshot = (try? await self.candidates()) ?? []
                await self.notifySubscribers(snapshot)
            }
        }
    }

    private func notifySubscribers(
        _ candidates: [ExtensionEngineHostCandidate<AppExtensionIdentity>]
    ) async {
        let callbacks = Array(subscribers.values)
        for callback in callbacks {
            await callback(candidates)
        }
    }
}

@MainActor
enum VocelloEngineHostManager {
    private static let expectedBundleIdentifier = "com.qvoice.ios.engine-extension"
    private static let monitorProvider = VocelloEngineMonitorProvider(
        expectedBundleIdentifier: expectedBundleIdentifier
    )

    static let shared: ExtensionEngineHostManager<AppExtensionIdentity> = {
        let manager = ExtensionEngineHostManager<AppExtensionIdentity>(
            expectedBundleIdentifier: expectedBundleIdentifier,
            candidateProvider: {
                try await monitorProvider.candidates()
            },
            transportFactory: { identity, handlers in
                try await AppExtensionProcessTransport(
                    identity: identity,
                    handlers: handlers
                )
            }
        )

        Task { @MainActor in
            try? await monitorProvider.registerCandidateObserver { candidates in
                await manager.handleAvailableCandidatesChanged(candidates)
            }
        }

        return manager
    }()
}
