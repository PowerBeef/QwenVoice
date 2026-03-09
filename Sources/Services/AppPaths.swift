import Foundation

enum AppPaths {
    static let appSupportOverrideEnvironmentKey = "QWENVOICE_APP_SUPPORT_DIR"

    static var appSupportDir: URL {
        if let overridePath = ProcessInfo.processInfo.environment[appSupportOverrideEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath, isDirectory: true)
        }

        if let fixtureRoot = UITestAutomationSupport.fixtureRoot {
            return fixtureRoot
        }

        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("QwenVoice", isDirectory: true)
    }

    static var modelsDir: URL {
        appSupportDir.appendingPathComponent("models", isDirectory: true)
    }

    static var outputsDir: URL {
        appSupportDir.appendingPathComponent("outputs", isDirectory: true)
    }

    static var voicesDir: URL {
        appSupportDir.appendingPathComponent("voices", isDirectory: true)
    }

    static var pythonVenvDir: URL {
        appSupportDir.appendingPathComponent("python", isDirectory: true)
    }
}
