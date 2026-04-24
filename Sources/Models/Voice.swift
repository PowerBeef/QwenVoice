import Foundation
import QwenVoiceNative

/// An enrolled voice reference for voice cloning.
struct Voice: Identifiable, Hashable {
    let id: String          // same as name
    let name: String
    let wavPath: String
    let hasTranscript: Bool

    func loadTranscript(fileManager: FileManager = .default) throws -> String? {
        let txtURL = URL(fileURLWithPath: wavPath).deletingPathExtension().appendingPathExtension("txt")
        guard fileManager.fileExists(atPath: txtURL.path) else { return nil }
        return try String(contentsOfFile: txtURL.path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(name: String, wavPath: String, hasTranscript: Bool) {
        self.id = name
        self.name = name
        self.wavPath = wavPath
        self.hasTranscript = hasTranscript
    }

    init(preparedVoice: PreparedVoice) {
        self.id = preparedVoice.id
        self.name = preparedVoice.name
        self.wavPath = preparedVoice.audioPath
        self.hasTranscript = preparedVoice.hasTranscript
    }
}
