import Foundation

@MainActor
final class BackendLaunchCoordinator {
    func startBackendIfNeeded(
        pythonBridge: PythonBridge,
        envManager: PythonEnvironmentManager,
        pythonPath: String,
        appSupportDir: String
    ) {
        if envManager.needsBackendRestart {
            pythonBridge.stop()
            envManager.needsBackendRestart = false
        }

        if UITestAutomationSupport.isStubBackendMode {
            guard !pythonBridge.isReady else { return }
            Task {
                do {
                    try await pythonBridge.initialize(appSupportDir: appSupportDir)
                } catch {
                    pythonBridge.lastError = "Backend initialization failed: \(error.localizedDescription)"
                }
            }
            return
        }

        guard !pythonBridge.isReady else { return }
        pythonBridge.start(pythonPath: pythonPath)
        Task {
            do {
                try await pythonBridge.initialize(appSupportDir: appSupportDir)
            } catch {
                pythonBridge.lastError = "Backend initialization failed: \(error.localizedDescription)"
            }
        }
    }
}
