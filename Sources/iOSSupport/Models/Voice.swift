import Foundation
import QwenVoiceCore

extension PreparedVoice {
    var wavPath: String {
        audioPath
    }

    func loadTranscript(fileManager: FileManager = .default) throws -> String? {
        let txtURL = URL(fileURLWithPath: audioPath).deletingPathExtension().appendingPathExtension("txt")
        guard fileManager.fileExists(atPath: txtURL.path) else { return nil }
        return try String(contentsOfFile: txtURL.path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(name: String, wavPath: String, hasTranscript: Bool) {
        self.init(
            id: name,
            name: name,
            audioPath: wavPath,
            hasTranscript: hasTranscript
        )
    }
}
