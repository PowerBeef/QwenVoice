import Foundation
import QwenVoiceNative

enum AppEngineSelection: Equatable {
    static let defaultSelection: Self = .native

    case native

    init(environment _: [String: String] = ProcessInfo.processInfo.environment) {
        self = .native
    }

    static func current(environment _: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        .native
    }

    func effectiveSelection() -> Self {
        self
    }

#if QW_TEST_SUPPORT
    func effectiveSelection(isStubBackendMode _: Bool = UITestAutomationSupport.isStubBackendMode) -> Self {
        self
    }
#endif

    func requiresManualInitialization() -> Bool {
        true
    }

#if QW_TEST_SUPPORT
    func requiresManualInitialization(isStubBackendMode _: Bool = UITestAutomationSupport.isStubBackendMode) -> Bool {
        true
    }
#endif

    @MainActor
    func makeEngine() -> any MacTTSEngine {
        return XPCNativeEngineClient()
    }

#if QW_TEST_SUPPORT
    @MainActor
    func makeEngine(isStubBackendMode: Bool = UITestAutomationSupport.isStubBackendMode) -> any MacTTSEngine {
        if isStubBackendMode {
            return UITestStubMacEngine()
        }
        return XPCNativeEngineClient()
    }
#endif

    @MainActor
    func resolveSidebarStatus(
        ttsEngineSnapshot: TTSEngineSnapshot,
        prefersInlinePresentation: Bool
    ) -> SidebarStatus {
        Self.nativeSidebarStatus(
            from: ttsEngineSnapshot,
            prefersInlinePresentation: prefersInlinePresentation
        )
    }

    @MainActor
    func clearSidebarError(
        ttsEngineStore: TTSEngineStore
    ) {
        ttsEngineStore.clearVisibleError()
    }

#if QW_TEST_SUPPORT
    @MainActor
    func clearSidebarError(
        ttsEngineStore: TTSEngineStore,
        isStubBackendMode _: Bool = UITestAutomationSupport.isStubBackendMode
    ) {
        ttsEngineStore.clearVisibleError()
    }
#endif

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
