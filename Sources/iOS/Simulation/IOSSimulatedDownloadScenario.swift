import Foundation

/// Simulator-only download scenario selector (`QVOICE_SIM_DOWNLOAD_SCENARIO`).
enum IOSSimulatedDownloadScenario: Sendable {
    case success
    case slow
    case failMid
    case failVerify

    static var current: IOSSimulatedDownloadScenario {
        switch ProcessInfo.processInfo.environment["QVOICE_SIM_DOWNLOAD_SCENARIO"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "slow":
            return .slow
        case "fail_mid", "fail-mid":
            return .failMid
        case "fail_verify", "fail-verify":
            return .failVerify
        default:
            return .success
        }
    }

    var delayMultiplier: Int {
        switch self {
        case .success, .failMid, .failVerify:
            return 1
        case .slow:
            return 3
        }
    }
}
