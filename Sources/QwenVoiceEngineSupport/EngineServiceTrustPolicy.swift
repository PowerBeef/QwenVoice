import Foundation

public enum EngineServiceTrustPolicy {
    public static let appBundleIdentifier = "com.qwenvoice.app"

    public static func codeSigningRequirement(
        bundleIdentifier: String = QwenVoiceEngineServiceBundleIdentifier
    ) -> String {
        serviceRequirement(bundleIdentifier: bundleIdentifier)
    }

    public static func serviceRequirement(
        bundleIdentifier: String = QwenVoiceEngineServiceBundleIdentifier,
        teamIdentifier: String? = nil
    ) -> String {
        requirement(
            forAllowedBundleIdentifiers: [bundleIdentifier],
            teamIdentifier: teamIdentifier
        )
    }

    public static func clientRequirement(teamIdentifier: String? = nil) -> String {
        #if QW_TEST_SUPPORT
        return clientRequirement(
            environment: ProcessInfo.processInfo.environment,
            teamIdentifier: teamIdentifier
        )
        #else
        return requirement(
            forAllowedBundleIdentifiers: [appBundleIdentifier],
            teamIdentifier: teamIdentifier
        )
        #endif
    }

    #if QW_TEST_SUPPORT
    public static func clientRequirement(
        environment: [String: String],
        teamIdentifier: String? = nil
    ) -> String {
        let normalizedTeamIdentifier = normalizedTeamIdentifier(teamIdentifier)
        let allowedBundleIdentifiers: [String]
        if normalizedTeamIdentifier == nil, isXCTestEnvironment(environment) {
            allowedBundleIdentifiers = [
                appBundleIdentifier,
                "com.qwenvoice.tests",
                "com.apple.dt.xctest.tool",
            ]
        } else {
            allowedBundleIdentifiers = [appBundleIdentifier]
        }

        return requirement(
            forAllowedBundleIdentifiers: allowedBundleIdentifiers,
            teamIdentifier: normalizedTeamIdentifier
        )
    }
    #endif

    private static func requirement(
        forAllowedBundleIdentifiers bundleIdentifiers: [String],
        teamIdentifier: String?
    ) -> String {
        let identifierClause = bundleIdentifiers
            .map { identifier in
                "identifier \"\(escape(identifier))\""
            }
            .joined(separator: " or ")

        let scopedIdentifierClause: String
        if bundleIdentifiers.count > 1 {
            scopedIdentifierClause = "(\(identifierClause))"
        } else {
            scopedIdentifierClause = identifierClause
        }

        guard let teamIdentifier = normalizedTeamIdentifier(teamIdentifier) else {
            return scopedIdentifierClause
        }

        return "\(scopedIdentifierClause) and certificate leaf[subject.OU] = \"\(escape(teamIdentifier))\""
    }

    private static func normalizedTeamIdentifier(_ teamIdentifier: String?) -> String? {
        guard let teamIdentifier = teamIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !teamIdentifier.isEmpty else {
            return nil
        }
        return teamIdentifier
    }

    #if QW_TEST_SUPPORT
    private static func isXCTestEnvironment(_ environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }
    #endif

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
