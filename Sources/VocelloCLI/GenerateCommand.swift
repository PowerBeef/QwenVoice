import Foundation
import QwenVoiceCore

/// `vocello generate` — synthesize one clip headlessly via the in-process engine.
enum GenerateCommand {
    @MainActor
    static func run(_ argv: [String]) async throws {
        let args = Args(argv)
        if args.flag("help") { printHelp(); return }

        let modeStr = (args.string("mode") ?? "custom").lowercased()
        guard let mode = GenerationMode(rawValue: modeStr) else {
            throw CLIError("invalid --mode '\(modeStr)' (use custom | design | clone)")
        }
        let quality: Bool
        switch (args.string("variant") ?? "speed").lowercased() {
        case "speed", "fast": quality = false
        case "quality", "hq": quality = true
        case let other: throw CLIError("invalid --variant '\(other)' (use speed | quality)")
        }

        let text = try resolveText(args)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError("empty text — pass --text \"…\" or --text-file <path>")
        }

        let dataDir = CLIPaths.dataDirectory(override: args.string("data-dir"))
        let manifestOverride = args.string("manifest").map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }

        note("booting engine (data: \(dataDir.path))")
        let runtime = try await CLIRuntime.bootstrap(dataDirectory: dataDir, manifestOverride: manifestOverride)
        let modelID = try runtime.modelID(mode: mode, quality: quality)

        let payload: GenerationRequest.Payload
        switch mode {
        case .custom:
            let speakerID = args.string("speaker") ?? runtime.defaultSpeakerID
            payload = .custom(speakerID: speakerID, deliveryStyle: args.string("delivery"))
        case .design:
            let brief = try args.require("voice-brief", "a voice description for Voice Design")
            payload = .design(voiceDescription: brief, deliveryStyle: args.string("delivery"))
        case .clone:
            throw CLIError("clone mode lands in the next phase (needs a saved voice) — use custom or design for now")
        }

        let outputPath = resolveOutputPath(args, dataDir: dataDir, mode: mode)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outputPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)

        note("loading \(modelID)…")
        try await runtime.engine.loadModel(id: modelID)

        let request = GenerationRequest(
            mode: mode, modelID: modelID, text: text, outputPath: outputPath,
            shouldStream: false, payload: payload, generationID: UUID())

        note("generating (\(text.count) chars)…")
        let result = try await runtime.engine.generate(request)

        // stdout = machine-readable (the path). stderr = human notes.
        print(result.audioPath)
        note("✓ \(String(format: "%.2f", result.durationSeconds))s · finish=\(result.finishReason?.rawValue ?? "?")")

        if args.flag("play") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            p.arguments = [result.audioPath]
            try? p.run(); p.waitUntilExit()
        }
    }

    private static func resolveText(_ args: Args) throws -> String {
        if let t = args.string("text") { return t }
        if let f = args.string("text-file") {
            return try String(contentsOfFile: (f as NSString).expandingTildeInPath, encoding: .utf8)
        }
        throw CLIError("missing text — pass --text \"…\" or --text-file <path>")
    }

    private static func resolveOutputPath(_ args: Args, dataDir: URL, mode: GenerationMode) -> String {
        if let out = args.string("out") { return (out as NSString).expandingTildeInPath }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return dataDir
            .appendingPathComponent("outputs/cli", isDirectory: true)
            .appendingPathComponent("\(fmt.string(from: Date()))_\(mode.rawValue).wav").path
    }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("• \(message)\n".utf8))
    }

    static func printHelp() {
        print("""
        vocello generate — synthesize a clip headlessly

        Usage:
          vocello generate --mode custom|design|clone --variant speed|quality \\
                           (--text "…" | --text-file <path>) [--out <path>] [options]

        Options:
          --mode         custom (default) | design | clone
          --variant      speed (default) | quality
          --text         inline script text
          --text-file    read script text from a file
          --speaker      (custom) speaker id; default = contract default
          --voice-brief  (design) voice description
          --delivery     optional delivery style
          --out          output .wav path; default → <data>/outputs/cli/
          --data-dir     runtime dir (default ~/Library/Application Support/QwenVoice[-Debug])
          --manifest     override path to qwenvoice_contract.json
          --play         play the result with afplay when done

        Prints the output WAV path on stdout.
        """)
    }
}
