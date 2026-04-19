import SwiftUI
import AppKit

private final class WeakSplitViewBox {
    weak var value: NSSplitView?

    init(_ value: NSSplitView) {
        self.value = value
    }
}

private enum WindowChromeState {
    static let configuredWindowIdentifier = NSUserInterfaceItemIdentifier("QwenVoiceWindowConfigured")
    static let dividerOverlayContainerLayerName = "QwenVoiceLegacyDividerBlendContainer"
    static let dividerOverlayBandLayerName = "QwenVoiceLegacyDividerBlendBand"
    static let dividerOverlayLeadingEdgeLayerName = "QwenVoiceLegacyDividerLeadingEdge"
    static let dividerOverlayTrailingEdgeLayerName = "QwenVoiceLegacyDividerTrailingEdge"

    @MainActor static var splitObservers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    @MainActor static var observedSplitViews: [ObjectIdentifier: WeakSplitViewBox] = [:]
    @MainActor static var windowToSplit: [ObjectIdentifier: ObjectIdentifier] = [:]
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

        pruneStaleSplitViews()

        let windowKey = ObjectIdentifier(window)
        let splitViews = findSplitViews(in: window.contentView)
        guard let splitView = selectPrimarySplitView(from: splitViews) else {
            if let previousSplitKey = WindowChromeState.windowToSplit[windowKey] {
                tearDownLegacyHandling(for: previousSplitKey)
                WindowChromeState.windowToSplit.removeValue(forKey: windowKey)
            }
            return
        }

        let splitKey = ObjectIdentifier(splitView)
        if let previousSplitKey = WindowChromeState.windowToSplit[windowKey], previousSplitKey != splitKey {
            tearDownLegacyHandling(for: previousSplitKey)
        }
        WindowChromeState.windowToSplit[windowKey] = splitKey

        splitView.dividerStyle = AppTheme.splitDividerStyle
        splitView.needsDisplay = true

        tearDownLegacyHandling(for: splitKey)
    }

    private static func findSplitViews(in rootView: NSView?) -> [NSSplitView] {
        guard let rootView else { return [] }

        var result: [NSSplitView] = []
        if let splitView = rootView as? NSSplitView {
            result.append(splitView)
        }

        for child in rootView.subviews {
            result.append(contentsOf: findSplitViews(in: child))
        }
        return result
    }

    private static func selectPrimarySplitView(from splitViews: [NSSplitView]) -> NSSplitView? {
        let verticalCandidates = splitViews.filter { $0.isVertical && $0.subviews.count >= 2 }
        if let primaryVertical = verticalCandidates.max(by: { $0.bounds.width < $1.bounds.width }) {
            return primaryVertical
        }
        return splitViews.first(where: { $0.subviews.count >= 2 })
    }

    private static func installSplitObserversIfNeeded(for splitView: NSSplitView) {
        let key = ObjectIdentifier(splitView)
        guard WindowChromeState.splitObservers[key] == nil else { return }

        WindowChromeState.observedSplitViews[key] = WeakSplitViewBox(splitView)
        splitView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default

        let resizeToken = center.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: splitView,
            queue: .main
        ) { [weak splitView] _ in
            MainActor.assumeIsolated {
                guard let splitView else { return }
                applyLegacyDividerBlendIfNeeded(to: splitView)
            }
        }

        let frameToken = center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: splitView,
            queue: .main
        ) { [weak splitView] _ in
            MainActor.assumeIsolated {
                guard let splitView else { return }
                applyLegacyDividerBlendIfNeeded(to: splitView)
            }
        }

        WindowChromeState.splitObservers[key] = [resizeToken, frameToken]
    }

    private static func pruneStaleSplitViews() {
        let staleKeys = WindowChromeState.observedSplitViews
            .filter { $0.value.value == nil }
            .map { $0.key }
        guard !staleKeys.isEmpty else { return }

        for staleKey in staleKeys {
            if let tokens = WindowChromeState.splitObservers.removeValue(forKey: staleKey) {
                tokens.forEach(NotificationCenter.default.removeObserver)
            }
            WindowChromeState.observedSplitViews.removeValue(forKey: staleKey)
            WindowChromeState.windowToSplit = WindowChromeState.windowToSplit.filter { $0.value != staleKey }
        }
    }

    private static func tearDownLegacyHandling(for splitKey: ObjectIdentifier) {
        if let splitView = WindowChromeState.observedSplitViews[splitKey]?.value {
            removeLegacyDividerBlend(from: splitView)
        }
        if let tokens = WindowChromeState.splitObservers.removeValue(forKey: splitKey) {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
        WindowChromeState.observedSplitViews.removeValue(forKey: splitKey)
        WindowChromeState.windowToSplit = WindowChromeState.windowToSplit.filter { $0.value != splitKey }
    }

    private static func applyLegacyDividerBlendIfNeeded(to splitView: NSSplitView) {
        removeLegacyDividerBlend(from: splitView)
    }

    private static func ensureOverlayLayer(named name: String, in parentLayer: CALayer) -> CALayer {
        if let existingLayer = parentLayer.sublayers?.first(where: { $0.name == name }) {
            return existingLayer
        }

        let newLayer = CALayer()
        newLayer.name = name
        parentLayer.addSublayer(newLayer)
        return newLayer
    }

    private static func removeLegacyDividerBlend(from splitView: NSSplitView) {
        guard let splitLayer = splitView.layer, var layers = splitLayer.sublayers else { return }
        layers.removeAll(where: { $0.name == WindowChromeState.dividerOverlayContainerLayerName })
        splitLayer.sublayers = layers
    }

    private static func expandedDividerFrame(for splitView: NSSplitView) -> CGRect {
        let baseFrame = dividerFrame(for: splitView)
        guard !baseFrame.isEmpty else { return .zero }

        let expandedFrame: CGRect
        if splitView.isVertical {
            expandedFrame = baseFrame.insetBy(dx: -AppTheme.legacyDividerBlendInset, dy: 0)
        } else {
            expandedFrame = baseFrame.insetBy(dx: 0, dy: -AppTheme.legacyDividerBlendInset)
        }

        return expandedFrame.intersection(splitView.bounds)
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
