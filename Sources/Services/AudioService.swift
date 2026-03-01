import Foundation

/// Utility functions for audio file management.
enum AudioService {
    static var shouldAutoPlay: Bool {
        if UserDefaults.standard.object(forKey: "autoPlay") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "autoPlay")
    }

    private static var configuredOutputsRoot: URL {
        let configuredPath = (UserDefaults.standard.string(forKey: "outputDirectory") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if configuredPath.isEmpty {
            return QwenVoiceApp.outputsDir
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
        f.dateFormat = "HH-mm-ss-SSS"
        return f
    }()
}

/// Global convenience function used by generate views.
func makeOutputPath(subfolder: String, text: String) -> String {
    AudioService.makeOutputPath(subfolder: subfolder, text: text)
}
