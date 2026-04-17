import Foundation

enum AppLaunchIssue: String, Equatable, Sendable {
    case invalidContract

    var summary: String {
        switch self {
        case .invalidContract:
            return "QwenVoice couldn't load its native model contract."
        }
    }
}

struct AppLaunchDiagnosticsSnapshot: Equatable, Sendable {
    let issue: AppLaunchIssue
    let manifestPath: String?
    let bundlePath: String
    let resourcesPath: String?
    let underlyingError: String

    var diagnosticsText: String {
        [
            issue.summary,
            "Manifest path: \(manifestPath ?? "not found")",
            "Bundle path: \(bundlePath)",
            "Resources path: \(resourcesPath ?? "not found")",
            "Details: \(underlyingError)",
        ]
        .joined(separator: "\n")
    }
}

enum AppLaunchPreflight {
    static var shouldShowDiagnostics: Bool {
        shouldShowDiagnostics(
            isUITest: UITestAutomationSupport.isEnabled,
            bundlePath: Bundle.main.bundlePath
        )
    }

    static func shouldShowDiagnostics(isUITest: Bool, bundlePath: String) -> Bool {
        guard !isUITest else { return false }
        guard !bundlePath.contains("/DerivedData/") else { return false }
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    static func run() -> AppLaunchDiagnosticsSnapshot? {
        guard shouldShowDiagnostics else { return nil }

        let manifestPath = TTSContract.manifestURL?.path ?? TTSContract.loadError?.manifestPath
        let bundlePath = Bundle.main.bundlePath
        let resourcesPath = Bundle.main.resourceURL?.path

        if let loadError = TTSContract.loadError {
            return AppLaunchDiagnosticsSnapshot(
                issue: .invalidContract,
                manifestPath: manifestPath,
                bundlePath: bundlePath,
                resourcesPath: resourcesPath,
                underlyingError: "\(loadError.summary)\n\n\(loadError.details)"
            )
        }

        return nil
    }
}
