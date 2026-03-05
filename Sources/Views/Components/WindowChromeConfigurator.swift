import SwiftUI
import AppKit

private enum WindowChromeState {
    static let configuredWindowIdentifier = NSUserInterfaceItemIdentifier("QwenVoiceWindowConfigured")
    static let dividerOverlayLayerName = "QwenVoiceLegacyDividerOverlay"
    static var splitObservers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
}

struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configureWindow(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(for: nsView)
        }
    }

    private func configureWindow(for view: NSView) {
        guard let window = view.window else { return }

        // Apply one-time base window configuration.
        if window.identifier != WindowChromeState.configuredWindowIdentifier {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.toolbarStyle = .unified
            window.identifier = WindowChromeState.configuredWindowIdentifier
        }

        // Apply profile-driven separator styling on every update pass so we
        // can react when split view internals are ready.
        Self.applySeparatorStyling(to: window)
    }

    private static func applySeparatorStyling(to window: NSWindow) {
        window.titlebarSeparatorStyle = AppTheme.windowTitlebarSeparatorStyle

        guard let splitView = findSplitView(in: window.contentView) else { return }

        splitView.dividerStyle = AppTheme.splitDividerStyle
        splitView.needsDisplay = true

        switch AppTheme.uiProfile {
        case .liquid:
            removeDividerAttenuationOverlay(from: splitView)
        case .legacy:
            installSplitObserversIfNeeded(for: splitView)
            applyDividerAttenuationOverlayIfNeeded(to: splitView)
        }
    }

    private static func findSplitView(in rootView: NSView?) -> NSSplitView? {
        guard let rootView else { return nil }
        if let splitView = rootView as? NSSplitView {
            return splitView
        }
        for child in rootView.subviews {
            if let splitView = findSplitView(in: child) {
                return splitView
            }
        }
        return nil
    }

    private static func installSplitObserversIfNeeded(for splitView: NSSplitView) {
        let key = ObjectIdentifier(splitView)
        guard WindowChromeState.splitObservers[key] == nil else { return }

        splitView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default

        let resizeToken = center.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: splitView,
            queue: .main
        ) { [weak splitView] _ in
            guard let splitView else { return }
            applyDividerAttenuationOverlayIfNeeded(to: splitView)
        }

        let frameToken = center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: splitView,
            queue: .main
        ) { [weak splitView] _ in
            guard let splitView else { return }
            applyDividerAttenuationOverlayIfNeeded(to: splitView)
        }

        WindowChromeState.splitObservers[key] = [resizeToken, frameToken]
    }

    private static func applyDividerAttenuationOverlayIfNeeded(to splitView: NSSplitView) {
        guard let alpha = AppTheme.systemSeparatorAlpha, alpha > 0 else {
            removeDividerAttenuationOverlay(from: splitView)
            return
        }

        splitView.wantsLayer = true
        guard let splitLayer = splitView.layer else { return }

        let overlayLayer: CALayer
        if let existingLayer = splitLayer.sublayers?.first(where: { $0.name == WindowChromeState.dividerOverlayLayerName }) {
            overlayLayer = existingLayer
        } else {
            let newLayer = CALayer()
            newLayer.name = WindowChromeState.dividerOverlayLayerName
            splitLayer.addSublayer(newLayer)
            overlayLayer = newLayer
        }

        overlayLayer.zPosition = 10
        overlayLayer.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
        overlayLayer.frame = dividerFrame(for: splitView).integral
        overlayLayer.isHidden = overlayLayer.frame.isEmpty
    }

    private static func removeDividerAttenuationOverlay(from splitView: NSSplitView) {
        guard let splitLayer = splitView.layer, var layers = splitLayer.sublayers else { return }
        layers.removeAll(where: { $0.name == WindowChromeState.dividerOverlayLayerName })
        splitLayer.sublayers = layers
    }

    private static func dividerFrame(for splitView: NSSplitView) -> CGRect {
        guard splitView.subviews.count >= 2 else { return .zero }

        let dividerThickness = max(splitView.dividerThickness, 1)

        if splitView.isVertical {
            let leadingPaneFrame = splitView.subviews[0].frame
            return CGRect(
                x: leadingPaneFrame.maxX,
                y: 0,
                width: dividerThickness,
                height: splitView.bounds.height
            )
        }

        let topPaneFrame = splitView.subviews[0].frame
        return CGRect(
            x: 0,
            y: topPaneFrame.maxY,
            width: splitView.bounds.width,
            height: dividerThickness
        )
    }
}
