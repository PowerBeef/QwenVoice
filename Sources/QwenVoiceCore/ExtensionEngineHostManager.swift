import Foundation

public struct ExtensionEngineHostCandidate<Identity: Sendable>: Sendable {
    public let bundleIdentifier: String
    public let identity: Identity

    public init(bundleIdentifier: String, identity: Identity) {
        self.bundleIdentifier = bundleIdentifier
        self.identity = identity
    }
}

extension ExtensionEngineHostCandidate: Equatable where Identity: Equatable {}

public enum ExtensionEngineHostManagerError: LocalizedError, Equatable {
    case noAvailableExtension

    public var errorDescription: String? {
        switch self {
        case .noAvailableExtension:
            return "Vocello couldn't find an available engine extension."
        }
    }
}

public typealias ExtensionEngineHostCandidateProvider<Identity: Sendable> = @Sendable () async throws -> [ExtensionEngineHostCandidate<Identity>]
public typealias ExtensionEngineHostTransportFactory<Identity: Sendable> = @Sendable (Identity, ExtensionEngineTransportHandlers) async throws -> any ExtensionEngineTransporting

public actor ExtensionEngineHostManager<Identity: Sendable> {
    private struct ActiveTransport {
        let id: UUID
        let bundleIdentifier: String
        let transport: any ExtensionEngineTransporting
    }

    private let expectedBundleIdentifier: String
    private let candidateProvider: ExtensionEngineHostCandidateProvider<Identity>
    private let transportFactory: ExtensionEngineHostTransportFactory<Identity>
    private var activeTransport: ActiveTransport?

    public init(
        expectedBundleIdentifier: String,
        candidateProvider: @escaping ExtensionEngineHostCandidateProvider<Identity>,
        transportFactory: @escaping ExtensionEngineHostTransportFactory<Identity>
    ) {
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.candidateProvider = candidateProvider
        self.transportFactory = transportFactory
    }

    public func makeTransport(
        handlers: ExtensionEngineTransportHandlers
    ) async throws -> any ExtensionEngineTransporting {
        let candidate = try await resolveCandidate()
        let rawTransport = try await transportFactory(candidate.identity, handlers)
        let transportID = UUID()

        if let current = activeTransport {
            current.transport.invalidate()
        }

        activeTransport = ActiveTransport(
            id: transportID,
            bundleIdentifier: candidate.bundleIdentifier,
            transport: rawTransport
        )

        return ManagedExtensionEngineTransport(
            hostManager: self,
            transportID: transportID,
            wrappedTransport: rawTransport
        )
    }

    func invalidateTransport(id: UUID) {
        guard let current = activeTransport, current.id == id else { return }
        current.transport.invalidate()
        activeTransport = nil
    }

    public func activeTransportBundleIdentifier() -> String? {
        activeTransport?.bundleIdentifier
    }

    public func hasActiveTransport() -> Bool {
        activeTransport != nil
    }

    func handleAvailableCandidatesChanged(
        _ candidates: [ExtensionEngineHostCandidate<Identity>]
    ) {
        guard let current = activeTransport else { return }
        guard shouldInvalidateActiveTransport(
            currentBundleIdentifier: current.bundleIdentifier,
            candidates: candidates
        ) else {
            return
        }

        current.transport.invalidate()
        activeTransport = nil
    }

    private func resolveCandidate() async throws -> ExtensionEngineHostCandidate<Identity> {
        let candidates = try await candidateProvider()
        if let preferred = preferredCandidate(in: candidates) {
            return preferred
        }
        if let fallback = candidates.first {
            return fallback
        }
        throw ExtensionEngineHostManagerError.noAvailableExtension
    }

    private func preferredCandidate(
        in candidates: [ExtensionEngineHostCandidate<Identity>]
    ) -> ExtensionEngineHostCandidate<Identity>? {
        candidates.first(where: { $0.bundleIdentifier == expectedBundleIdentifier })
            ?? candidates.first
    }

    private func shouldInvalidateActiveTransport(
        currentBundleIdentifier: String,
        candidates: [ExtensionEngineHostCandidate<Identity>]
    ) -> Bool {
        guard let preferredCandidate = preferredCandidate(in: candidates) else {
            return true
        }

        if !candidates.contains(where: { $0.bundleIdentifier == currentBundleIdentifier }) {
            return true
        }

        return preferredCandidate.bundleIdentifier != currentBundleIdentifier
    }
}

private final class ManagedExtensionEngineTransport<Identity: Sendable>: ExtensionEngineTransporting, @unchecked Sendable {
    private let hostManager: ExtensionEngineHostManager<Identity>
    private let transportID: UUID
    private let wrappedTransport: any ExtensionEngineTransporting
    private let invalidationLock = NSLock()
    private var hasInvalidated = false

    init(
        hostManager: ExtensionEngineHostManager<Identity>,
        transportID: UUID,
        wrappedTransport: any ExtensionEngineTransporting
    ) {
        self.hostManager = hostManager
        self.transportID = transportID
        self.wrappedTransport = wrappedTransport
    }

    func resume() {
        wrappedTransport.resume()
    }

    func invalidate() {
        invalidationLock.lock()
        if hasInvalidated {
            invalidationLock.unlock()
            return
        }
        hasInvalidated = true
        invalidationLock.unlock()

        Task {
            await hostManager.invalidateTransport(id: transportID)
        }
    }

    func perform(_ payload: Data, reply: @escaping @Sendable (Data) -> Void) {
        wrappedTransport.perform(payload, reply: reply)
    }
}
