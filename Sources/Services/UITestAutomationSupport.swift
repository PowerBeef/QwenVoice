import Foundation

enum UITestBackendMode {
    case live
    case stub
}

enum UITestSetupScenario: String {
    case success
    case failOnce = "fail_once"
}

enum UITestAutomationSupport {
    private static let environment = ProcessInfo.processInfo.environment

    static let uiTestEnvironmentKey = "QWENVOICE_UI_TEST"
    static let backendModeEnvironmentKey = "QWENVOICE_UI_TEST_BACKEND_MODE"
    static let fixtureRootEnvironmentKey = "QWENVOICE_UI_TEST_FIXTURE_ROOT"
    static let importAudioPathEnvironmentKey = "QWENVOICE_UI_TEST_IMPORT_AUDIO_PATH"
    static let enrollAudioPathEnvironmentKey = "QWENVOICE_UI_TEST_ENROLL_AUDIO_PATH"
    static let outputDirectoryEnvironmentKey = "QWENVOICE_UI_TEST_OUTPUT_DIRECTORY"
    static let screenshotDirectoryEnvironmentKey = "QWENVOICE_UITEST_SCREENSHOT_DIR"
    static let defaultsSuiteEnvironmentKey = "QWENVOICE_UI_TEST_DEFAULTS_SUITE"
    static let setupScenarioEnvironmentKey = "QWENVOICE_UI_TEST_SETUP_SCENARIO"
    static let setupDelayEnvironmentKey = "QWENVOICE_UI_TEST_SETUP_DELAY_MS"
    static let modelDownloadFailOnceEnvironmentKey = "QWENVOICE_UI_TEST_MODEL_DOWNLOAD_FAIL_ONCE"

    static var isEnabled: Bool {
        isTruthy(environment[uiTestEnvironmentKey])
            || ProcessInfo.processInfo.arguments.contains("--uitest")
    }

    static var backendMode: UITestBackendMode {
        guard isEnabled else { return .live }
        // Check env var first, fall back to launch arg
        let value = environment[backendModeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value == "stub" { return .stub }
        // --uitest launch arg implies stub mode when env var is absent
        if ProcessInfo.processInfo.arguments.contains("--uitest") && value == nil {
            return .stub
        }
        return .live
    }

    static var isStubBackendMode: Bool {
        backendMode == .stub
    }

    static var fixtureRoot: URL? {
        guard let raw = environment[fixtureRootEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    static var importAudioURL: URL? {
        pathURL(for: importAudioPathEnvironmentKey)
    }

    static var enrollAudioURL: URL? {
        pathURL(for: enrollAudioPathEnvironmentKey)
    }

    static var outputDirectoryURL: URL? {
        pathURL(for: outputDirectoryEnvironmentKey)
    }

    static var screenshotDirectoryURL: URL? {
        pathURL(for: screenshotDirectoryEnvironmentKey)
    }

    static var appStorage: UserDefaults {
        if let suiteName = environment[defaultsSuiteEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !suiteName.isEmpty,
           let defaults = UserDefaults(suiteName: suiteName) {
            return defaults
        }
        return .standard
    }

    static var setupScenario: UITestSetupScenario {
        guard let rawValue = environment[setupScenarioEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            let scenario = UITestSetupScenario(rawValue: rawValue) else {
            return .success
        }
        return scenario
    }

    static var setupDelayNanoseconds: UInt64 {
        guard let raw = environment[setupDelayEnvironmentKey],
              let milliseconds = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              milliseconds > 0 else {
            return 180_000_000
        }
        return UInt64(milliseconds) * 1_000_000
    }

    static var modelDownloadFailOnceIDs: Set<String> {
        commaSeparatedValues(for: modelDownloadFailOnceEnvironmentKey)
    }

    static func stubStateDirectory(in appSupportDir: URL) -> URL {
        appSupportDir.appendingPathComponent(".stub-state", isDirectory: true)
    }

    static func stubEventsDirectory(in appSupportDir: URL) -> URL {
        appSupportDir.appendingPathComponent(".stub-events", isDirectory: true)
    }

    static func consumeFailOnceFlag(namespace: String, identifier: String? = nil, appSupportDir: URL) -> Bool {
        guard isEnabled else { return false }
        let stateDirectory = stubStateDirectory(in: appSupportDir)
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

        let suffix = identifier?.replacingOccurrences(of: "/", with: "-") ?? "default"
        let markerURL = stateDirectory.appendingPathComponent("\(namespace)-\(suffix).flag")
        guard !FileManager.default.fileExists(atPath: markerURL.path) else { return false }

        FileManager.default.createFile(atPath: markerURL.path, contents: Data())
        return true
    }

    static func recordAction(_ name: String, details: String = "", appSupportDir: URL) {
        guard isEnabled else { return }
        let eventsDirectory = stubEventsDirectory(in: appSupportDir)
        try? FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        let fileName = name.replacingOccurrences(of: "/", with: "-")
        let fileURL = eventsDirectory.appendingPathComponent("\(fileName).txt")
        let contents = details.isEmpty ? name : "\(name)\n\(details)"
        try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func stubPythonPath() -> String {
        "stub-python3"
    }

    static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func pathURL(for key: String) -> URL? {
        guard let raw = environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private static func commaSeparatedValues(for key: String) -> Set<String> {
        guard let raw = environment[key], !raw.isEmpty else { return [] }
        let values = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Set(values)
    }
}
