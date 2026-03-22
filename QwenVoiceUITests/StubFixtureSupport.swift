import Foundation

enum StubFixtureSupport {
    /// Create a minimal fixture directory mimicking ~/Library/Application Support/QwenVoice/.
    /// Returns the root path for use as QWENVOICE_UI_TEST_FIXTURE_ROOT.
    static func createFixtureRoot() -> String {
        let root = NSTemporaryDirectory() + "QwenVoiceUITestFixtures/\(UUID().uuidString)"
        let fm = FileManager.default

        let dirs = [
            "\(root)/models",
            "\(root)/outputs/CustomVoice",
            "\(root)/outputs/VoiceDesign",
            "\(root)/outputs/Clones",
            "\(root)/voices",
            "\(root)/cache/normalized_clone_refs",
        ]
        for dir in dirs {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
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
}
