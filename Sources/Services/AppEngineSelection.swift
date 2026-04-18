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

    func effectiveSelection(isStubBackendMode _: Bool = UITestAutomationSupport.isStubBackendMode) -> Self {
        self
    }

    func requiresManualInitialization(isStubBackendMode _: Bool = UITestAutomationSupport.isStubBackendMode) -> Bool {
        true
    }

    @MainActor
    func makeEngine(
        isStubBackendMode: Bool = UITestAutomationSupport.isStubBackendMode
    ) -> any MacTTSEngine {
        isStubBackendMode ? UITestStubMacEngine() : XPCNativeEngineClient()
    }

    @MainActor
    func resolveSidebarStatus(
        ttsEngineSnapshot: TTSEngineSnapshot,
        prefersInlinePresentation: Bool,
        isStubBackendMode: Bool = UITestAutomationSupport.isStubBackendMode
    ) -> SidebarStatus {
        Self.nativeSidebarStatus(
            from: ttsEngineSnapshot,
            prefersInlinePresentation: prefersInlinePresentation
        )
    }

    @MainActor
    func clearSidebarError(
        ttsEngineStore: TTSEngineStore,
        isStubBackendMode: Bool = UITestAutomationSupport.isStubBackendMode
    ) {
        ttsEngineStore.clearVisibleError()
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
