import SwiftUI
import AppKit

struct AppLaunchConfiguration {
    let isUITest: Bool
    let disableAnimations: Bool
    let fastIdle: Bool
    let initialScreenID: String?
    let debugCaptureEnabled: Bool
    let uiTestWindowSize: CGSize?

    static let current = AppLaunchConfiguration(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment
    )
    private static var openedInitialSettingsWindow = false

    init(arguments: [String], environment: [String: String]) {
        let inferredUITest = arguments.contains("--uitest")
            || arguments.contains("--uitest-disable-animations")
            || arguments.contains("--uitest-fast-idle")
            || arguments.contains("--uitest-debug-capture")
            || arguments.contains(where: { $0.hasPrefix("--uitest-screen=") })

        isUITest = inferredUITest
        disableAnimations = inferredUITest && (
            arguments.contains("--uitest") || arguments.contains("--uitest-disable-animations")
        )
        fastIdle = inferredUITest && (
            arguments.contains("--uitest") || arguments.contains("--uitest-fast-idle")
        )
        debugCaptureEnabled = inferredUITest && arguments.contains("--uitest-debug-capture")
        initialScreenID = arguments.first(where: { $0.hasPrefix("--uitest-screen=") })?
            .replacingOccurrences(of: "--uitest-screen=", with: "")
        uiTestWindowSize = Self.parseWindowSize(environment["QWENVOICE_UI_TEST_WINDOW_SIZE"])
    }

    var initialSidebarItem: SidebarItem? {
        guard let initialScreenID else { return nil }
        return SidebarItem(testScreenID: initialScreenID)
    }

    var shouldOpenSettingsOnLaunch: Bool {
        initialScreenID == "preferences"
    }

    var animationsEnabled: Bool {
        !disableAnimations
    }

    func animation(_ animation: Animation?) -> Animation? {
        animationsEnabled ? animation : nil
    }

    static func performAnimated<Result>(_ animation: Animation?, _ updates: () -> Result) -> Result {
        withAnimation(current.animation(animation), updates)
    }

    static func openSettingsWindowIfNeeded() {
        guard current.shouldOpenSettingsOnLaunch, !openedInitialSettingsWindow else { return }
        openedInitialSettingsWindow = true
        DispatchQueue.main.async {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    private static func parseWindowSize(_ rawValue: String?) -> CGSize? {
        guard let rawValue else { return nil }

        let parts = rawValue
            .lowercased()
            .split(separator: "x", maxSplits: 1)
            .map(String.init)
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width > 0,
              height > 0 else {
            return nil
        }

        return CGSize(width: width, height: height)
    }
}

@main
struct QwenVoiceApp: App {
    @StateObject private var pythonBridge = PythonBridge()
    @StateObject private var audioPlayer = AudioPlayerViewModel()
    @StateObject private var envManager = PythonEnvironmentManager()
    @StateObject private var modelManager = ModelManagerViewModel()

    init() {
        // Ignore SIGPIPE to prevent crashes when writing to a broken pipe
        // (e.g. Python backend terminates between isRunning check and write)
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch envManager.state {
                case .ready(let pythonPath):
                    ContentView()
                        .environmentObject(pythonBridge)
                        .environmentObject(audioPlayer)
                        .environmentObject(envManager)
                        .environmentObject(modelManager)
                        .background(
                            UITestWindowSizeConfigurator(
                                contentSize: AppLaunchConfiguration.current.uiTestWindowSize
                            )
                        )
                        .frame(minWidth: 720, minHeight: 560)
                        .onAppear {
                            if envManager.needsBackendRestart {
                                pythonBridge.stop()
                                envManager.needsBackendRestart = false
                            }
                            startBackend(pythonPath: pythonPath)
                        }
                case .idle:
                    Color.clear
                        .frame(minWidth: 500, minHeight: 400)
                default:
                    SetupView(envManager: envManager)
                        .frame(minWidth: 500, minHeight: 400)
                }
            }
            .defaultAppStorage(UITestAutomationSupport.appStorage)
            .onAppear {
                setupAppSupport()
                envManager.ensureEnvironment()
                AppLaunchConfiguration.openSettingsWindowIfNeeded()
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
                    NotificationCenter.default.post(name: .navigateToSidebarItem, object: SidebarItem.customVoice)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Voice Design") {
                    NotificationCenter.default.post(name: .navigateToSidebarItem, object: SidebarItem.voiceDesign)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Voice Cloning") {
                    NotificationCenter.default.post(name: .navigateToSidebarItem, object: SidebarItem.voiceCloning)
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("History") {
                    NotificationCenter.default.post(name: .navigateToSidebarItem, object: SidebarItem.history)
                }
                .keyboardShortcut("4", modifiers: .command)

                Button("Voices") {
                    NotificationCenter.default.post(name: .navigateToSidebarItem, object: SidebarItem.voices)
                }
                .keyboardShortcut("5", modifiers: .command)

                Button("Models") {
                    NotificationCenter.default.post(name: .navigateToSidebarItem, object: SidebarItem.models)
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

    private func startBackend(pythonPath: String) {
        guard !pythonBridge.isReady else { return }
        pythonBridge.start(pythonPath: pythonPath)
        Task {
            do {
                try await pythonBridge.initialize(appSupportDir: Self.appSupportDir.path)
            } catch {
                pythonBridge.lastError = "Backend initialization failed: \(error.localizedDescription)"
            }
        }
    }

    private func setupAppSupport() {
        let fm = FileManager.default
        let outputSubdirectories = Set(TTSModel.all.map(\.outputSubfolder))

        let dirs = [
            Self.appSupportDir.path,
            Self.appSupportDir.appendingPathComponent("models").path,
            Self.appSupportDir.appendingPathComponent("outputs").path,
            Self.appSupportDir.appendingPathComponent("voices").path,
            Self.appSupportDir.appendingPathComponent("cache").path,
            Self.appSupportDir.appendingPathComponent("cache/stream_sessions").path,
        ] + outputSubdirectories.sorted().map {
            Self.appSupportDir.appendingPathComponent("outputs/\($0)").path
        }

        for dir in dirs {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    static var appSupportDir: URL {
        AppPaths.appSupportDir
    }

    static var modelsDir: URL { AppPaths.modelsDir }
    static var outputsDir: URL { AppPaths.outputsDir }
    static var voicesDir: URL { AppPaths.voicesDir }
}

private enum UITestWindowSizingState {
    static var configuredWindows: Set<ObjectIdentifier> = []
}

private struct UITestWindowSizeConfigurator: NSViewRepresentable {
    let contentSize: CGSize?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            applyWindowSizeIfNeeded(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            applyWindowSizeIfNeeded(for: nsView)
        }
    }

    private func applyWindowSizeIfNeeded(for view: NSView) {
        guard let contentSize,
              let window = view.window else {
            return
        }

        let key = ObjectIdentifier(window)
        guard !UITestWindowSizingState.configuredWindows.contains(key) else { return }

        window.setContentSize(contentSize)
        UITestWindowSizingState.configuredWindows.insert(key)
    }
}
