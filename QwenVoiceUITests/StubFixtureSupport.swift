import Foundation

enum UITestLaunchBackendMode: String {
    case live
    case stub
}

enum UITestLaunchDataRoot: String {
    case fixture
    case real
}

struct UITestFixtureContext {
    let root: String?
    let shouldCleanup: Bool
}

enum StubFixtureSupport {
    private static var realAppSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("QwenVoice", isDirectory: true)
    }

    static func createContext(
        backendMode: UITestLaunchBackendMode,
        dataRoot: UITestLaunchDataRoot
    ) -> UITestFixtureContext {
        switch (backendMode, dataRoot) {
        case (.stub, _):
            return UITestFixtureContext(root: createStubFixtureRoot(), shouldCleanup: true)
        case (.live, .fixture):
            return UITestFixtureContext(root: createLiveFixtureRoot(), shouldCleanup: true)
        case (.live, .real):
            return UITestFixtureContext(root: realAppSupportRoot.path, shouldCleanup: false)
        }
    }

    /// Create a minimal fixture directory mimicking ~/Library/Application Support/QwenVoice/.
    /// Returns the root path for use as QWENVOICE_UI_TEST_FIXTURE_ROOT.
    static func createStubFixtureRoot() -> String {
        let root = NSTemporaryDirectory() + "QwenVoiceUITestFixtures/\(UUID().uuidString)"
        createBaseDirectories(root: root)
        return root
    }

    static func createLiveFixtureRoot() -> String {
        let root = NSTemporaryDirectory() + "QwenVoiceUILiveFixtures/\(UUID().uuidString)"
        createBaseDirectories(root: root)

        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let fm = FileManager.default
        let modelsSource = realAppSupportRoot.appendingPathComponent("models", isDirectory: true)
        let pythonSource = realAppSupportRoot.appendingPathComponent("python", isDirectory: true)
        let voicesSource = realAppSupportRoot.appendingPathComponent("voices", isDirectory: true)
        let historySource = realAppSupportRoot.appendingPathComponent("history.sqlite")

        if modelsSource.isFileURL {
            mirrorItem(at: modelsSource, to: rootURL.appendingPathComponent("models", isDirectory: true), fileManager: fm)
        }
        if pythonSource.isFileURL {
            mirrorItem(at: pythonSource, to: rootURL.appendingPathComponent("python", isDirectory: true), fileManager: fm)
        }
        if fm.fileExists(atPath: voicesSource.path) {
            copyTree(at: voicesSource, to: rootURL.appendingPathComponent("voices", isDirectory: true), fileManager: fm)
        }
        if fm.fileExists(atPath: historySource.path) {
            try? fm.copyItem(at: historySource, to: rootURL.appendingPathComponent("history.sqlite"))
        }

        return root
    }

    /// Write a minimal WAV file (44-byte header + 0 samples) for import/enrollment testing.
    static func createMinimalWAV(at path: String) {
        var header = Data(count: 44)
        let sampleRate: UInt32 = 24000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16

        // RIFF header
        header.replaceSubrange(0..<4, with: "RIFF".data(using: .ascii)!)
        withUnsafeBytes(of: UInt32(36).littleEndian) { header.replaceSubrange(4..<8, with: $0) }
        header.replaceSubrange(8..<12, with: "WAVE".data(using: .ascii)!)

        // fmt chunk
        header.replaceSubrange(12..<16, with: "fmt ".data(using: .ascii)!)
        withUnsafeBytes(of: UInt32(16).littleEndian) { header.replaceSubrange(16..<20, with: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { header.replaceSubrange(20..<22, with: $0) } // PCM
        withUnsafeBytes(of: channels.littleEndian) { header.replaceSubrange(22..<24, with: $0) }
        withUnsafeBytes(of: sampleRate.littleEndian) { header.replaceSubrange(24..<28, with: $0) }
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        withUnsafeBytes(of: byteRate.littleEndian) { header.replaceSubrange(28..<32, with: $0) }
        let blockAlign = channels * (bitsPerSample / 8)
        withUnsafeBytes(of: blockAlign.littleEndian) { header.replaceSubrange(32..<34, with: $0) }
        withUnsafeBytes(of: bitsPerSample.littleEndian) { header.replaceSubrange(34..<36, with: $0) }

        // data chunk
        header.replaceSubrange(36..<40, with: "data".data(using: .ascii)!)
        withUnsafeBytes(of: UInt32(0).littleEndian) { header.replaceSubrange(40..<44, with: $0) }

        try? header.write(to: URL(fileURLWithPath: path))
    }

    /// Clean up fixture directory.
    static func cleanupFixtureRoot(_ root: String) {
        try? FileManager.default.removeItem(atPath: root)
    }

    private static func createBaseDirectories(root: String) {
        let fm = FileManager.default
        let dirs = [
            "\(root)/models",
            "\(root)/outputs/CustomVoice",
            "\(root)/outputs/VoiceDesign",
            "\(root)/outputs/Clones",
            "\(root)/voices",
            "\(root)/cache/normalized_clone_refs",
            "\(root)/cache/stream_sessions",
        ]
        for dir in dirs {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    private static func mirrorItem(at source: URL, to destination: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: source.path) else { return }
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
        } catch {
            try? fileManager.copyItem(at: source, to: destination)
        }
    }

    private static func copyTree(at source: URL, to destination: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: source.path) else { return }
        try? fileManager.removeItem(at: destination)
        try? fileManager.copyItem(at: source, to: destination)
    }
}
