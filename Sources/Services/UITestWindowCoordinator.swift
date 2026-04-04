import SwiftUI
import AppKit
import CoreGraphics

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
                Task { [weak self] in
                    await self?.syncVisibleMainWindowState()
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

        if let pngData = renderCachedDisplay(of: renderView, in: bounds)
            ?? renderLayerBackedContent(of: renderView, in: bounds, scale: window.backingScaleFactor)
            ?? renderPDFContent(of: renderView, in: bounds, scale: window.backingScaleFactor) {
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

@MainActor private enum UITestWindowSizingState {
    static var configuredWindows: Set<ObjectIdentifier> = []
}

struct UITestWindowSizeConfigurator: NSViewRepresentable {
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

        if let forcedAppearance = UITestAutomationSupport.forcedNSAppearance {
            window.appearance = forcedAppearance
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
