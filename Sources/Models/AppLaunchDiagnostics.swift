import Foundation

enum AppLaunchIssue: String, Equatable, Sendable {
    case invalidContract
    case missingBackend
    case missingPython
    case missingFFmpeg

    var summary: String {
        switch self {
        case .invalidContract:
            return "QwenVoice couldn't load its bundled model contract."
        case .missingBackend:
            return "QwenVoice couldn't locate its bundled Python backend."
        case .missingPython:
            return "QwenVoice couldn't locate its bundled Python runtime."
        case .missingFFmpeg:
            return "QwenVoice couldn't locate its bundled ffmpeg helper."
        }
    }
}

struct AppLaunchDiagnosticsSnapshot: Equatable, Sendable {
    let issue: AppLaunchIssue
    let manifestPath: String?
    let backendPath: String?
    let pythonPath: String?
    let ffmpegPath: String?
    let underlyingError: String

    var diagnosticsText: String {
        [
            issue.summary,
            "Manifest path: \(manifestPath ?? "not found")",
            "Backend path: \(backendPath ?? "not found")",
            "Python path: \(pythonPath ?? "not found")",
            "ffmpeg path: \(ffmpegPath ?? "not found")",
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

        let discovery = PythonRuntimeDiscovery()
        let manifestPath = TTSContract.manifestURL?.path ?? TTSContract.loadError?.manifestPath
        let backendPath = PythonBridge.findServerScript()
        let pythonPath = discovery.bundledPythonPath()
        let ffmpegPath = PythonBridge.findFFmpeg()

        if let loadError = TTSContract.loadError {
            return AppLaunchDiagnosticsSnapshot(
                issue: .invalidContract,
                manifestPath: manifestPath,
                backendPath: backendPath,
                pythonPath: pythonPath,
                ffmpegPath: ffmpegPath,
                underlyingError: "\(loadError.summary)\n\n\(loadError.details)"
            )
        }

        if backendPath == nil {
            return AppLaunchDiagnosticsSnapshot(
                issue: .missingBackend,
                manifestPath: manifestPath,
                backendPath: backendPath,
                pythonPath: pythonPath,
                ffmpegPath: ffmpegPath,
                underlyingError: "The bundled backend entrypoint `backend/server.py` could not be found."
            )
        }

        if pythonPath == nil {
            return AppLaunchDiagnosticsSnapshot(
                issue: .missingPython,
                manifestPath: manifestPath,
                backendPath: backendPath,
                pythonPath: pythonPath,
                ffmpegPath: ffmpegPath,
                underlyingError: "The bundled `python/bin/python3` executable could not be found."
            )
        }

        if ffmpegPath == nil {
            return AppLaunchDiagnosticsSnapshot(
                issue: .missingFFmpeg,
                manifestPath: manifestPath,
                backendPath: backendPath,
                pythonPath: pythonPath,
                ffmpegPath: ffmpegPath,
                underlyingError: "The bundled `ffmpeg` helper could not be found."
            )
        }

        return nil
    }
}
