import Foundation

@MainActor
final class AppStartupCoordinator {
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

    func syncUITestEnvironmentReadiness(
        state: PythonEnvironmentManager.State,
        pythonBridge: PythonBridge
    ) {
        guard UITestAutomationSupport.isEnabled else { return }

        let activePythonPath: String?
        if case .ready(let pythonPath) = state {
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
        if activePythonPath != nil {
            UITestWindowCoordinator.shared.scheduleRecoveryIfNeeded(reason: "environment_ready")
        }
    }

    private func bundledRuntimeRoot() -> String? {
        Bundle.main.resourceURL?
            .appendingPathComponent("python", isDirectory: true)
            .path
    }
}
