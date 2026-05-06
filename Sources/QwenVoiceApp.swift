import SwiftUI
import AppKit
import QwenVoiceNative

@main
struct QwenVoiceApp: App {
    @NSApplicationDelegateAdaptor(QwenVoiceApplicationDelegate.self)
    private var appDelegate
    @StateObject private var ttsEngineStore: TTSEngineStore
    @State private var didInitializeSelectedTTSEngine = false
    @StateObject private var audioPlayer = AudioPlayerViewModel()
    @StateObject private var modelManager = ModelManagerViewModel()
    @StateObject private var savedVoicesViewModel = SavedVoicesViewModel()
    @StateObject private var appCommandRouter = AppCommandRouter.shared
    @StateObject private var generationLibraryEvents = GenerationLibraryEvents.shared
    @StateObject private var appStartupCoordinator = AppStartupCoordinator()
    private let appEngineSelection: AppEngineSelection

    init() {
        let appEngineSelection = AppEngineSelection.current()
        self.appEngineSelection = appEngineSelection
#if QW_TEST_SUPPORT
        let useStubBackend = AppLaunchConfiguration.shouldUseStubBackend(
            isStubBackendMode: UITestAutomationSupport.isStubBackendMode,
            isAudioQualityHeadlessHost: AppLaunchConfiguration.current.isAudioQualityHeadlessHost
        )
        let engine = appEngineSelection.makeEngine(isStubBackendMode: useStubBackend)
#else
        let engine = appEngineSelection.makeEngine()
#endif
        _ttsEngineStore = StateObject(
            wrappedValue: TTSEngineStore(
                engine: engine
            )
        )

#if QW_TEST_SUPPORT
        if let forcedAppearance = UITestAutomationSupport.forcedNSAppearance {
            NSApplication.shared.appearance = forcedAppearance
        }
#endif
    }

    var body: some Scene {
        WindowGroup {
#if QW_TEST_SUPPORT
            if AppLaunchConfiguration.current.isAudioQualityHeadlessHost {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
                    .onAppear {
                        AppLaunchConfiguration.hideAudioQualityHeadlessHostWindowsIfNeeded()
                    }
            } else {
                mainWindowContent
            }
#else
            mainWindowContent
#endif
        }
        .defaultSize(width: 720, height: 560)
        Settings {
            // The Cmd+, scene hosts the same SettingsView the
            // sidebar shows, so muscle memory keeps working. Deep
            // link highlighting is a no-op in this surface (the
            // sidebar has no notion of "the user just clicked a
            // disabled mode" inside the standalone settings
            // window).
            SettingsView(highlightedModelID: .constant(nil))
                .environmentObject(modelManager)
#if QW_TEST_SUPPORT
                .defaultAppStorage(UITestAutomationSupport.appStorage)
#endif
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
                    appCommandRouter.navigate(to: .settings)
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

    @ViewBuilder
    private var mainWindowContent: some View {
        Group {
            if let launchDiagnostics = appStartupCoordinator.launchDiagnostics {
                StartupDiagnosticsView(
                    snapshot: launchDiagnostics,
                    onRetry: retryLaunchPreflight
                )
                .frame(minWidth: 520, minHeight: 420)
            } else {
                ContentView()
                    .environmentObject(ttsEngineStore)
                    .environmentObject(audioPlayer)
                    .environmentObject(audioPlayer.playbackProgress)
                    .environmentObject(modelManager)
                    .environmentObject(savedVoicesViewModel)
                    .environmentObject(appCommandRouter)
                    .environmentObject(generationLibraryEvents)
                    .frame(minWidth: 720, minHeight: 560)
            }
        }
#if QW_TEST_SUPPORT
        .defaultAppStorage(UITestAutomationSupport.appStorage)
        .background(
            UITestWindowSizeConfigurator(
                contentSize: AppLaunchConfiguration.current.uiTestWindowSize
            )
        )
#endif
        .onAppear {
            appStartupCoordinator.setupAppSupport()
            startSelectedTTSEngineIfNeeded()
            appStartupCoordinator.refreshLaunchDiagnostics()
            AppLaunchConfiguration.openSettingsWindowIfNeeded()
        }
    }

    static var voicesDir: URL { AppPaths.voicesDir }

    static var appSupportDir: URL {
        AppPaths.appSupportDir
    }

    static var modelsDir: URL { AppPaths.modelsDir }
    static var outputsDir: URL { AppPaths.outputsDir }

    private func startSelectedTTSEngineIfNeeded() {
#if QW_TEST_SUPPORT
        guard !UITestAutomationSupport.shouldSuppressAppEngineAutoStart else { return }
        guard !AppLaunchConfiguration.current.isAudioQualityHeadlessHost else { return }
        guard appEngineSelection.requiresManualInitialization(
            isStubBackendMode: UITestAutomationSupport.isStubBackendMode
        ) else { return }
#else
        guard appEngineSelection.requiresManualInitialization() else { return }
#endif
        guard !didInitializeSelectedTTSEngine else { return }
        didInitializeSelectedTTSEngine = true

        Task {
            do {
                try await ttsEngineStore.initialize(appSupportDirectory: Self.appSupportDir)
            } catch {
                // Native engine initialization publishes its own failure snapshot.
            }
        }
    }

    private func retryLaunchPreflight() {
        appStartupCoordinator.refreshLaunchDiagnostics()
    }
}
