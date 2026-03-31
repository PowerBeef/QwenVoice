import Foundation

/// Aggregates app UI state for test-mode queries.
/// Only active when UITestAutomationSupport.isEnabled.
@MainActor
final class TestStateProvider: ObservableObject {
    enum RuntimeSource: String {
        case none
        case bundled
        case devVenv = "dev_venv"
        case stub
        case other
    }

    static let shared = TestStateProvider()

    @Published var activeScreen: String = ""
    @Published var windowTitle: String = ""
    @Published var isReady: Bool = false
    @Published var windowMounted: Bool = false
    @Published var environmentReady: Bool = false
    @Published var backendReady: Bool = false
    @Published var interactiveReady: Bool = false
    @Published var selectedSpeaker: String = ""
    @Published var voiceDescription: String = ""
    @Published var emotion: String = ""
    @Published var isGenerating: Bool = false
    @Published var text: String = ""
    @Published var referenceAudioPath: String = ""
    @Published var referenceTranscript: String = ""
    @Published var disabledSidebarItems: String = ""
    @Published var lastNavigationStartedAtMS: Int = 0
    @Published var lastNavigationCompletedAtMS: Int = 0
    @Published var lastNavigationDurationMS: Int = 0
    @Published var lastNavigationTargetScreen: String = ""
    @Published var lastNavigationCompletedScreen: String = ""
    @Published var sidebarStatusKind: String = ""
    @Published var sidebarStatusLabel: String = ""
    @Published var sidebarStatusPresentation: String = ""
    @Published var sidebarInlineStatusVisible: Bool = false
    @Published var sidebarStandaloneStatusVisible: Bool = true
    @Published var launchPhase: String = "initializing"
    @Published var readinessBlocker: String = "environment_not_ready"
    @Published var hasVisibleMainWindow: Bool = false
    @Published var windowActivationAttemptCount: Int = 0
    @Published var lastWindowActivationReason: String = ""
    @Published var lastWindowActivationAtMS: Int = 0
    @Published var runtimeSource: String = RuntimeSource.none.rawValue
    @Published var activePythonPath: String = ""
    @Published var activeFFmpegPath: String = ""
    @Published var backendLastError: String = ""
    @Published var clonePrimingPhase: String = ""
    @Published var cloneFastReady: Bool = false
    @Published var previewPreparedCount: Int = 0
    @Published var previewPreparedAtMS: Int = 0
    @Published var previewChunkCount: Int = 0
    @Published var previewChunkAtMS: Int = 0
    @Published var previewFinalizedCount: Int = 0
    @Published var previewFinalizedAtMS: Int = 0

    func setEnvironmentReady(_ ready: Bool) {
        environmentReady = ready
        refreshInteractiveReady()
    }

    func setBackendReady(_ ready: Bool) {
        backendReady = ready
        refreshInteractiveReady()
    }

    func markWindowMounted(
        activeScreen: String,
        windowTitle: String,
        disabledSidebarItems: String
    ) {
        windowMounted = true
        hasVisibleMainWindow = true
        self.activeScreen = activeScreen
        self.windowTitle = windowTitle
        self.disabledSidebarItems = disabledSidebarItems
        refreshInteractiveReady()
    }

    func markSidebarSelectionStarted(targetScreen: String) {
        lastNavigationTargetScreen = targetScreen
        lastNavigationStartedAtMS = Self.monotonicMilliseconds
        lastNavigationCompletedAtMS = 0
        lastNavigationDurationMS = 0
    }

    func markSidebarSelectionCompleted(
        activeScreen: String,
        windowTitle: String,
        disabledSidebarItems: String
    ) {
        let completedAtMS = Self.monotonicMilliseconds

        windowMounted = true
        hasVisibleMainWindow = true
        self.activeScreen = activeScreen
        self.windowTitle = windowTitle
        self.disabledSidebarItems = disabledSidebarItems
        lastNavigationCompletedScreen = activeScreen
        lastNavigationCompletedAtMS = completedAtMS
        if lastNavigationStartedAtMS > 0 {
            lastNavigationDurationMS = max(completedAtMS - lastNavigationStartedAtMS, 0)
        }
        refreshInteractiveReady()
    }

    func markWindowUnmounted() {
        windowMounted = false
        hasVisibleMainWindow = false
        refreshInteractiveReady()
    }

    func setVisibleMainWindow(_ visible: Bool) {
        hasVisibleMainWindow = visible
        refreshInteractiveReady()
    }

    func recordWindowActivationAttempt(reason: String, hasVisibleMainWindow: Bool) {
        windowActivationAttemptCount += 1
        lastWindowActivationReason = reason
        lastWindowActivationAtMS = Self.monotonicMilliseconds
        self.hasVisibleMainWindow = hasVisibleMainWindow
        refreshInteractiveReady()
    }

    func setRuntimeStatus(source: RuntimeSource, pythonPath: String?, ffmpegPath: String?) {
        runtimeSource = source.rawValue
        activePythonPath = pythonPath ?? ""
        activeFFmpegPath = ffmpegPath ?? ""
    }

    func setBackendLastError(_ message: String?) {
        backendLastError = message ?? ""
    }

    func recordPreviewPrepared() {
        previewPreparedCount += 1
        previewPreparedAtMS = Self.monotonicMilliseconds
    }

    func recordPreviewChunk() {
        previewChunkCount += 1
        previewChunkAtMS = Self.monotonicMilliseconds
    }

    func recordPreviewFinalized() {
        previewFinalizedCount += 1
        previewFinalizedAtMS = Self.monotonicMilliseconds
    }

    func setSidebarStatus(_ status: SidebarStatus) {
        switch status {
        case .idle:
            sidebarStatusKind = "idle"
            sidebarStatusLabel = "Ready"
            sidebarStatusPresentation = "none"
        case .starting:
            sidebarStatusKind = "starting"
            sidebarStatusLabel = "Starting engine…"
            sidebarStatusPresentation = "none"
        case .running(let activity):
            sidebarStatusKind = "running"
            sidebarStatusLabel = activity.label
            switch activity.presentation {
            case .standaloneCard:
                sidebarStatusPresentation = "standaloneCard"
            case .inlinePlayer:
                sidebarStatusPresentation = "inlinePlayer"
            }
        case .error(let message):
            sidebarStatusKind = "error"
            sidebarStatusLabel = message
            sidebarStatusPresentation = "none"
        case .crashed(let message):
            sidebarStatusKind = "crashed"
            sidebarStatusLabel = message
            sidebarStatusPresentation = "none"
        }
    }

    func setSidebarFooter(inlineStatusVisible: Bool, standaloneStatusVisible: Bool) {
        sidebarInlineStatusVisible = inlineStatusVisible
        sidebarStandaloneStatusVisible = standaloneStatusVisible
    }

    func snapshot() -> [String: Any] {
        [
            "activeScreen": activeScreen,
            "windowTitle": windowTitle,
            "isReady": isReady,
            "windowMounted": windowMounted,
            "environmentReady": environmentReady,
            "backendReady": backendReady,
            "interactiveReady": interactiveReady,
            "selectedSpeaker": selectedSpeaker,
            "voiceDescription": voiceDescription,
            "emotion": emotion,
            "isGenerating": isGenerating,
            "text": text,
            "referenceAudioPath": referenceAudioPath,
            "referenceTranscript": referenceTranscript,
            "disabledSidebarItems": disabledSidebarItems,
            "lastNavigationStartedAtMS": lastNavigationStartedAtMS,
            "lastNavigationCompletedAtMS": lastNavigationCompletedAtMS,
            "lastNavigationDurationMS": lastNavigationDurationMS,
            "lastNavigationTargetScreen": lastNavigationTargetScreen,
            "lastNavigationCompletedScreen": lastNavigationCompletedScreen,
            "sidebarStatusKind": sidebarStatusKind,
            "sidebarStatusLabel": sidebarStatusLabel,
            "sidebarStatusPresentation": sidebarStatusPresentation,
            "sidebarInlineStatusVisible": sidebarInlineStatusVisible,
            "sidebarStandaloneStatusVisible": sidebarStandaloneStatusVisible,
            "launchPhase": launchPhase,
            "readinessBlocker": readinessBlocker,
            "hasVisibleMainWindow": hasVisibleMainWindow,
            "windowActivationAttemptCount": windowActivationAttemptCount,
            "lastWindowActivationReason": lastWindowActivationReason,
            "lastWindowActivationAtMS": lastWindowActivationAtMS,
            "runtimeSource": runtimeSource,
            "activePythonPath": activePythonPath,
            "activeFFmpegPath": activeFFmpegPath,
            "backendLastError": backendLastError,
            "clonePrimingPhase": clonePrimingPhase,
            "cloneFastReady": cloneFastReady,
            "previewPreparedCount": previewPreparedCount,
            "previewPreparedAtMS": previewPreparedAtMS,
            "previewChunkCount": previewChunkCount,
            "previewChunkAtMS": previewChunkAtMS,
            "previewFinalizedCount": previewFinalizedCount,
            "previewFinalizedAtMS": previewFinalizedAtMS,
        ]
    }

    nonisolated static func runtimeSource(
        for pythonPath: String?,
        bundledRuntimeRoot: String?,
        devVenvRoot: String,
        stubPythonPath: String
    ) -> RuntimeSource {
        guard let pythonPath,
              !pythonPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .none
        }

        let normalizedPythonPath = normalizePath(pythonPath)
        if normalizedPythonPath == normalizePath(stubPythonPath) {
            return .stub
        }

        if let bundledRuntimeRoot,
           isPath(normalizedPythonPath, inside: bundledRuntimeRoot) {
            return .bundled
        }

        if isPath(normalizedPythonPath, inside: devVenvRoot) {
            return .devVenv
        }

        return .other
    }

    private nonisolated static func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private nonisolated static func isPath(_ path: String, inside root: String) -> Bool {
        let normalizedRoot = normalizePath(root)
        return path == normalizedRoot || path.hasPrefix(normalizedRoot + "/")
    }

    private func refreshInteractiveReady() {
        interactiveReady = windowMounted
            && environmentReady
            && (UITestAutomationSupport.isStubBackendMode || backendReady)
        isReady = interactiveReady
        refreshLaunchDiagnostics()
    }

    private func refreshLaunchDiagnostics() {
        if interactiveReady {
            launchPhase = "interactive_ready"
            readinessBlocker = ""
            return
        }

        if !environmentReady {
            if windowMounted || backendReady {
                launchPhase = "environment_sync"
                readinessBlocker = "environment_state_desynced"
                return
            }
            launchPhase = "environment_setup"
            readinessBlocker = "environment_not_ready"
            return
        }

        if !UITestAutomationSupport.isStubBackendMode && !backendReady {
            launchPhase = "backend_startup"
            readinessBlocker = "backend_not_ready"
            return
        }

        if !hasVisibleMainWindow {
            launchPhase = "window_activation"
            readinessBlocker = "window_not_visible"
            return
        }

        if !windowMounted {
            launchPhase = "window_mount"
            readinessBlocker = "window_not_mounted"
            return
        }

        launchPhase = "awaiting_interactive_ready"
        readinessBlocker = "interactive_ready_timeout"
    }

    private static var monotonicMilliseconds: Int {
        Int(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}
