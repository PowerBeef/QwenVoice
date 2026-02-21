import Foundation

/// Utility functions for audio file management.
enum AudioService {
    /// Generate an output file path with timestamp and text snippet.
    static func makeOutputPath(subfolder: String, text: String) -> String {
        let outputsDir = QwenVoiceApp.outputsDir.appendingPathComponent(subfolder)
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
        f.dateFormat = "HH-mm-ss"
        return f
    }()
}

/// Global convenience function used by generate views.
func makeOutputPath(subfolder: String, text: String) -> String {
    AudioService.makeOutputPath(subfolder: subfolder, text: text)
}
