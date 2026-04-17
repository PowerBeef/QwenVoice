import Foundation
import QwenVoiceNative

@MainActor
final class AppStartupCoordinator: ObservableObject {
    @Published private(set) var launchDiagnostics: AppLaunchDiagnosticsSnapshot?

    func setupAppSupport() {
        let fm = FileManager.default
        let outputSubdirectories = Set(TTSModel.all.map(\.outputSubfolder))

        let dirs = [
            QwenVoiceApp.appSupportDir.path,
            QwenVoiceApp.appSupportDir.appendingPathComponent("models").path,
            QwenVoiceApp.appSupportDir.appendingPathComponent("outputs").path,
            QwenVoiceApp.appSupportDir.appendingPathComponent("voices").path,
            QwenVoiceApp.appSupportDir.appendingPathComponent("cache").path,
            QwenVoiceApp.appSupportDir.appendingPathComponent("cache/stream_sessions").path,
        ] + outputSubdirectories.sorted().map {
            QwenVoiceApp.appSupportDir.appendingPathComponent("outputs/\($0)").path
        }

        for dir in dirs {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    func refreshLaunchDiagnostics() {
        launchDiagnostics = AppLaunchPreflight.run()
    }

    func clearLaunchDiagnostics() {
        launchDiagnostics = nil
    }

    func syncUITestRuntimeReadiness(
        appEngineSelection: AppEngineSelection,
        environmentState: PythonEnvironmentManager.State,
        pythonBridge: PythonBridge,
        ttsEngineSnapshot: TTSEngineSnapshot
    ) {
        guard UITestAutomationSupport.isEnabled else { return }

        switch appEngineSelection.effectiveSelection(
            isStubBackendMode: UITestAutomationSupport.isStubBackendMode
        ) {
        case .native:
            TestStateProvider.shared.setRuntimeStatus(
                source: UITestAutomationSupport.isStubBackendMode ? .stub : .native,
                pythonPath: nil,
                ffmpegPath: nil
            )
            TestStateProvider.shared.setEnvironmentReady(true)
            TestStateProvider.shared.setBackendReady(ttsEngineSnapshot.isReady)
            TestStateProvider.shared.setBackendLastError(ttsEngineSnapshot.visibleErrorMessage)
            if ttsEngineSnapshot.isReady {
                UITestWindowCoordinator.shared.scheduleRecoveryIfNeeded(reason: "engine_ready")
            }
        case .python:
            let activePythonPath: String?
            if case .ready(let pythonPath) = environmentState {
                activePythonPath = pythonPath
            } else {
                activePythonPath = nil
            }

            let runtimeSource = TestStateProvider.runtimeSource(
                for: activePythonPath,
                bundledRuntimeRoot: bundledRuntimeRoot(),
                devVenvRoot: AppPaths.pythonVenvDir.path,
                stubPythonPath: UITestAutomationSupport.stubPythonPath()
            )
            let activeFFmpegPath = PythonBridge.findFFmpeg()

            TestStateProvider.shared.setRuntimeStatus(
                source: runtimeSource,
                pythonPath: activePythonPath,
                ffmpegPath: activeFFmpegPath
            )
            TestStateProvider.shared.setEnvironmentReady(activePythonPath != nil)
            TestStateProvider.shared.setBackendReady(
                UITestAutomationSupport.isStubBackendMode || pythonBridge.isReady
            )
            TestStateProvider.shared.setBackendLastError(pythonBridge.lastError)
            if activePythonPath != nil {
                UITestWindowCoordinator.shared.scheduleRecoveryIfNeeded(reason: "environment_ready")
            }
        }
    }

    private func bundledRuntimeRoot() -> String? {
        Bundle.main.resourceURL?
            .appendingPathComponent("python", isDirectory: true)
            .path
    }
}
