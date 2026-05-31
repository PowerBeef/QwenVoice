import Foundation
import QwenVoiceCore

/// `vocello bench` — the deterministic benchmark/perf driver. Replaces the
/// computer-use UI-driving: drives the matrix (mode × variant × length ×
/// cold/warm) in-process with telemetry on, controlling cold/warm exactly via
/// explicit load/unload (no UI waits, no engine-busy races). Then runs the
/// aggregator. Engine telemetry rows (RTF / decode / memory / audioQC /
/// promptChars) are written exactly as in the app.
enum BenchCommand {
    /// Fixed corpus — keep identical to benchmarks/baseline-*-length-sweep.md.
    static let corpus: [(len: String, text: String)] = [
        ("short", "The train left the station at dawn."),
        ("medium", "The morning train slipped quietly out of the station, carrying a handful of sleepy travelers toward the coast."),
        ("long", "The morning train slipped quietly out of the station, carrying a handful of sleepy travelers toward the coast. Outside the fogged windows, pale fields gave way to grey water, and the rhythm of the rails settled into a steady, hypnotic hum. By the time the sun finally broke through, most of the passengers had drifted into an unhurried silence."),
    ]
    static let defaultDesignBrief = "A warm, calm middle-aged male narrator with a clear, measured pace."
    static let defaultCloneVoice = "A_warm_elderly_woman"

    @MainActor
    static func run(_ argv: [String]) async throws {
        let args = Args(argv)
        if args.flag("help") { printHelp(); return }

        // Telemetry on (in-process) regardless of env; default to the debug-isolated
        // data dir (holds the full model set) unless --data-dir is given.
        TelemetryGate.applyHandshakeMode(.lightweight)
        setenv("QWENVOICE_DEBUG", "1", 0)

        let modes = parseList(args.string("modes")) ?? ["custom", "design", "clone"]
        let variants = parseList(args.string("variants")) ?? ["speed", "quality"]
        let lengths = parseList(args.string("lengths")) ?? ["short", "medium", "long"]
        let warm = max(1, Int(args.string("warm") ?? "3") ?? 3)
        let designBrief = args.string("voice-brief") ?? defaultDesignBrief
        let cloneVoiceName = args.string("voice") ?? defaultCloneVoice

        let dataDir = CLIPaths.dataDirectory(override: args.string("data-dir"))
        if !args.flag("keep") {
            // Start clean so the aggregate reflects only this run.
            try? FileManager.default.removeItem(at: dataDir.appendingPathComponent("diagnostics", isDirectory: true))
        }

        note("bench • data: \(dataDir.path)")
        let runtime = try await CLIRuntime.bootstrap(
            dataDirectory: dataDir,
            manifestOverride: args.string("manifest").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })

        let outDir = dataDir.appendingPathComponent("outputs/bench", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // Resolve the clone reference once if clone is in the matrix.
        var cloneReference: CloneReference?
        if modes.contains("clone") {
            let voices = try await runtime.engine.listPreparedVoices()
            guard let v = voices.first(where: { $0.name == cloneVoiceName || $0.id == cloneVoiceName }) else {
                throw CLIError("clone bench needs saved voice '\(cloneVoiceName)' (have: \(voices.map(\.name).joined(separator: ", ")))")
            }
            cloneReference = CloneReference(audioPath: v.audioPath, transcript: nil, preparedVoiceID: v.id)
        }

        let coldLen = lengths.contains("medium") ? "medium" : lengths.first
        var total = 0
        let started = Date()

        for modeStr in modes {
            guard let mode = GenerationMode(rawValue: modeStr) else {
                note("skip unknown mode '\(modeStr)'"); continue
            }
            for variantStr in variants {
                let quality = variantStr.lowercased() == "quality"
                let modelID: String
                do { modelID = try runtime.modelID(mode: mode, quality: quality) }
                catch { note("skip \(modeStr)/\(variantStr): \(error)"); continue }

                let payload = try payload(for: mode, customSpeaker: runtime.defaultSpeakerID,
                                          designBrief: designBrief, cloneReference: cloneReference)

                // Force cold for this cell: unload whatever's loaded so the next
                // generate loads inside the call (records warmState=cold).
                try? await runtime.engine.unloadModel()

                // Cold sample (Custom/Design only — Clone is warm-by-design).
                if mode != .clone, let coldLen, let coldText = text(for: coldLen) {
                    try await take(runtime, mode: mode, modelID: modelID, payload: payload,
                                   len: coldLen, text: coldText, state: "cold", n: 0, outDir: outDir)
                    total += 1
                }
                // Warm samples per requested length.
                for len in lengths {
                    guard let t = text(for: len) else { continue }
                    for n in 0..<warm {
                        try await take(runtime, mode: mode, modelID: modelID, payload: payload,
                                       len: len, text: t, state: "warm", n: n, outDir: outDir)
                        total += 1
                    }
                }
            }
        }

        note("✓ \(total) takes in \(String(format: "%.0f", Date().timeIntervalSince(started)))s")

        if !args.flag("no-summary") {
            runSummarizer(diagnostics: dataDir.appendingPathComponent("diagnostics", isDirectory: true))
        }
    }

    // MARK: - One take

    @MainActor
    private static func take(_ runtime: CLIRuntime, mode: GenerationMode, modelID: String,
                             payload: GenerationRequest.Payload, len: String, text: String,
                             state: String, n: Int, outDir: URL) async throws {
        let out = outDir.appendingPathComponent("\(mode.rawValue)_\(modelID)_\(len)_\(state)_\(n).wav").path
        let request = GenerationRequest(
            mode: mode, modelID: modelID, text: text, outputPath: out,
            shouldStream: false, payload: payload, generationID: UUID())
        let t0 = Date()
        let result = try await runtime.engine.generate(request)
        let wall = Date().timeIntervalSince(t0)
        FileHandle.standardError.write(Data(
            "  \(mode.rawValue)/\(modelID.hasSuffix("quality") ? "Q" : "S")/\(len)/\(state)#\(n)  \(String(format: "%.2f", result.durationSeconds))s audio in \(String(format: "%.1f", wall))s\n".utf8))
    }

    private static func payload(for mode: GenerationMode, customSpeaker: String, designBrief: String,
                                cloneReference: CloneReference?) throws -> GenerationRequest.Payload {
        switch mode {
        case .custom: return .custom(speakerID: customSpeaker, deliveryStyle: nil)
        case .design: return .design(voiceDescription: designBrief, deliveryStyle: nil)
        case .clone:
            guard let cloneReference else { throw CLIError("clone reference unavailable") }
            return .clone(reference: cloneReference)
        }
    }

    private static func text(for len: String) -> String? {
        corpus.first { $0.len == len }?.text
    }

    private static func runSummarizer(diagnostics: URL) {
        let script = FileManager.default.currentDirectoryPath + "/scripts/summarize_generation_telemetry.py"
        guard FileManager.default.fileExists(atPath: script) else {
            note("(summarizer not found at \(script); run it manually on \(diagnostics.path))")
            return
        }
        note("aggregating →")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script, diagnostics.path]
        try? p.run()
        p.waitUntilExit()
    }

    private static func parseList(_ s: String?) -> [String]? {
        guard let s, !s.isEmpty else { return nil }
        return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    private static func note(_ m: String) { FileHandle.standardError.write(Data("• \(m)\n".utf8)) }

    static func printHelp() {
        print("""
        vocello bench — drive the perf/quality matrix headlessly + aggregate

        Usage:
          vocello bench [--modes custom,design,clone] [--variants speed,quality] \\
                        [--lengths short,medium,long] [--warm 3] [options]

        Per cell: 1 cold (medium) for Custom/Design + N warm per length; Voice
        Cloning is warm-only. Telemetry is forced on; results land in
        <data>/diagnostics and are summarized by scripts/summarize_generation_telemetry.py.

        Options:
          --modes        comma list (default custom,design,clone)
          --variants     comma list (default speed,quality)
          --lengths      comma list (default short,medium,long)
          --warm         warm reps per (cell × length); default 3
          --voice        (clone) saved voice name; default \(defaultCloneVoice)
          --voice-brief  (design) brief; default the standard narrator brief
          --data-dir     runtime dir; default the debug-isolated folder (full model set)
          --manifest     override path to qwenvoice_contract.json
          --keep         append to existing diagnostics (default: clear first)
          --no-summary   skip running the aggregator
        """)
    }
}
