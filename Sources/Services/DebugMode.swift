import Foundation
import QwenVoiceCore

/// App-target view of the one explicit process-local runtime debug gate.
/// Release builds retain diagnostic code, but production-affecting overrides are
/// inert unless the launching process explicitly sets `QWENVOICE_DEBUG`.
enum DebugMode {
    static let isEnabled = RuntimeDebugGate.isEnabled()
}
