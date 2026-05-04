import Foundation

/// Utility functions for audio file management.
enum AudioService {
    private static var defaults: UserDefaults {
#if QW_TEST_SUPPORT
        UITestAutomationSupport.appStorage
#else
        .standard
#endif
    }

    static var shouldAutoPlay: Bool {
        if defaults.object(forKey: "autoPlay") == nil {
            return true
        }
        return defaults.bool(forKey: "autoPlay")
    }

    /// When ON: live-preview playback waits for enough buffered audio
    /// to play through long scripts without underrun pauses (predictive
    /// prebuffer based on text length × per-mode engine RTF). Adds a
    /// few seconds before the first audio plays. Default OFF preserves
    /// the existing fast-start-with-stutter behavior.
    /// See `LivePreviewEstimator` and
    /// `AudioPlayerViewModel.shouldStartLivePlayback`.
    static let smoothPlaybackKey = "QwenVoice.SmoothLivePreviewPlayback"
    static var smoothPlaybackEnabled: Bool {
        get { defaults.bool(forKey: smoothPlaybackKey) }
        set { defaults.set(newValue, forKey: smoothPlaybackKey) }
    }

    private static var configuredOutputsRoot: URL {
        let configuredPath = (defaults.string(forKey: "outputDirectory") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if configuredPath.isEmpty {
            return AppPaths.outputsDir
        }

        let expandedPath = (configuredPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath, isDirectory: true)
    }

    /// Generate an output file path with timestamp and text snippet.
    static func makeOutputPath(subfolder: String, text: String) -> String {
        let outputsDir = configuredOutputsRoot.appendingPathComponent(subfolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: outputsDir, withIntermediateDirectories: true)

        let timestamp = Self.timestampFormatter.string(from: Date())
        let cleanText = text
            .replacingOccurrences(of: "[^\\w\\s-]", with: "", options: .regularExpression)
            .prefix(20)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
        let filename = "\(timestamp)_\(cleanText.isEmpty ? "audio" : cleanText).wav"
        return outputsDir.appendingPathComponent(filename).path
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HH-mm-ss-SSS"
        return f
    }()
}

/// Global convenience function used by generate views.
func makeOutputPath(subfolder: String, text: String) -> String {
    AudioService.makeOutputPath(subfolder: subfolder, text: text)
}
