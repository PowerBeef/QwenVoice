import Foundation

public enum EngineServiceTrustPolicy {
    public static let appBundleIdentifier = "com.qwenvoice.app"
    public static let testBundleIdentifier = "com.qwenvoice.tests"
    public static let xctestToolBundleIdentifier = "com.apple.dt.xctest.tool"

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

    public static func clientRequirement(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        teamIdentifier: String? = nil
    ) -> String {
        let bundleIdentifiers: [String]
        if isRunningUnderXCTest(environment: environment) {
            bundleIdentifiers = [
                appBundleIdentifier,
                testBundleIdentifier,
                xctestToolBundleIdentifier,
            ]
        } else {
            bundleIdentifiers = [appBundleIdentifier]
        }
        return requirement(
            forAllowedBundleIdentifiers: bundleIdentifiers,
            teamIdentifier: teamIdentifier
        )
    }

    public static func isRunningUnderXCTest(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }

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

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
