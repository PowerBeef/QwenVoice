import SwiftUI
import UIKit
import QwenVoiceCore

struct IOSPreviewInitialState {
    let selectedTab: IOSAppTab
    let selectedGenerationSection: IOSGenerationSection
    let customDraft: CustomVoiceDraft
    let designDraft: VoiceDesignDraft
    let cloneDraft: VoiceCloningDraft
}

struct IOSPreviewSettingsModelSample {
    let status: ModelInventoryStatus
    let operationState: IOSModelInstallerViewModel.OperationState
}

struct IOSPreviewSettingsState {
    let modelSamples: [String: IOSPreviewSettingsModelSample]

    func sample(for model: TTSModel) -> IOSPreviewSettingsModelSample? {
        modelSamples[model.id]
    }
}

struct IOSPreviewRouteDefinition {
    let route: String
    let variant: String
    let title: String
    let initialState: IOSPreviewInitialState
    let settingsState: IOSPreviewSettingsState?

    var fullRouteID: String {
        "\(route)/\(variant)"
    }
}

struct IOSPreviewSession {
    let definition: IOSPreviewRouteDefinition
    let outputDirectory: URL
    let captureScreenshot: Bool

    var manifestURL: URL {
        outputDirectory.appendingPathComponent("manifest.json")
    }

    var routeDirectory: URL {
        IOSPreviewRuntime.routeDirectory(
            outputRoot: outputDirectory,
            route: definition.route,
            variant: definition.variant
        )
    }

    var sceneURL: URL {
        routeDirectory.appendingPathComponent("scene.json")
    }

    var nativeScreenshotURL: URL {
        routeDirectory.appendingPathComponent("native.png")
    }

    var fallbacksDirectory: URL {
        routeDirectory.appendingPathComponent("fallbacks", isDirectory: true)
    }
}

enum IOSPreviewRuntime {
    static let current: IOSPreviewSession? = resolveCurrentSession()

    static var isEnabled: Bool {
        current != nil
    }

    static let routes: [IOSPreviewRouteDefinition] = {
        let customDraft = CustomVoiceDraft(
            selectedSpeaker: TTSModel.defaultSpeaker,
            delivery: DeliveryInputState(mode: .preset, selectedPresetID: "neutral"),
            text: "Build a preview pipeline that preserves the real SwiftUI layout while letting Codex inspect it in a browser."
        )
        let designDraft = VoiceDesignDraft(
            voiceDescription: "A polished product narrator with steady pacing, crisp diction, and a calm, credible tone.",
            delivery: DeliveryInputState(mode: .preset, selectedPresetID: "neutral"),
            text: "The browser mirror should stay close to the simulator while still exposing semantic structure."
        )
        let cloneDraft = VoiceCloningDraft(
            selectedSavedVoiceID: nil,
            referenceAudioPath: "/Preview/Reference/boardroom-narrator.wav",
            referenceTranscript: "Here is a short reference sample used to establish cadence and pronunciation for the clone preview.",
            text: "This route shows how a prepared reference clip can be surfaced in the HTML mirror."
        )

        let settingsState = IOSPreviewSettingsState(modelSamples: [
            "pro_custom": IOSPreviewSettingsModelSample(
                status: .installed(sizeBytes: 2_492_000_000),
                operationState: .installed
            ),
            "pro_design": IOSPreviewSettingsModelSample(
                status: .notInstalled,
                operationState: .available(estimatedBytes: 3_114_000_000)
            ),
            "pro_clone": IOSPreviewSettingsModelSample(
                status: .incomplete(
                    message: "Installation incomplete: missing 2 required files.",
                    sizeBytes: 1_873_000_000
                ),
                operationState: .failed("Repair needed")
            )
        ])

        return [
            IOSPreviewRouteDefinition(
                route: "generate/custom",
                variant: "default",
                title: "Generate / Custom",
                initialState: IOSPreviewInitialState(
                    selectedTab: .generate,
                    selectedGenerationSection: .custom,
                    customDraft: customDraft,
                    designDraft: VoiceDesignDraft(),
                    cloneDraft: VoiceCloningDraft()
                ),
                settingsState: nil
            ),
            IOSPreviewRouteDefinition(
                route: "generate/design",
                variant: "default",
                title: "Generate / Design",
                initialState: IOSPreviewInitialState(
                    selectedTab: .generate,
                    selectedGenerationSection: .design,
                    customDraft: CustomVoiceDraft(selectedSpeaker: TTSModel.defaultSpeaker),
                    designDraft: designDraft,
                    cloneDraft: VoiceCloningDraft()
                ),
                settingsState: nil
            ),
            IOSPreviewRouteDefinition(
                route: "generate/clone",
                variant: "default",
                title: "Generate / Clone",
                initialState: IOSPreviewInitialState(
                    selectedTab: .generate,
                    selectedGenerationSection: .clone,
                    customDraft: CustomVoiceDraft(selectedSpeaker: TTSModel.defaultSpeaker),
                    designDraft: VoiceDesignDraft(),
                    cloneDraft: cloneDraft
                ),
                settingsState: nil
            ),
            IOSPreviewRouteDefinition(
                route: "settings",
                variant: "default",
                title: "Settings",
                initialState: IOSPreviewInitialState(
                    selectedTab: .settings,
                    selectedGenerationSection: .custom,
                    customDraft: CustomVoiceDraft(selectedSpeaker: TTSModel.defaultSpeaker),
                    designDraft: VoiceDesignDraft(),
                    cloneDraft: VoiceCloningDraft()
                ),
                settingsState: settingsState
            )
        ]
    }()

    private static func resolveCurrentSession() -> IOSPreviewSession? {
        let environment = ProcessInfo.processInfo.environment
        guard let rawRoute = environment["QVOICE_PREVIEW_ROUTE"]?.trimmingCharacters(in: .whitespacesAndNewlines).previewNilIfEmpty else {
            return nil
        }

        let normalized = normalizeRoute(
            rawRoute,
            variant: environment["QVOICE_PREVIEW_VARIANT"]?.trimmingCharacters(in: .whitespacesAndNewlines).previewNilIfEmpty
        )
        guard let definition = routes.first(where: { route in
            route.route == normalized.route && route.variant == normalized.variant
        }) else {
            return nil
        }

        let outputDirectory = resolveOutputDirectory(
            path: environment["QVOICE_PREVIEW_OUTPUT_DIR"]
        )
        let captureScreenshot = environment["QVOICE_PREVIEW_CAPTURE_SCREENSHOT"] != "0"
        return IOSPreviewSession(
            definition: definition,
            outputDirectory: outputDirectory,
            captureScreenshot: captureScreenshot
        )
    }

    private static func normalizeRoute(_ rawRoute: String, variant: String?) -> (route: String, variant: String) {
        let trimmed = rawRoute.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedVariant = variant?.previewNilIfEmpty ?? "default"
        let components = trimmed
            .split(separator: "/")
            .map(String.init)

        if let last = components.last,
           last == requestedVariant,
           components.count >= 2 {
            return (components.dropLast().joined(separator: "/"), requestedVariant)
        }

        return (trimmed, requestedVariant)
    }

    static func resolveOutputDirectory(path: String?) -> URL {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines).previewNilIfEmpty else {
            return AppPaths.appSupportDir.appendingPathComponent("swiftui-preview", isDirectory: true)
        }

        if NSString(string: path).isAbsolutePath {
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        return AppPaths.appSupportDir.appendingPathComponent(path, isDirectory: true)
    }

    static func routeDirectory(outputRoot: URL, route: String, variant: String) -> URL {
        let base = route
            .split(separator: "/")
            .map(String.init)
            .reduce(outputRoot.appendingPathComponent("routes", isDirectory: true)) { partial, component in
                partial.appendingPathComponent(component, isDirectory: true)
            }

        return base.appendingPathComponent(variant, isDirectory: true)
    }
}

struct IOSPreviewManifest: Codable {
    struct RouteEntry: Codable {
        let routeID: String
        let route: String
        let title: String
        let variant: String
    }

    let schemaVersion: Int
    let generatedAt: String
    let routes: [RouteEntry]
}

struct IOSSceneGraphDocument: Codable {
    let schemaVersion: Int
    let routeID: String
    let route: String
    let variant: String
    let exportedAt: String
    let canvas: IOSSceneGraphFrame
    let nativeScreenshotPath: String?
    let rootNode: IOSSceneGraphNode
    let fallbackRegions: [IOSPreviewFallbackRegion]
}

struct IOSSceneGraphNode: Codable {
    let id: String
    let role: String
    let frame: IOSSceneGraphFrame
    let text: String?
    let accessibilityLabel: String?
    let accessibilityIdentifier: String?
    let fallbackRegionID: String?
    let sourceType: String
    let childOrder: Int
    let style: IOSSceneGraphStyle?
    let children: [IOSSceneGraphNode]
}

struct IOSSceneGraphFrame: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct IOSSceneGraphStyle: Codable {
    let fontSize: Double?
    let fontWeight: String?
    let foregroundColorHex: String?
    let backgroundColorHex: String?
    let cornerRadius: Double?
    let opacity: Double?
}

struct IOSPreviewFallbackRegion: Codable {
    let id: String
    let reason: String
    let frame: IOSSceneGraphFrame
    let imagePath: String?
}

struct IOSPreviewCaptureBridge: UIViewRepresentable {
    let selectedTab: IOSAppTab
    let selectedGenerationSection: IOSGenerationSection

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        IOSPreviewExportCoordinator.shared.scheduleExport(
            from: uiView,
            selectedTab: selectedTab,
            selectedGenerationSection: selectedGenerationSection
        )
    }
}

@MainActor
private final class IOSPreviewExportCoordinator {
    static let shared = IOSPreviewExportCoordinator()

    private let timestampFormatter = ISO8601DateFormatter()
    private var exportTask: Task<Void, Never>?

    func scheduleExport(
        from anchorView: UIView,
        selectedTab: IOSAppTab,
        selectedGenerationSection: IOSGenerationSection
    ) {
        guard let session = IOSPreviewRuntime.current else { return }

        exportTask?.cancel()
        exportTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            guard let window = resolveWindow(from: anchorView) else { return }

            do {
                try FileManager.default.createDirectory(
                    at: session.outputDirectory,
                    withIntermediateDirectories: true
                )
                try writeManifest(for: session)
                try exportScene(
                    for: session,
                    in: window,
                    selectedTab: selectedTab,
                    selectedGenerationSection: selectedGenerationSection
                )
            } catch {
                #if DEBUG
                print("[IOSPreviewExportCoordinator] Export failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    private func resolveWindow(from anchorView: UIView) -> UIWindow? {
        if let window = anchorView.window {
            return window
        }

        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private func writeManifest(for session: IOSPreviewSession) throws {
        let manifest = IOSPreviewManifest(
            schemaVersion: 1,
            generatedAt: timestampFormatter.string(from: Date()),
            routes: IOSPreviewRuntime.routes.map { route in
                IOSPreviewManifest.RouteEntry(
                    routeID: route.fullRouteID,
                    route: route.route,
                    title: route.title,
                    variant: route.variant
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: session.manifestURL, options: .atomic)
    }

    private func exportScene(
        for session: IOSPreviewSession,
        in window: UIWindow,
        selectedTab: IOSAppTab,
        selectedGenerationSection: IOSGenerationSection
    ) throws {
        try FileManager.default.createDirectory(
            at: session.routeDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: session.fallbacksDirectory,
            withIntermediateDirectories: true
        )

        let screenshot = session.captureScreenshot ? captureScreenshot(from: window) : nil
        if let screenshot, let pngData = screenshot.pngData() {
            try pngData.write(to: session.nativeScreenshotURL, options: .atomic)
        }

        var fallbackRegions: [IOSPreviewFallbackRegion] = []
        let rootNode = IOSPreviewSceneGraphExtractor.extract(
            from: window,
            screenshot: screenshot,
            fallbackDirectory: session.fallbacksDirectory,
            outputRoot: session.outputDirectory,
            fallbackRegions: &fallbackRegions
        )

        let document = IOSSceneGraphDocument(
            schemaVersion: 1,
            routeID: session.definition.fullRouteID,
            route: session.definition.route,
            variant: session.definition.variant,
            exportedAt: timestampFormatter.string(from: Date()),
            canvas: IOSSceneGraphFrame(
                x: 0,
                y: 0,
                width: Double(window.bounds.width),
                height: Double(window.bounds.height)
            ),
            nativeScreenshotPath: session.captureScreenshot ? relativePath(
                for: session.nativeScreenshotURL,
                under: session.outputDirectory
            ) : nil,
            rootNode: rootNode,
            fallbackRegions: fallbackRegions
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: session.sceneURL, options: .atomic)

        #if DEBUG
        print(
            "[IOSPreviewExportCoordinator] Exported \(session.definition.fullRouteID) " +
            "tab=\(selectedTab.rawValue) section=\(selectedGenerationSection.rawValue) " +
            "to \(session.sceneURL.path)"
        )
        #endif
    }

    private func captureScreenshot(from window: UIWindow) -> UIImage {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func relativePath(for url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        guard fullPath.hasPrefix(rootPath) else { return fullPath }
        return String(fullPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

@MainActor
private enum IOSPreviewSceneGraphExtractor {
    static func extract(
        from window: UIWindow,
        screenshot: UIImage?,
        fallbackDirectory: URL,
        outputRoot: URL,
        fallbackRegions: inout [IOSPreviewFallbackRegion]
    ) -> IOSSceneGraphNode {
        let rootView = window.rootViewController?.view ?? window
        return makeNode(
            from: rootView,
            in: window,
            screenshot: screenshot,
            fallbackDirectory: fallbackDirectory,
            outputRoot: outputRoot,
            fallbackRegions: &fallbackRegions,
            childOrder: 0
        ) ?? IOSSceneGraphNode(
            id: "preview-root",
            role: "screen",
            frame: IOSSceneGraphFrame(
                x: 0,
                y: 0,
                width: Double(window.bounds.width),
                height: Double(window.bounds.height)
            ),
            text: nil,
            accessibilityLabel: nil,
            accessibilityIdentifier: "preview-root",
            fallbackRegionID: nil,
            sourceType: String(describing: type(of: rootView)),
            childOrder: 0,
            style: nil,
            children: []
        )
    }

    private static func makeNode(
        from view: UIView,
        in window: UIWindow,
        screenshot: UIImage?,
        fallbackDirectory: URL,
        outputRoot: URL,
        fallbackRegions: inout [IOSPreviewFallbackRegion],
        childOrder: Int
    ) -> IOSSceneGraphNode? {
        guard !view.isHidden, view.alpha > 0.01 else { return nil }
        let frame = absoluteFrame(for: view, in: window)
        guard frame.width > 0.5, frame.height > 0.5 else { return nil }

        let sourceType = String(describing: type(of: view))
        let identifier = view.accessibilityIdentifier
        let label = view.accessibilityLabel
        let fallbackRegionID: String?

        if isFallbackView(view) {
            let fallbackID = identifier ?? "fallback_\(UUID().uuidString)"
            let relativeImagePath = writeFallbackImage(
                screenshot: screenshot,
                frame: frame,
                fallbackID: fallbackID,
                fallbackDirectory: fallbackDirectory,
                outputRoot: outputRoot
            )
            fallbackRegions.append(
                IOSPreviewFallbackRegion(
                    id: fallbackID,
                    reason: "Rendered as native screenshot for fidelity-sensitive content.",
                    frame: frame,
                    imagePath: relativeImagePath
                )
            )
            fallbackRegionID = fallbackID
        } else {
            fallbackRegionID = nil
        }

        let children: [IOSSceneGraphNode]
        if fallbackRegionID == nil {
            children = view.subviews.enumerated().compactMap { index, child in
                makeNode(
                    from: child,
                    in: window,
                    screenshot: screenshot,
                    fallbackDirectory: fallbackDirectory,
                    outputRoot: outputRoot,
                    fallbackRegions: &fallbackRegions,
                    childOrder: index
                )
            }
        } else {
            children = []
        }

        return IOSSceneGraphNode(
            id: identifier ?? "node_\(UUID().uuidString)",
            role: role(for: view, accessibilityIdentifier: identifier),
            frame: frame,
            text: text(for: view),
            accessibilityLabel: label,
            accessibilityIdentifier: identifier,
            fallbackRegionID: fallbackRegionID,
            sourceType: sourceType,
            childOrder: childOrder,
            style: style(for: view),
            children: children
        )
    }

    private static func absoluteFrame(for view: UIView, in window: UIWindow) -> IOSSceneGraphFrame {
        let rect = view === window ? window.bounds : view.convert(view.bounds, to: window)
        return IOSSceneGraphFrame(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height)
        )
    }

    private static func role(for view: UIView, accessibilityIdentifier: String?) -> String {
        if accessibilityIdentifier?.hasPrefix("screen_") == true || view is UIWindow {
            return "screen"
        }
        if accessibilityIdentifier?.hasPrefix("rootTab_") == true {
            return "tab"
        }
        if view is UISwitch {
            return "toggle"
        }
        if view is UITextField || view is UITextView {
            return "input"
        }
        if view is UIButton || view.accessibilityTraits.contains(.button) {
            return "button"
        }
        if view is UIImageView {
            return "image"
        }
        if view is UIScrollView {
            return "list"
        }
        if min(view.bounds.width, view.bounds.height) <= 1.5 {
            return "divider"
        }
        if view is UILabel {
            return "text"
        }
        if isFallbackView(view) {
            return "fallback"
        }
        return "group"
    }

    private static func text(for view: UIView) -> String? {
        switch view {
        case let label as UILabel:
            return label.text?.trimmingCharacters(in: .whitespacesAndNewlines).previewNilIfEmpty
        case let textField as UITextField:
            return textField.text?.previewNilIfEmpty ?? textField.placeholder?.previewNilIfEmpty
        case let textView as UITextView:
            return textView.text?.trimmingCharacters(in: .whitespacesAndNewlines).previewNilIfEmpty
        case let button as UIButton:
            return button.currentTitle?.trimmingCharacters(in: .whitespacesAndNewlines).previewNilIfEmpty
        default:
            return nil
        }
    }

    private static func style(for view: UIView) -> IOSSceneGraphStyle? {
        let font: UIFont?
        let foregroundColor: UIColor?

        switch view {
        case let label as UILabel:
            font = label.font
            foregroundColor = label.textColor
        case let textField as UITextField:
            font = textField.font
            foregroundColor = textField.textColor
        case let textView as UITextView:
            font = textView.font
            foregroundColor = textView.textColor
        case let button as UIButton:
            font = button.titleLabel?.font
            foregroundColor = button.titleColor(for: .normal)
        default:
            font = nil
            foregroundColor = nil
        }

        let backgroundColor = view.backgroundColor?.previewHexString
        let foregroundColorHex = foregroundColor?.previewHexString
        let fontSize = font.map { Double($0.pointSize) }
        let fontWeight = font.map { $0.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any] }
            .flatMap { $0?[.weight] as? CGFloat }
            .map(fontWeightName)
        let cornerRadius = view.layer.cornerRadius > 0 ? Double(view.layer.cornerRadius) : nil
        let opacity = view.alpha < 0.999 ? Double(view.alpha) : nil

        if fontSize == nil,
           fontWeight == nil,
           foregroundColorHex == nil,
           backgroundColor == nil,
           cornerRadius == nil,
           opacity == nil {
            return nil
        }

        return IOSSceneGraphStyle(
            fontSize: fontSize,
            fontWeight: fontWeight,
            foregroundColorHex: foregroundColorHex,
            backgroundColorHex: backgroundColor,
            cornerRadius: cornerRadius,
            opacity: opacity
        )
    }

    private static func fontWeightName(_ weight: CGFloat) -> String {
        switch weight {
        case ..<(-0.4): return "light"
        case -0.4..<0.15: return "regular"
        case 0.15..<0.35: return "medium"
        case 0.35..<0.55: return "semibold"
        default: return "bold"
        }
    }

    private static func isFallbackView(_ view: UIView) -> Bool {
        if view is UIVisualEffectView {
            return true
        }

        let typeName = String(describing: type(of: view)).lowercased()
        return typeName.contains("visualeffect")
            || typeName.contains("material")
            || typeName.contains("glass")
            || typeName.contains("blur")
            || typeName.contains("metal")
    }

    private static func writeFallbackImage(
        screenshot: UIImage?,
        frame: IOSSceneGraphFrame,
        fallbackID: String,
        fallbackDirectory: URL,
        outputRoot: URL
    ) -> String? {
        guard let screenshot,
              let cgImage = screenshot.cgImage else {
            return nil
        }

        let scale = screenshot.scale
        let cropRect = CGRect(
            x: max(frame.x * scale, 0),
            y: max(frame.y * scale, 0),
            width: max(frame.width * scale, 1),
            height: max(frame.height * scale, 1)
        ).integral

        guard cropRect.width > 0,
              cropRect.height > 0,
              let cropped = cgImage.cropping(to: cropRect) else {
            return nil
        }

        let image = UIImage(cgImage: cropped, scale: scale, orientation: .up)
        guard let pngData = image.pngData() else { return nil }

        let fileURL = fallbackDirectory.appendingPathComponent("\(fallbackID).png")
        try? pngData.write(to: fileURL, options: .atomic)
        return relativePath(fileURL, under: outputRoot)
    }

    private static func relativePath(_ url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        guard fullPath.hasPrefix(rootPath) else { return fullPath }
        return String(fullPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private extension String {
    var previewNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension UIColor {
    var previewHexString: String? {
        guard let components = cgColor.components else { return nil }

        let resolved: (CGFloat, CGFloat, CGFloat, CGFloat)
        switch components.count {
        case 2:
            resolved = (components[0], components[0], components[0], components[1])
        case 4:
            resolved = (components[0], components[1], components[2], components[3])
        default:
            return nil
        }

        return String(
            format: "#%02X%02X%02X%02X",
            Int(resolved.0 * 255),
            Int(resolved.1 * 255),
            Int(resolved.2 * 255),
            Int(resolved.3 * 255)
        )
    }
}
