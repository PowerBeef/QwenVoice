import Foundation

enum AppPaths {
    static let appSupportOverrideEnvironmentKey = "QWENVOICE_APP_SUPPORT_DIR"
    static let localReleaseDataIDInfoKey = "QwenVoiceLocalReleaseDataID"

    private static let defaultFolderName: String = {
        #if DEBUG
        return "QwenVoice-Debug"
        #else
        return "QwenVoice"
        #endif
    }()

    private static let legacyFolderName = "QwenVoice"
    private static let localReleaseFolderName = "QwenVoice-Release-Local"

    static var isRepoLocalReleaseBundle: Bool {
        #if DEBUG
        false
        #else
        Bundle.main.bundleURL.standardizedFileURL.path.hasSuffix("/build/Release/Vocello.app")
        #endif
    }

    static var localReleaseDataID: String? {
        guard isRepoLocalReleaseBundle else { return nil }
        guard let raw = Bundle.main.object(forInfoDictionaryKey: localReleaseDataIDInfoKey) as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let sanitized = String(trimmed.unicodeScalars.filter { allowed.contains($0) })
        return sanitized.isEmpty ? nil : sanitized
    }

    static var localReleaseDefaultsSuiteName: String? {
        guard let localReleaseDataID else { return nil }
        return "com.qwenvoice.app.local-release.\(localReleaseDataID)"
    }

    static var appSupportDir: URL {
        if let overridePath = ProcessInfo.processInfo.environment[appSupportOverrideEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath, isDirectory: true)
        }
        #if !DEBUG
        if let localReleaseDataID {
            return baseApplicationSupportDir()
                .appendingPathComponent(localReleaseFolderName, isDirectory: true)
                .appendingPathComponent(localReleaseDataID, isDirectory: true)
        }
        #endif
        return baseApplicationSupportDir().appendingPathComponent(defaultFolderName, isDirectory: true)
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

    static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    // One-shot: rename ~/Library/Application Support/QwenVoice ->
    // QwenVoice-Debug on first Debug launch so testing data survives the
    // policy switch. Idempotent; skipped when an env-var override is set.
    static func migrateLegacyDataIfNeeded() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let override = environment[appSupportOverrideEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return
        }
        let base = baseApplicationSupportDir()
        let newURL = base.appendingPathComponent(defaultFolderName, isDirectory: true)
        let legacyURL = base.appendingPathComponent(legacyFolderName, isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: newURL.path),
              fm.fileExists(atPath: legacyURL.path) else { return }
        do {
            try fm.moveItem(at: legacyURL, to: newURL)
            NSLog("AppPaths: migrated legacy data folder %@ -> %@", legacyURL.path, newURL.path)
        } catch {
            NSLog("AppPaths: legacy data folder migration failed: %@", String(describing: error))
        }
        #endif
    }

    private static func baseApplicationSupportDir() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(
                fileURLWithPath: (NSHomeDirectory() as NSString)
                    .appendingPathComponent("Library/Application Support"),
                isDirectory: true
            )
    }
}

enum AppDefaults {
    static var store: UserDefaults {
        if let suiteName = AppPaths.localReleaseDefaultsSuiteName,
           let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        return .standard
    }
}
