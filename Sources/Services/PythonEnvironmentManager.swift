import CryptoKit
import Foundation

/// Manages the Python virtual environment lifecycle: check, create, install dependencies, validate.
@MainActor
final class PythonEnvironmentManager: ObservableObject {

    // MARK: - State

    enum State: Equatable {
        case idle
        case checking
        case settingUp(SetupPhase)
        case ready(pythonPath: String)
        case failed(message: String)
    }

    enum SetupPhase: Equatable {
        case findingPython
        case creatingVenv
        case installingDependencies(installed: Int, total: Int)
        case updatingDependencies
    }

    @Published private(set) var state: State = .idle
    @Published var needsBackendRestart = false
    private var setupTask: Task<Void, Never>?
    private var setupTaskID: UUID?
    private let discovery = PythonRuntimeDiscovery()
    private lazy var validator = PythonRuntimeValidator(discovery: discovery)
    private lazy var installer = RequirementsInstaller(discovery: discovery)
    private lazy var provisioner = PythonRuntimeProvisioner(
        discovery: discovery,
        validator: validator,
        installer: installer
    )
    private let stateMachine = EnvironmentSetupStateMachine()

    // MARK: - Paths

    // MARK: - Init

    init() {}

    // MARK: - Public

    func ensureEnvironment() {
        guard Self.shouldStartSetupTask(for: state, hasInFlightTask: setupTask != nil) else {
            return
        }

        switch stateMachine.launchAction(
            machineIdentifier: discovery.machineIdentifier(),
            bundledPythonPath: discovery.bundledPythonPath(),
            bundledRuntimeExists: discovery.bundledRuntimeExists(),
            isStubBackendMode: UITestAutomationSupport.isStubBackendMode,
            uiTestLiveOverridePythonPath: discovery.uiTestLiveOverridePythonPath(),
            venvPythonPath: discovery.venvPythonPath,
            isMarkerValid: discovery.isMarkerValid()
        ) {
        case .fail(let message):
            state = .failed(message: message)
        case .validateBundled(let bundledPython):
            state = .checking
            launchSetupTask { [weak self] in
                await self?.validateBundledRuntimeAndUpdateState(bundledPython)
            }
        case .runStub:
            state = .checking
            launchSetupTask { [weak self] in
                await self?.runStubSetup()
            }
        case .validateUITestRuntime(let uiTestLivePython):
            state = .checking
            launchSetupTask { [weak self] in
                await self?.validateUITestRuntimeAndUpdateState(uiTestLivePython)
            }
        case .ready(let pythonPath):
            state = .ready(pythonPath: pythonPath)
        case .runSlowPath:
            state = .checking
            launchSetupTask { [weak self] in
                await self?.runSetupSlowPath()
            }
        }
    }

    func retry() {
        ensureEnvironment()
    }

    func resetEnvironment() {
        if UITestAutomationSupport.isStubBackendMode {
            needsBackendRestart = true
            state = .idle
            setupTask = nil
            setupTaskID = nil
            ensureEnvironment()
            return
        }

        if let bundledPython = discovery.bundledPythonPath() {
            needsBackendRestart = true
            if case .ready(let pythonPath) = state, pythonPath == bundledPython {
                return
            }
            state = .checking
            setupTask = nil
            setupTaskID = nil
            launchSetupTask { [weak self] in
                await self?.validateBundledRuntimeAndUpdateState(bundledPython)
            }
            return
        }

        if discovery.fileManager.fileExists(atPath: discovery.venvDir.path) {
            try? discovery.fileManager.removeItem(at: discovery.venvDir)
        }
        needsBackendRestart = true
        state = .idle
        setupTask = nil
        setupTaskID = nil
        ensureEnvironment()
    }

    nonisolated static func shouldStartSetupTask(for state: State, hasInFlightTask: Bool) -> Bool {
        EnvironmentSetupStateMachine.shouldStartSetupTask(
            for: state,
            hasInFlightTask: hasInFlightTask
        )
    }

    // MARK: - Setup Logic

    private func runSetupSlowPath() async {
        let outcome = await provisioner.runSlowPath { [weak self] newState in
            self?.state = newState
        }

        switch outcome {
        case .ready(let pythonPath):
            await MainActor.run { state = .ready(pythonPath: pythonPath) }
        case .failed(let message):
            await MainActor.run { state = .failed(message: message) }
        }
    }

    private func launchSetupTask(_ operation: @escaping @Sendable () async -> Void) {
        let taskID = UUID()
        let task = Task.detached(priority: .userInitiated) {
            await operation()
        }
        setupTask = task
        setupTaskID = taskID

        Task { [weak self] in
            _ = await task.result
            guard let self else { return }
            self.completeSetupTaskIfCurrent(taskID)
        }
    }

    private func runStubSetup() async {
        let delay = UITestAutomationSupport.setupDelayNanoseconds

        await MainActor.run {
            self.state = .settingUp(.findingPython)
        }
        try? await Task.sleep(nanoseconds: delay)

        await MainActor.run {
            self.state = .settingUp(.creatingVenv)
        }
        try? await Task.sleep(nanoseconds: delay)

        await MainActor.run {
            self.state = .settingUp(.installingDependencies(installed: 1, total: 3))
        }
        try? await Task.sleep(nanoseconds: delay)

        await MainActor.run {
            self.state = .settingUp(.installingDependencies(installed: 2, total: 3))
        }
        try? await Task.sleep(nanoseconds: delay)

        await MainActor.run {
            self.state = .settingUp(.updatingDependencies)
        }
        try? await Task.sleep(nanoseconds: delay)

        if UITestAutomationSupport.setupScenario == .failOnce,
           UITestAutomationSupport.consumeFailOnceFlag(
                namespace: "setup-fail",
                appSupportDir: discovery.appSupportDir
           ) {
            await MainActor.run {
                self.state = .failed(message: "Simulated setup failure for UI automation.")
            }
            return
        }

        await MainActor.run {
            self.state = .ready(pythonPath: UITestAutomationSupport.stubPythonPath())
        }
    }

    private func validateUITestRuntimeAndUpdateState(_ pythonPath: String) async {
        do {
            try await validator.validateImports(pythonPath: pythonPath)
            await MainActor.run {
                self.state = .ready(pythonPath: pythonPath)
            }
        } catch {
            await MainActor.run {
                self.state = .failed(
                    message: "The UI test runtime override is present but failed validation.\n\n\(error.localizedDescription)\n\nQwenVoice will not reinstall dependencies automatically when launched with an overridden UI test app-support root."
                )
            }
        }
    }

    private func completeSetupTaskIfCurrent(_ taskID: UUID) {
        guard setupTaskID == taskID else { return }
        setupTask = nil
        setupTaskID = nil
    }

    private func validateBundledRuntime(_ pythonPath: String) async throws {
        try await validator.validateBundledRuntime(pythonPath: pythonPath)
    }

    private func validateBundledRuntimeAndUpdateState(_ pythonPath: String) async {
        do {
            try await validateBundledRuntime(pythonPath)
            await MainActor.run {
                self.state = .ready(pythonPath: pythonPath)
            }
        } catch {
            await MainActor.run {
                self.state = .failed(
                    message: "The bundled Python runtime is present but failed validation.\n\n\(error.localizedDescription)\n\nThis is a packaging issue (often an MLX runtime built for a newer macOS). Reinstall the app or use a new release build."
                )
            }
        }
    }

    // MARK: - Error

    enum SetupError: LocalizedError {
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let msg): return msg
            }
        }
    }
}
