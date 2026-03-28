import SwiftUI
import AppKit
import CoreGraphics

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
    @MainActor private static var openedInitialSettingsWindow = false

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

    @MainActor static func openSettingsWindowIfNeeded() {
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

@MainActor
final class UITestWindowCoordinator {
    struct ScreenshotCaptureResult {
        let captured: Bool
        let mode: UITestScreenshotCaptureMode
        let failureReason: String?
    }

    static let shared = UITestWindowCoordinator()
    static let mainContentWindowIdentifier = NSUserInterfaceItemIdentifier("QwenVoiceMainContentWindow")

    private var observationTokens: [NSObjectProtocol] = []
    private var recoveryTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard observationTokens.isEmpty else { return }

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignMainNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didExposeNotification,
            NSWindow.willCloseNotification,
        ]

        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.syncVisibleMainWindowState()
                }
            }
            observationTokens.append(token)
        }

        syncVisibleMainWindowState()
    }

    func scheduleRecoveryIfNeeded(reason: String) {
        guard UITestAutomationSupport.isEnabled else { return }

        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled else { return }
            await self.runRecoveryIfNeeded(reason: reason)
        }
    }

    func activateMainWindow(reason: String) async -> Bool {
        guard UITestAutomationSupport.isEnabled else { return false }

        let application = NSApplication.shared
        let targetWindow = preferredMainWindow()

        application.unhide(nil)
        application.activate(ignoringOtherApps: true)

        if let targetWindow {
            if targetWindow.isMiniaturized {
                targetWindow.deminiaturize(nil)
            }
            targetWindow.makeKeyAndOrderFront(nil)
            targetWindow.orderFrontRegardless()
        } else {
            application.arrangeInFront(nil)
        }

        try? await Task.sleep(for: .milliseconds(250))
        let hasVisibleMainWindow = syncVisibleMainWindowState()
        TestStateProvider.shared.recordWindowActivationAttempt(
            reason: reason,
            hasVisibleMainWindow: hasVisibleMainWindow
        )
        return hasVisibleMainWindow
    }

    func captureMainWindowScreenshot(name: String) -> ScreenshotCaptureResult {
        let mode = UITestAutomationSupport.screenshotCaptureMode

        guard UITestAutomationSupport.isEnabled else {
            return ScreenshotCaptureResult(
                captured: false,
                mode: mode,
                failureReason: "ui_test_automation_disabled"
            )
        }
        guard let screenshotDirectory = UITestAutomationSupport.screenshotDirectoryURL else {
            return ScreenshotCaptureResult(
                captured: false,
                mode: mode,
                failureReason: "screenshot_directory_unavailable"
            )
        }
        guard let window = preferredMainWindow() else {
            return ScreenshotCaptureResult(
                captured: false,
                mode: mode,
                failureReason: "main_window_unavailable"
            )
        }

        try? FileManager.default.createDirectory(
            at: screenshotDirectory,
            withIntermediateDirectories: true
        )
        let destinationURL = screenshotDirectory.appendingPathComponent("\(name).png")

        if ReadmeScreenshotRenderer.shouldRender(name: name) {
            let captured = ReadmeScreenshotRenderer.render(
                name: name,
                snapshot: TestStateProvider.shared.snapshot(),
                to: destinationURL
            )
            return ScreenshotCaptureResult(
                captured: captured,
                mode: mode,
                failureReason: captured ? nil : "readme_capture_failed"
            )
        }

        switch mode {
        case .content:
            let captured = captureWindowContent(window, to: destinationURL)
            return ScreenshotCaptureResult(
                captured: captured,
                mode: mode,
                failureReason: captured ? nil : "content_capture_failed"
            )
        case .system:
            if !canUseSystemScreenCapture() {
                return ScreenshotCaptureResult(
                    captured: false,
                    mode: mode,
                    failureReason: "screen_capture_permission_required"
                )
            }
            let captured = captureWindowImage(window, to: destinationURL)
            return ScreenshotCaptureResult(
                captured: captured,
                mode: mode,
                failureReason: captured ? nil : "system_capture_failed"
            )
        }
    }

    private func captureWindowImage(_ window: NSWindow, to destinationURL: URL) -> Bool {
        window.displayIfNeeded()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", destinationURL.path]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: destinationURL.path)
    }

    private func captureWindowContent(_ window: NSWindow, to destinationURL: URL) -> Bool {
        guard let contentView = window.contentView else { return false }
        let renderView = contentView
        let bounds = renderView.bounds.integral
        guard !bounds.isEmpty else {
            return false
        }

        renderView.layoutSubtreeIfNeeded()
        renderView.displayIfNeeded()
        window.displayIfNeeded()

        if let pngData = renderPDFContent(of: renderView, in: bounds, scale: window.backingScaleFactor)
            ?? renderLayerBackedContent(of: renderView, in: bounds, scale: window.backingScaleFactor)
            ?? renderCachedDisplay(of: renderView, in: bounds) {
            do {
                try pngData.write(to: destinationURL)
                return true
            } catch {
                return false
            }
        }

        return false
    }

    private func renderPDFContent(
        of view: NSView,
        in bounds: NSRect,
        scale: CGFloat
    ) -> Data? {
        let pdfData = view.dataWithPDF(inside: bounds)
        guard let pdfImage = NSPDFImageRep(data: pdfData) else { return nil }

        let pixelsWide = Int(bounds.width * scale)
        let pixelsHigh = Int(bounds.height * scale)
        guard pixelsWide > 0,
              pixelsHigh > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelsWide,
                pixelsHigh: pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        bitmap.size = bounds.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        pdfImage.draw(in: bounds)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .png, properties: [:])
    }

    private func renderLayerBackedContent(
        of view: NSView,
        in bounds: NSRect,
        scale: CGFloat
    ) -> Data? {
        guard let layer = view.layer else { return nil }

        let pixelsWide = Int(bounds.width * scale)
        let pixelsHigh = Int(bounds.height * scale)
        guard pixelsWide > 0,
              pixelsHigh > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelsWide,
                pixelsHigh: pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        context.cgContext.scaleBy(x: scale, y: scale)
        layer.render(in: context.cgContext)
        context.flushGraphics()
        return bitmap.representation(using: .png, properties: [:])
    }

    private func renderCachedDisplay(of view: NSView, in bounds: NSRect) -> Data? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }

        view.cacheDisplay(in: bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    private func canUseSystemScreenCapture() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func syncVisibleMainWindowState() -> Bool {
        let hasVisibleMainWindow = mainWindows().contains { window in
            window.isVisible && !window.isMiniaturized
        }
        TestStateProvider.shared.setVisibleMainWindow(hasVisibleMainWindow)
        return hasVisibleMainWindow
    }

    private func runRecoveryIfNeeded(reason: String) async {
        syncVisibleMainWindowState()
        guard TestStateProvider.shared.environmentReady,
              !TestStateProvider.shared.windowMounted else {
            return
        }

        _ = await activateMainWindow(reason: reason)

        guard TestStateProvider.shared.environmentReady,
              !TestStateProvider.shared.windowMounted else {
            return
        }

        try? await Task.sleep(for: .milliseconds(450))
        guard TestStateProvider.shared.environmentReady,
              !TestStateProvider.shared.windowMounted else {
            return
        }

        _ = await activateMainWindow(reason: "\(reason)_retry")
    }

    private func preferredMainWindow() -> NSWindow? {
        let windows = mainWindows()
        return windows.first(where: { $0.isVisible && !$0.isMiniaturized }) ?? windows.first
    }

    private func mainWindows() -> [NSWindow] {
        Self.trackedMainWindows(in: NSApplication.shared.windows)
    }

    static func trackedMainWindows(in windows: [NSWindow]) -> [NSWindow] {
        windows.filter { window in
            window.identifier == mainContentWindowIdentifier
                && window.canBecomeMain
                && !window.isExcludedFromWindowsMenu
        }
    }
}

@main
struct QwenVoiceApp: App {
    @StateObject private var pythonBridge = PythonBridge()
    @StateObject private var audioPlayer = AudioPlayerViewModel()
    @StateObject private var envManager = PythonEnvironmentManager()
    @StateObject private var modelManager = ModelManagerViewModel()
    @StateObject private var savedVoicesViewModel = SavedVoicesViewModel()
    private let testStateServer = TestStateServer()

    init() {
        // Ignore SIGPIPE to prevent crashes when writing to a broken pipe
        // (e.g. Python backend terminates between isRunning check and write)
        signal(SIGPIPE, SIG_IGN)

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

    private func syncUITestEnvironmentReadiness(for state: PythonEnvironmentManager.State) {
        guard UITestAutomationSupport.isEnabled else { return }

        let isEnvironmentReady: Bool
        let activePythonPath: String?
        if case .ready = state {
            isEnvironmentReady = true
        } else {
            isEnvironmentReady = false
        }
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
        TestStateProvider.shared.setEnvironmentReady(isEnvironmentReady)
        if isEnvironmentReady {
            UITestWindowCoordinator.shared.scheduleRecoveryIfNeeded(reason: "environment_ready")
        }
    }

    private func bundledRuntimeRoot() -> String? {
        Bundle.main.resourceURL?
            .appendingPathComponent("python", isDirectory: true)
            .path
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch envManager.state {
                case .ready(let pythonPath):
                    ContentView()
                        .environmentObject(pythonBridge)
                        .environmentObject(audioPlayer)
                        .environmentObject(audioPlayer.playbackProgress)
                        .environmentObject(envManager)
                        .environmentObject(modelManager)
                        .environmentObject(savedVoicesViewModel)
                        .frame(minWidth: 720, minHeight: 560)
                        .onAppear {
                            syncUITestEnvironmentReadiness(for: .ready(pythonPath: pythonPath))
                            if envManager.needsBackendRestart {
                                pythonBridge.stop()
                                envManager.needsBackendRestart = false
                            }
                            startBackend(pythonPath: pythonPath)
                        }
                case .idle:
                    SetupView(envManager: envManager)
                        .frame(minWidth: 500, minHeight: 400)
                default:
                    SetupView(envManager: envManager)
                        .frame(minWidth: 500, minHeight: 400)
                }
            }
            .defaultAppStorage(UITestAutomationSupport.appStorage)
            .background(
                UITestWindowSizeConfigurator(
                    contentSize: AppLaunchConfiguration.current.uiTestWindowSize
                )
            )
            .onAppear {
                setupAppSupport()
                if UITestAutomationSupport.isEnabled {
                    UITestWindowCoordinator.shared.syncVisibleMainWindowState()
                    TestStateProvider.shared.setBackendReady(UITestAutomationSupport.isStubBackendMode)
                }
                envManager.ensureEnvironment()
                syncUITestEnvironmentReadiness(for: envManager.state)
                AppLaunchConfiguration.openSettingsWindowIfNeeded()
            }
            .onChange(of: envManager.state) { _, newState in
                syncUITestEnvironmentReadiness(for: newState)
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

                Button("Saved Voices") {
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
        if UITestAutomationSupport.isStubBackendMode {
            guard !pythonBridge.isReady else { return }
            Task {
                do {
                    try await pythonBridge.initialize(appSupportDir: Self.appSupportDir.path)
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

@MainActor private enum UITestWindowSizingState {
    static var configuredWindows: Set<ObjectIdentifier> = []
}

private struct UITestWindowSizeConfigurator: NSViewRepresentable {
    let contentSize: CGSize?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            applyWindowConfigurationIfNeeded(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            applyWindowConfigurationIfNeeded(for: nsView)
        }
    }

    private func applyWindowConfigurationIfNeeded(for view: NSView) {
        guard let window = view.window else {
            return
        }

        if UITestAutomationSupport.isEnabled {
            window.identifier = UITestWindowCoordinator.mainContentWindowIdentifier
        }

        guard let contentSize else {
            return
        }

        let key = ObjectIdentifier(window)
        guard !UITestWindowSizingState.configuredWindows.contains(key) else { return }

        window.setContentSize(contentSize)
        UITestWindowSizingState.configuredWindows.insert(key)
    }
}
