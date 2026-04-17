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
        isStubBackendMode ? .python : self
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
            return NativeMLXMacEngine()
        }
    }
}
