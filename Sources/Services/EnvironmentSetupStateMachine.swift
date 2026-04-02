import Foundation

struct EnvironmentSetupStateMachine {
    enum LaunchAction: Equatable {
        case fail(message: String)
        case validateBundled(String)
        case runStub
        case validateUITestRuntime(String)
        case ready(String)
        case runSlowPath
    }

    static func shouldStartSetupTask(
        for state: PythonEnvironmentManager.State,
        hasInFlightTask: Bool
    ) -> Bool {
        if case .ready = state {
            return false
        }

        guard hasInFlightTask else { return true }

        switch state {
        case .checking, .settingUp:
            return false
        case .idle, .ready, .failed:
            return true
        }
    }

    func launchAction(
        machineIdentifier: String,
        bundledPythonPath: String?,
        bundledRuntimeExists: Bool,
        isStubBackendMode: Bool,
        uiTestLiveOverridePythonPath: String?,
        venvPythonPath: String,
        isMarkerValid: Bool
    ) -> LaunchAction {
        guard machineIdentifier.starts(with: "arm64") else {
            return .fail(
                message: "QwenVoice requires an Apple Silicon Mac (M1 or later).\nThis Mac has a \(machineIdentifier) processor, which is not supported by the MLX framework."
            )
        }

        if let bundledPythonPath {
            return .validateBundled(bundledPythonPath)
        }

        if bundledRuntimeExists {
            return .fail(
                message: "The bundled Python runtime is present but could not be located.\n\nThis is a packaging issue. Reinstall the app or use a new release build."
            )
        }

        if isStubBackendMode {
            return .runStub
        }

        if let uiTestLiveOverridePythonPath {
            return .validateUITestRuntime(uiTestLiveOverridePythonPath)
        }

        if FileManager.default.fileExists(atPath: venvPythonPath),
           isMarkerValid {
            return .ready(venvPythonPath)
        }

        return .runSlowPath
    }
}
