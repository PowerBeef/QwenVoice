import Foundation

enum AppPaths {
    static let appSupportOverrideEnvironmentKey = "QVOICE_APP_SUPPORT_DIR"
    static let sharedAppGroupIdentifier = "group.com.qvoice.shared"

    static var managedAppSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Q-Voice", isDirectory: true)
    }

    static var sharedContainerDir: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: sharedAppGroupIdentifier
        )?.appendingPathComponent("Vocello", isDirectory: true)
    }

    static var isUsingSharedContainer: Bool {
        sharedContainerDir != nil
    }

    static var appSupportDir: URL {
        resolvedAppSupportDir(environment: ProcessInfo.processInfo.environment)
    }

    static func resolvedAppSupportDir(environment: [String: String]) -> URL {
        if let overridePath = environment[appSupportOverrideEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            if NSString(string: overridePath).isAbsolutePath {
                return URL(fileURLWithPath: overridePath, isDirectory: true)
            }
            return managedAppSupportDir.appendingPathComponent(overridePath, isDirectory: true)
        }

        return sharedContainerDir ?? managedAppSupportDir
    }

    static var modelsDir: URL {
        appSupportDir.appendingPathComponent("models", isDirectory: true)
    }

    static var modelDownloadRootDir: URL {
        appSupportDir.appendingPathComponent("downloads", isDirectory: true)
    }

    static var modelDownloadStagingDir: URL {
        modelDownloadRootDir.appendingPathComponent("staging", isDirectory: true)
    }

    static var modelDeliveryStateFile: URL {
        modelDownloadRootDir.appendingPathComponent("ios_model_delivery_state.json", isDirectory: false)
    }

    static var outputsDir: URL {
        appSupportDir.appendingPathComponent("outputs", isDirectory: true)
    }

    static var voicesDir: URL {
        appSupportDir.appendingPathComponent("voices", isDirectory: true)
    }

    static var importedReferenceAudioDir: URL {
        appSupportDir.appendingPathComponent("cache/imported_references", isDirectory: true)
    }

    static var preparedAudioDir: URL {
        appSupportDir.appendingPathComponent("cache/prepared_audio", isDirectory: true)
    }

    static var normalizedCloneReferenceDir: URL {
        appSupportDir.appendingPathComponent("cache/normalized_clone_refs", isDirectory: true)
    }

    static var streamSessionsDir: URL {
        appSupportDir.appendingPathComponent("cache/stream_sessions", isDirectory: true)
    }

    static var nativeMLXCacheDir: URL {
        appSupportDir.appendingPathComponent("cache/native_mlx", isDirectory: true)
    }
}
