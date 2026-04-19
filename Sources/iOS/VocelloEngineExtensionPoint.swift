import ExtensionFoundation
import Foundation

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
enum VocelloEngineIdentityResolver {
    private static let expectedBundleIdentifier = "com.qvoice.ios.engine-extension"
    private static var monitor: AppExtensionPoint.Monitor?

    static func resolveIdentity() async throws -> AppExtensionIdentity {
        if let identity = currentIdentity {
            return identity
        }

        let newMonitor = try await AppExtensionPoint.Monitor(
            appExtensionPoint: AppExtensionPoint.vocelloEngineService
        )
        monitor = newMonitor

        if let identity = currentIdentity {
            return identity
        }

        throw VocelloEngineIdentityResolverError.noAvailableExtension
    }

    private static var currentIdentity: AppExtensionIdentity? {
        if let matchingIdentity = monitor?.identities.first(where: {
            $0.bundleIdentifier == expectedBundleIdentifier
        }) {
            return matchingIdentity
        }
        return monitor?.identities.first
    }
}
