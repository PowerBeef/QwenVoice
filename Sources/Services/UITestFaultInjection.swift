#if QW_TEST_SUPPORT
import Foundation

enum UITestFault: String {
    case listVoices = "QWENVOICE_UI_TEST_FAULT_LIST_VOICES"
    case historyFetch = "QWENVOICE_UI_TEST_FAULT_HISTORY_FETCH"
    case historyDeleteDatabase = "QWENVOICE_UI_TEST_FAULT_HISTORY_DELETE_DB"
    case historyDeleteAudio = "QWENVOICE_UI_TEST_FAULT_HISTORY_DELETE_AUDIO"
    case voiceTranscriptRead = "QWENVOICE_UI_TEST_FAULT_VOICE_TRANSCRIPT_READ"
}

struct UITestFaultError: LocalizedError {
    let fault: UITestFault

    var errorDescription: String? {
        switch fault {
        case .listVoices:
            return "Simulated voice-list load failure."
        case .historyFetch:
            return "Simulated history refresh failure."
        case .historyDeleteDatabase:
            return "Simulated history database delete failure."
        case .historyDeleteAudio:
            return "Simulated audio file delete failure."
        case .voiceTranscriptRead:
            return "Simulated saved transcript read failure."
        }
    }
}

enum UITestFaultInjection {
    private static let uiTestEnvironmentKey = "QWENVOICE_UI_TEST"

    static func isEnabled(_ fault: UITestFault) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard isTruthy(environment[uiTestEnvironmentKey]) else { return false }
        return isTruthy(environment[fault.rawValue])
    }

    static func throwIfEnabled(_ fault: UITestFault) throws {
        guard isEnabled(fault) else { return }
        throw UITestFaultError(fault: fault)
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}
#endif
