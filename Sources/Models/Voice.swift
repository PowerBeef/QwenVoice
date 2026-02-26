import Foundation

/// An enrolled voice reference for voice cloning.
struct Voice: Identifiable, Hashable {
    let id: String          // same as name
    let name: String
    let wavPath: String
    let hasTranscript: Bool

    var transcript: String? {
        let txtPath = wavPath.replacingOccurrences(of: ".wav", with: ".txt")
        guard FileManager.default.fileExists(atPath: txtPath) else { return nil }
        return try? String(contentsOfFile: txtPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Initialize from a Python backend response
    init(from rpcValue: [String: RPCValue]) {
        self.name = rpcValue["name"]?.stringValue ?? ""
        self.id = self.name
        self.wavPath = rpcValue["wav_path"]?.stringValue ?? ""
        self.hasTranscript = rpcValue["has_transcript"]?.boolValue ?? false
    }

    init(name: String, wavPath: String, hasTranscript: Bool) {
        self.id = name
        self.name = name
        self.wavPath = wavPath
        self.hasTranscript = hasTranscript
    }
}
