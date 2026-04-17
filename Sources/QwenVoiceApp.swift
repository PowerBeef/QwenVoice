import SwiftUI
import AppKit
import QwenVoiceNative

@main
struct QwenVoiceApp: App {
    @StateObject private var pythonBridge: PythonBridge
    @StateObject private var ttsEngineStore: TTSEngineStore
    @StateObject private var audioPlayer = AudioPlayerViewModel()
    @StateObject private var envManager = PythonEnvironmentManager()
    @StateObject private var modelManager = ModelManagerViewModel()
    @StateObject private var savedVoicesViewModel = SavedVoicesViewModel()
    @StateObject private var appCommandRouter = AppCommandRouter.shared
    @StateObject private var generationLibraryEvents = GenerationLibraryEvents.shared
    @StateObject private var appStartupCoordinator = AppStartupCoordinator()
    private let testStateServer = TestStateServer()
    private let backendLaunchCoordinator = BackendLaunchCoordinator()

    init() {
        let pythonBridge = PythonBridge()
        _pythonBridge = StateObject(wrappedValue: pythonBridge)
        _ttsEngineStore = StateObject(
            wrappedValue: TTSEngineStore(
                engine: PythonBridgeMacTTSEngineAdapter(bridge: pythonBridge)
            )
        )

        // Ignore SIGPIPE to prevent crashes when writing to a broken pipe
        // (e.g. Python backend terminates between isRunning check and write)
        signal(SIGPIPE, SIG_IGN)

        if let forcedAppearance = UITestAutomationSupport.forcedNSAppearance {
            NSApplication.shared.appearance = forcedAppearance
        }

        // In UI test mode, start the test state HTTP server and force activate.
        if AppLaunchConfiguration.current.isUITest {
            let windowCoordinator = UITestWindowCoordinator.shared
            testStateServer.start()
            windowCoordinator.start()
            DispatchQueue.main.async {
                Task { @MainActor in
                    _ = await windowCoordinator.activateMainWindow(reason: "launch_init")
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let launchDiagnostics = appStartupCoordinator.launchDiagnostics {
                    StartupDiagnosticsView(
                        snapshot: launchDiagnostics,
                        onRetry: retryLaunchPreflight
                    )
                    .frame(minWidth: 520, minHeight: 420)
                } else {
                    switch envManager.state {
                    case .ready(let pythonPath):
                        ContentView()
                            .environmentObject(pythonBridge)
                            .environmentObject(ttsEngineStore)
                            .environmentObject(audioPlayer)
                            .environmentObject(audioPlayer.playbackProgress)
                            .environmentObject(envManager)
                            .environmentObject(modelManager)
                            .environmentObject(savedVoicesViewModel)
                            .environmentObject(appCommandRouter)
                            .environmentObject(generationLibraryEvents)
                            .frame(minWidth: 720, minHeight: 560)
                            .onAppear {
                                appStartupCoordinator.syncUITestEnvironmentReadiness(
                                    state: .ready(pythonPath: pythonPath),
                                    pythonBridge: pythonBridge
                                )
                                backendLaunchCoordinator.startBackendIfNeeded(
                                    pythonBridge: pythonBridge,
                                    envManager: envManager,
                                    pythonPath: pythonPath,
                                    appSupportDir: Self.appSupportDir.path
                                )
                            }
                    case .idle:
                        SetupView(envManager: envManager)
                            .frame(minWidth: 500, minHeight: 400)
                    default:
                        SetupView(envManager: envManager)
                            .frame(minWidth: 500, minHeight: 400)
                    }
                }
            }
            .defaultAppStorage(UITestAutomationSupport.appStorage)
            .background(
                UITestWindowSizeConfigurator(
                    contentSize: AppLaunchConfiguration.current.uiTestWindowSize
                )
            )
            .onAppear {
                appStartupCoordinator.setupAppSupport()
                appStartupCoordinator.refreshLaunchDiagnostics()
                if UITestAutomationSupport.isEnabled {
                    UITestWindowCoordinator.shared.syncVisibleMainWindowState()
                    TestStateProvider.shared.setBackendReady(UITestAutomationSupport.isStubBackendMode)
                    TestStateProvider.shared.setBackendLastError(pythonBridge.lastError)
                }
                if appStartupCoordinator.launchDiagnostics == nil {
                    envManager.ensureEnvironment()
                    appStartupCoordinator.syncUITestEnvironmentReadiness(
                        state: envManager.state,
                        pythonBridge: pythonBridge
                    )
                }
                AppLaunchConfiguration.openSettingsWindowIfNeeded()
            }
            .onReceive(envManager.$state) { newState in
                guard appStartupCoordinator.launchDiagnostics == nil else { return }
                appStartupCoordinator.syncUITestEnvironmentReadiness(
                    state: newState,
                    pythonBridge: pythonBridge
                )
            }
            .onReceive(pythonBridge.$isReady) { isReady in
                guard UITestAutomationSupport.isEnabled else { return }
                TestStateProvider.shared.setBackendReady(UITestAutomationSupport.isStubBackendMode || isReady)
                if isReady {
                    UITestWindowCoordinator.shared.scheduleRecoveryIfNeeded(reason: "backend_ready")
                }
            }
            .onReceive(pythonBridge.$sidebarStatus) { status in
                guard UITestAutomationSupport.isEnabled else { return }
                TestStateProvider.shared.setSidebarStatus(status)
            }
            .onReceive(pythonBridge.$lastError) { lastError in
                guard UITestAutomationSupport.isEnabled else { return }
                TestStateProvider.shared.setBackendLastError(lastError)
            }
        }
        .defaultSize(width: 720, height: 560)
        Settings {
            PreferencesView()
                .environmentObject(envManager)
                .defaultAppStorage(UITestAutomationSupport.appStorage)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }

            // Playback commands
            CommandMenu("Playback") {
                Button("Play / Pause") {
                    audioPlayer.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!audioPlayer.hasAudio)

                Button("Stop") {
                    audioPlayer.dismiss()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!audioPlayer.hasAudio)
            }

            CommandMenu("Navigate") {
                Button("Custom Voice") {
                    appCommandRouter.navigate(to: .customVoice)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Voice Design") {
                    appCommandRouter.navigate(to: .voiceDesign)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Voice Cloning") {
                    appCommandRouter.navigate(to: .voiceCloning)
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("History") {
                    appCommandRouter.navigate(to: .history)
                }
                .keyboardShortcut("4", modifiers: .command)

                Button("Saved Voices") {
                    appCommandRouter.navigate(to: .voices)
                }
                .keyboardShortcut("5", modifiers: .command)

                Button("Models") {
                    appCommandRouter.navigate(to: .models)
                }
                .keyboardShortcut("6", modifiers: .command)
            }

            // File menu additions
            CommandGroup(after: .saveItem) {
                Divider()
                Button("Open Output Folder") {
                    NSWorkspace.shared.open(Self.outputsDir)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Reveal in Finder") {
                    if let path = audioPlayer.currentFilePath {
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(audioPlayer.currentFilePath == nil)
            }
        }
    }

    static var appSupportDir: URL {
        AppPaths.appSupportDir
    }

    static var modelsDir: URL { AppPaths.modelsDir }
    static var outputsDir: URL { AppPaths.outputsDir }
    static var voicesDir: URL { AppPaths.voicesDir }

    private func retryLaunchPreflight() {
        appStartupCoordinator.refreshLaunchDiagnostics()
        guard appStartupCoordinator.launchDiagnostics == nil else { return }
        envManager.ensureEnvironment()
        appStartupCoordinator.syncUITestEnvironmentReadiness(
            state: envManager.state,
            pythonBridge: pythonBridge
        )
    }
}
