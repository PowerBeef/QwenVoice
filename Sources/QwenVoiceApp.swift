import SwiftUI
import AppKit
import QwenVoiceNative

@main
struct QwenVoiceApp: App {
    @NSApplicationDelegateAdaptor(QwenVoiceApplicationDelegate.self)
    private var appDelegate
    @StateObject private var pythonBridge: PythonBridge
    @StateObject private var ttsEngineStore: TTSEngineStore
    @State private var didInitializeSelectedTTSEngine = false
    @StateObject private var audioPlayer = AudioPlayerViewModel()
    @StateObject private var envManager = PythonEnvironmentManager()
    @StateObject private var modelManager = ModelManagerViewModel()
    @StateObject private var savedVoicesViewModel = SavedVoicesViewModel()
    @StateObject private var appCommandRouter = AppCommandRouter.shared
    @StateObject private var generationLibraryEvents = GenerationLibraryEvents.shared
    @StateObject private var appStartupCoordinator = AppStartupCoordinator()
    private let appEngineSelection: AppEngineSelection
    private let testStateServer = TestStateServer()
    private let backendLaunchCoordinator = BackendLaunchCoordinator()

    init() {
        let pythonBridge = PythonBridge()
        let appEngineSelection = AppEngineSelection.current()
        self.appEngineSelection = appEngineSelection
        _pythonBridge = StateObject(wrappedValue: pythonBridge)
        _ttsEngineStore = StateObject(
            wrappedValue: TTSEngineStore(
                engine: appEngineSelection.makeEngine(
                    pythonBridge: pythonBridge,
                    isStubBackendMode: UITestAutomationSupport.isStubBackendMode
                )
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
            if appEngineSelection.effectiveSelection(
                isStubBackendMode: UITestAutomationSupport.isStubBackendMode
            ) == .native {
                Task { @MainActor in
                    TestStateProvider.shared.setRuntimeStatus(
                        source: UITestAutomationSupport.isStubBackendMode ? .stub : .native,
                        pythonPath: nil,
                        ffmpegPath: nil
                    )
                    TestStateProvider.shared.setEnvironmentReady(true)
                    TestStateProvider.shared.setBackendReady(false)
                }
            }
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
                    switch bootstrapMode {
                    case .native:
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
                    case .python:
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
                                    syncUITestRuntimeState()
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
            }
            .defaultAppStorage(UITestAutomationSupport.appStorage)
            .background(
                UITestWindowSizeConfigurator(
                    contentSize: AppLaunchConfiguration.current.uiTestWindowSize
                )
            )
            .onAppear {
                appStartupCoordinator.setupAppSupport()
                startSelectedTTSEngineIfNeeded()
                appStartupCoordinator.refreshLaunchDiagnostics()
                if UITestAutomationSupport.isEnabled {
                    UITestWindowCoordinator.shared.syncVisibleMainWindowState()
                }
                syncUITestRuntimeState()
                if appStartupCoordinator.launchDiagnostics == nil, bootstrapMode == .python {
                    envManager.ensureEnvironment()
                    syncUITestRuntimeState()
                }
                AppLaunchConfiguration.openSettingsWindowIfNeeded()
            }
            .onReceive(envManager.$state) { _ in
                guard bootstrapMode == .python else { return }
                guard appStartupCoordinator.launchDiagnostics == nil else { return }
                syncUITestRuntimeState()
            }
            .onReceive(pythonBridge.$isReady) { _ in
                guard bootstrapMode == .python else { return }
                syncUITestRuntimeState()
            }
            .onReceive(pythonBridge.$sidebarStatus) { _ in
                syncUITestSidebarStatus()
            }
            .onReceive(ttsEngineStore.$snapshot) { _ in
                syncUITestRuntimeState()
                syncUITestSidebarStatus()
            }
            .onReceive(audioPlayer.$isLiveStream) { _ in
                syncUITestSidebarStatus()
            }
            .onReceive(pythonBridge.$lastError) { _ in
                guard bootstrapMode == .python else { return }
                syncUITestRuntimeState()
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

    private enum BootstrapMode {
        case native
        case python
    }

    private var bootstrapMode: BootstrapMode {
        appEngineSelection.effectiveSelection(
            isStubBackendMode: UITestAutomationSupport.isStubBackendMode
        ) == .python ? .python : .native
    }

    static var modelsDir: URL { AppPaths.modelsDir }
    static var outputsDir: URL { AppPaths.outputsDir }

    private func startSelectedTTSEngineIfNeeded() {
        guard appEngineSelection.requiresManualInitialization(
            isStubBackendMode: UITestAutomationSupport.isStubBackendMode
        ) else { return }
        guard !didInitializeSelectedTTSEngine else { return }
        didInitializeSelectedTTSEngine = true

        Task {
            do {
                try await ttsEngineStore.initialize(appSupportDirectory: Self.appSupportDir)
                await MainActor.run {
                    syncUITestRuntimeState()
                }
            } catch {
                // Native engine initialization publishes its own failure snapshot.
                await MainActor.run {
                    syncUITestRuntimeState()
                }
            }
        }
    }
    static var voicesDir: URL { AppPaths.voicesDir }

    private func retryLaunchPreflight() {
        appStartupCoordinator.refreshLaunchDiagnostics()
        guard appStartupCoordinator.launchDiagnostics == nil else { return }
        if bootstrapMode == .python {
            envManager.ensureEnvironment()
        }
        syncUITestRuntimeState()
    }

    private func syncUITestRuntimeState() {
        appStartupCoordinator.syncUITestRuntimeReadiness(
            appEngineSelection: appEngineSelection,
            environmentState: envManager.state,
            pythonBridge: pythonBridge,
            ttsEngineSnapshot: ttsEngineStore.snapshot
        )
    }

    private func syncUITestSidebarStatus() {
        guard UITestAutomationSupport.isEnabled else { return }
        let resolvedStatus = appEngineSelection.resolveSidebarStatus(
            pythonBridge: pythonBridge,
            ttsEngineSnapshot: ttsEngineStore.snapshot,
            prefersInlinePresentation: audioPlayer.isLiveStream
        )
        TestStateProvider.shared.setSidebarStatus(resolvedStatus)
    }
}
