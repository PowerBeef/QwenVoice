import SwiftUI
import QwenVoiceCore

enum IOSAppTab: String, CaseIterable, Identifiable {
    case generate
    case library
    case settings

    var id: String { rawValue }
}

enum IOSLibrarySection: String, CaseIterable, Identifiable {
    case history
    case voices

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history:
            return "History"
        case .voices:
            return "Voices"
        }
    }

    var selectionTint: Color {
        switch self {
        case .history:
            return IOSBrandTheme.library
        case .voices:
            return IOSBrandTheme.library
        }
    }
}

enum IOSGenerationSection: String, CaseIterable, Identifiable {
    case custom
    case design
    case clone

    var id: String { rawValue }

    var mode: GenerationMode {
        switch self {
        case .custom: return .custom
        case .design: return .design
        case .clone: return .clone
        }
    }

    var title: String {
        mode.displayName
    }

    var compactTitle: String {
        switch self {
        case .custom:
            return "Choose Voice"
        case .design:
            return "Describe Voice"
        case .clone:
            return "Use Reference"
        }
    }
}

struct IOSUITestGenerationOverrides {
    let selectedSection: IOSGenerationSection?
    let scriptText: String?
    let voiceDesignBrief: String?

    static var current: IOSUITestGenerationOverrides {
        let environment = ProcessInfo.processInfo.environment
        return IOSUITestGenerationOverrides(
            selectedSection: environment["QVOICE_UI_TEST_SECTION"]
                .flatMap(IOSGenerationSection.init(rawValue:)),
            scriptText: environment["QVOICE_UI_TEST_SCRIPT_TEXT"],
            voiceDesignBrief: environment["QVOICE_UI_TEST_VOICE_BRIEF"]
        )
    }
}

enum IOSSimulatorPreviewPolicy {
    static var isSimulatorPreview: Bool {
        IOSSimulatorRuntimeSupport.isSimulator
    }

    static func showsFullGenerationUI(for mode: GenerationMode) -> Bool {
        if isSimulatorPreview {
            return true
        }
        return IOSNativeDeviceFeatureGate.unsupportedReason(for: mode) == nil
    }

    static func allowsExecution(
        for mode: GenerationMode,
        declaredModes: Set<GenerationMode>
    ) -> Bool {
        !isSimulatorPreview && IOSNativeDeviceFeatureGate.isModeSupported(mode, declaredModes: declaredModes)
    }

    static var allowsModelMutations: Bool {
        !isSimulatorPreview
    }

    static func previewOperationState(
        for model: TTSModel,
        status: ModelManagerViewModel.ModelStatus,
        operationState: IOSModelInstallerViewModel.OperationState
    ) -> IOSModelInstallerViewModel.OperationState {
        guard isSimulatorPreview else { return operationState }

        switch operationState {
        case .available,
                .downloading,
                .interrupted,
                .resuming,
                .restarting,
                .verifying,
                .installing,
                .installed,
                .deleting:
            return operationState
        case .failed(let message):
            return .failed(message)
        case .idle, .unavailable:
            switch status {
            case .installed:
                return .installed
            case .checking, .notInstalled:
                return .available(estimatedBytes: model.estimatedDownloadBytes)
            case .incomplete(let message, _), .error(let message):
                return .failed(message)
            }
        }
    }
}
