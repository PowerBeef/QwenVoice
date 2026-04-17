import Foundation
import QwenVoiceNative

enum AppEngineSelection: String, Equatable {
    static let environmentKey = "QWENVOICE_APP_ENGINE"
    static let defaultSelection: Self = .native

    case python
    case native

    init(
        environment: [String: String],
        defaultSelection: Self = Self.defaultSelection
    ) {
        let rawValue = environment[Self.environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self = rawValue.flatMap(Self.init(rawValue:)) ?? defaultSelection
    }

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        Self(environment: environment)
    }

    func effectiveSelection(
        isStubBackendMode: Bool = UITestAutomationSupport.isStubBackendMode
    ) -> Self {
        self
    }

    func requiresManualInitialization(
        isStubBackendMode: Bool = UITestAutomationSupport.isStubBackendMode
    ) -> Bool {
        effectiveSelection(isStubBackendMode: isStubBackendMode) == .native
    }

    @MainActor
    func makeEngine(
        pythonBridge: PythonBridge,
        isStubBackendMode: Bool = UITestAutomationSupport.isStubBackendMode
    ) -> any MacTTSEngine {
        switch effectiveSelection(isStubBackendMode: isStubBackendMode) {
        case .python:
            return PythonBridgeMacTTSEngineAdapter(bridge: pythonBridge)
        case .native:
            return isStubBackendMode ? UITestStubMacEngine() : NativeMLXMacEngine()
        }
    }

    @MainActor
    func resolveSidebarStatus(
        pythonBridge: PythonBridge,
        ttsEngineSnapshot: TTSEngineSnapshot,
        prefersInlinePresentation: Bool,
        isStubBackendMode: Bool = UITestAutomationSupport.isStubBackendMode
    ) -> SidebarStatus {
        switch effectiveSelection(isStubBackendMode: isStubBackendMode) {
        case .python:
            return pythonBridge.sidebarStatus
        case .native:
            return Self.nativeSidebarStatus(
                from: ttsEngineSnapshot,
                prefersInlinePresentation: prefersInlinePresentation
            )
        }
    }

    @MainActor
    func clearSidebarError(
        pythonBridge: PythonBridge,
        ttsEngineStore: TTSEngineStore,
        isStubBackendMode: Bool = UITestAutomationSupport.isStubBackendMode
    ) {
        switch effectiveSelection(isStubBackendMode: isStubBackendMode) {
        case .python:
            pythonBridge.lastError = nil
        case .native:
            ttsEngineStore.clearVisibleError()
        }
    }

    private static func nativeSidebarStatus(
        from snapshot: TTSEngineSnapshot,
        prefersInlinePresentation: Bool
    ) -> SidebarStatus {
        if let visibleErrorMessage = snapshot.visibleErrorMessage,
           !visibleErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return snapshot.isReady ? .error(visibleErrorMessage) : .crashed(visibleErrorMessage)
        }

        switch snapshot.loadState {
        case .idle, .loaded:
            return snapshot.isReady ? .idle : .starting
        case .starting:
            return .starting
        case .running(_, let label, let fraction):
            return .running(
                ActivityStatus(
                    label: label ?? "Generating audio…",
                    fraction: fraction,
                    presentation: prefersInlinePresentation ? .inlinePlayer : .standaloneCard
                )
            )
        case .failed(let message):
            return snapshot.isReady ? .error(message) : .crashed(message)
        }
    }
}
