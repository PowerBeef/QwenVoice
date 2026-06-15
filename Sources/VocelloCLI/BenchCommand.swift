import Foundation
import QwenVoiceCore

/// `vocello bench` — the deterministic benchmark/perf driver: drives the matrix
/// (mode × variant × length × cold/warm) in-process with telemetry on,
/// controlling cold/warm exactly via explicit load/unload (no UI waits, no
/// engine-busy races). Then runs the aggregator. Engine telemetry rows (RTF /
/// decode / memory / audioQC / promptChars) are written exactly as in the app.
/// With `--delivery`, it also runs a reference-free prosody analysis on the
/// paired neutral-vs-instructed WAVs and surfaces the deltas in the summary.
enum BenchCommand {
    /// Fixed corpus — keep identical to benchmarks/baseline-*-length-sweep.md.
    static let corpus: [(len: String, text: String)] = [
        ("short", "The train left the station at dawn."),
        ("medium", "The morning train slipped quietly out of the station, carrying a handful of sleepy travelers toward the coast."),
        ("long", "The morning train slipped quietly out of the station, carrying a handful of sleepy travelers toward the coast. Outside the fogged windows, pale fields gave way to grey water, and the rhythm of the rails settled into a steady, hypnotic hum. By the time the sun finally broke through, most of the passengers had drifted into an unhurried silence."),
    ]
    static let defaultDesignBrief = "A warm, calm middle-aged male narrator with a clear, measured pace."
    static let defaultCloneVoice = "A_warm_elderly_woman"

    /// Default delivery cells for `--delivery` (bare flag): one expressive, one
    /// calm, one whisper — the three preset families with distinct acoustic
    /// signatures, so QC + the prosody gate cover the delivery spectrum.
    static let defaultDeliverySet = ["happy.strong", "calm.normal", "whisper.normal"]

    /// Bucket a prompt char count into the short/medium/long labels used for
    /// filenames and the telemetry `lenBucket`. Mirrors the logic in
    /// `scripts/summarize_generation_telemetry.py`.
    static func lenBucket(_ chars: Int) -> String {
        chars == 0 ? "n/a" : chars < 70 ? "short" : chars > 220 ? "long" : "medium"
    }

    /// A resolved delivery cell: `id` is the stable `<preset>.<intensity>` token
    /// (stamped into the telemetry note + filename), `instruction` the preset's
    /// instruction string sent as `deliveryStyle`.
    struct DeliveryItem {
        let id: String
        let instruction: String
    }

    /// Parse `--delivery` items (`<preset>[.<intensity>]`, intensity defaults to
    /// normal) against the shared EmotionPreset table. Fails loudly on unknown
    /// presets/intensities and on neutral (which sends no instruction — a plain
    /// warm take already covers it).
    static func resolveDeliveryItems(_ spec: String?) throws -> [DeliveryItem] {
        let tokens = parseList(spec) ?? defaultDeliverySet
        return try tokens.map { token in
            let parts = token.split(separator: ".").map(String.init)
            guard (1...2).contains(parts.count),
                  let preset = EmotionPreset.preset(id: parts[0]) else {
                let known = EmotionPreset.all.map(\.id).joined(separator: ", ")
                throw CLIError("unknown delivery preset '\(token)' (use <preset>[.<intensity>]; presets: \(known))")
            }
            guard preset.id != "neutral" else {
                throw CLIError("delivery cell 'neutral' is redundant — the plain warm take already runs without an instruction")
            }
            let intensity: EmotionIntensity
            if parts.count == 2 {
                guard let resolved = EmotionIntensity.allCases.first(where: { $0.rpcValue == parts[1] }) else {
                    throw CLIError("unknown delivery intensity '\(parts[1])' (use subtle | normal | strong)")
                }
                intensity = resolved
            } else {
                intensity = .normal
            }
            return DeliveryItem(
                id: "\(preset.id).\(intensity.rpcValue)",
                instruction: preset.instruction(for: intensity)
            )
        }
    }

    @MainActor
    static func run(_ argv: [String]) async throws {
        let args = Args(argv)
        if args.flag("help") { printHelp(); return }
        CLIOutput.configure(args)

        // Invariant: the filename length token is derived via the same lenBucket
        // the summarizer uses, so producer and consumer agree by construction.
        // Fail loudly if a corpus edit drifts past a threshold.
        for c in corpus where lenBucket(c.text.count) != c.len {
            throw CLIError("corpus drift: '\(c.len)' text buckets as '\(lenBucket(c.text.count))' (\(c.text.count) chars) — adjust the corpus or lenBucket thresholds")
        }

        // Telemetry on (in-process) regardless of env; default to the debug-isolated
        // data dir (holds the full model set) unless --data-dir is given.
        // --telemetry verbose adds the raw per-sample sidecars (the env var carries
        // it to the sampler).
        let telemetryVerbose = (args.string("telemetry") ?? "lightweight").lowercased() == "verbose"
        TelemetryGate.applyHandshakeMode(telemetryVerbose ? .verbose : .lightweight)
        if telemetryVerbose { setenv("QWENVOICE_NATIVE_TELEMETRY_MODE", "verbose", 1) }
        setenv("QWENVOICE_DEBUG", "1", 0)

        // --force-class: run constrained-tier code paths on any Mac. Must be set
        // before the device class is first resolved (i.e. before bootstrap).
        if let tier = args.string("force-class") {
            let canonical = try canonicalForceClass(tier)
            setenv("QWENVOICE_FORCE_MEMORY_CLASS", canonical, 1)
            note("forcing memory class: \(canonical)")
        }

        var modes = parseList(args.string("modes")) ?? ["custom", "design", "clone"]
        let variants = parseList(args.string("variants")) ?? ["speed", "quality"]
        let lengths = parseList(args.string("lengths")) ?? ["short", "medium", "long"]
        let warm = max(1, Int(args.string("warm") ?? "3") ?? 3)
        let designBrief = args.string("voice-brief") ?? defaultDesignBrief
        let cloneVoiceName = args.string("voice") ?? defaultCloneVoice
        let ttfc = args.flag("ttfc")
        // --delivery [list]: instruct-bearing cells on top of the plain matrix.
        // Value form picks the cells; the bare flag runs the default set.
        let deliveryItems: [DeliveryItem]
        if let deliverySpec = args.string("delivery") {
            deliveryItems = try resolveDeliveryItems(deliverySpec)
        } else if args.flag("delivery") {
            deliveryItems = try resolveDeliveryItems(nil)
        } else {
            deliveryItems = []
        }

        let dataDir = CLIPaths.dataDirectory(override: args.string("data-dir"))
        if !args.flag("keep") {
            try clearDiagnosticsIfSafe(dataDir: dataDir, force: args.flag("force"))
        }

        note("bench • data: \(dataDir.path)")
        let runtime = try await CLIRuntime.bootstrap(
            dataDirectory: dataDir,
            manifestOverride: args.string("manifest").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })

        let outDir = dataDir.appendingPathComponent("outputs/bench", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // --- Preflight (fail fast / auto-skip up front, not mid-matrix) ---
        // Clone needs a saved voice; if absent, auto-skip clone unless it's the only mode.
        var cloneReference: CloneReference?
        if modes.contains("clone") {
            let voices = try await runtime.engine.listPreparedVoices()
            let have = voices.map(\.name).joined(separator: ", ")
            if let v = voices.first(where: { $0.name == cloneVoiceName || $0.id == cloneVoiceName }) {
                cloneReference = CloneReference(audioPath: v.audioPath, transcript: nil, preparedVoiceID: v.id)
            } else if modes == ["clone"] {
                throw CLIError("clone bench needs saved voice '\(cloneVoiceName)' (have: \(have.isEmpty ? "none" : have))")
            } else {
                note("preflight: no saved voice '\(cloneVoiceName)' — skipping clone (have: \(have.isEmpty ? "none" : have))")
                modes.removeAll { $0 == "clone" }
            }
        }
        // Every requested (mode × variant) model must be installed — fail fast.
        try preflightModels(runtime: runtime, modes: modes, variants: variants, dataDir: dataDir)

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

                // Delivery cells (--delivery): instruct-bearing warm takes on the
                // medium text, one per requested preset.intensity. Custom/Design
                // only — the clone checkpoints have no instruction control. The
                // plain warm takes above double as the neutral reference for the
                // listening comparison; the summarizer segregates these rows via
                // the notes.delivery stamp so the headline matrix stays clean.
                if !deliveryItems.isEmpty, mode != .clone, let deliveryText = text(for: "medium") {
                    for item in deliveryItems {
                        let deliveryPayload = try Self.payload(
                            for: mode, customSpeaker: runtime.defaultSpeakerID,
                            designBrief: designBrief, cloneReference: cloneReference,
                            deliveryStyle: item.instruction)
                        try await take(runtime, mode: mode, modelID: modelID, payload: deliveryPayload,
                                       len: "medium", text: deliveryText, state: "warm", n: 0,
                                       outDir: outDir, delivery: item.id)
                        total += 1
                    }
                }
            }
        }

        note("✓ \(total) takes in \(String(format: "%.0f", Date().timeIntervalSince(started)))s")

        let diagDir = dataDir.appendingPathComponent("diagnostics", isDirectory: true)
        let label = args.string("label") ?? ""
        if !args.flag("no-summary") {
            runSummarizer(diagnostics: diagDir, label: label)
            // Prosody analysis for --delivery takes: deterministic, reference-free,
            // complements audioQC with tone/cadence deltas vs the paired neutral take.
            if !deliveryItems.isEmpty {
                runDeliveryProsodyAnalysis(diagnostics: diagDir)
            }
        }
        if args.flag("ledger") {
            appendLedgerRow(diagnostics: diagDir, label: label)
        }

        // Optional engine first-chunk-latency probe. Runs AFTER the summary so its
        // streaming rows don't perturb the headline (non-streaming) RTF/decode table.
        // This is engine-side TTFC — not the app's through-XPC TTFA.
        if ttfc {
            note("ttfc probe (warm streaming, after summary)…")
            var rows: [TTFCRow] = []
            for modeStr in modes {
                guard let mode = GenerationMode(rawValue: modeStr) else { continue }
                for variantStr in variants {
                    let quality = variantStr.lowercased() == "quality"
                    guard let modelID = try? runtime.modelID(mode: mode, quality: quality) else { continue }
                    guard let probeLen = coldLen ?? lengths.first, let probeText = text(for: probeLen) else { continue }
                    let payload = try payload(for: mode, customSpeaker: runtime.defaultSpeakerID,
                                              designBrief: designBrief, cloneReference: cloneReference)
                    try await runtime.engine.loadModel(id: modelID)  // warm
                    let out = outDir.appendingPathComponent("\(mode.rawValue)_\(modelID)_ttfcprobe.wav").path
                    let request = GenerationRequest(
                        mode: mode, modelID: modelID, text: probeText, outputPath: out,
                        shouldStream: true, streamingInterval: GenerationSemantics.appStreamingInterval,
                        payload: payload, generationID: UUID())
                    let (_, ms, _) = try await GenerateCommand.generateObservingFirstChunk(runtime, request)
                    rows.append(TTFCRow(mode: mode.rawValue, variant: quality ? "quality" : "speed",
                                        modelID: modelID, firstChunkMS: ms))
                    note("  ttfc \(mode.rawValue)/\(quality ? "Q" : "S"): \(ms.map { String(format: "%.0f", $0) } ?? "-")ms")
                }
            }
            reportTTFC(rows, diagnostics: diagDir)
        }

    }

    // MARK: - One take

    @MainActor
    private static func take(_ runtime: CLIRuntime, mode: GenerationMode, modelID: String,
                             payload: GenerationRequest.Payload, len: String, text: String,
                             state: String, n: Int, outDir: URL, delivery: String? = nil) async throws {
        // Bucket the char count with the SAME function the summarizer uses, so
        // the filename and the telemetry row agree by construction regardless of
        // the bucket thresholds.
        let lenToken = lenBucket(text.count)
        // Delivery takes extend the state token (`warm_d-<preset>.<intensity>`)
        // so the filename and the engine row's notes.delivery stamp agree.
        let stateToken = delivery.map { "\(state)_d-\($0)" } ?? state
        let out = outDir.appendingPathComponent("\(mode.rawValue)_\(modelID)_\(lenToken)_\(stateToken)_\(n).wav").path
        let request = GenerationRequest(
            mode: mode, modelID: modelID, text: text, outputPath: out,
            shouldStream: false, payload: payload, generationID: UUID())
        if let delivery { setenv("QWENVOICE_BENCH_DELIVERY", delivery, 1) }
        defer { if delivery != nil { unsetenv("QWENVOICE_BENCH_DELIVERY") } }
        let t0 = Date()
        let result = try await runtime.engine.generate(request)
        let wall = Date().timeIntervalSince(t0)
        let deliveryTag = delivery.map { "/\($0)" } ?? ""
        FileHandle.standardError.write(Data(
            "  \(mode.rawValue)/\(modelID.hasSuffix("quality") ? "Q" : "S")/\(len)/\(state)\(deliveryTag)#\(n)  \(String(format: "%.2f", result.durationSeconds))s audio in \(String(format: "%.1f", wall))s\n".utf8))
    }

    private static func payload(for mode: GenerationMode, customSpeaker: String, designBrief: String,
                                cloneReference: CloneReference?, deliveryStyle: String? = nil) throws -> GenerationRequest.Payload {
        switch mode {
        case .custom: return .custom(speakerID: customSpeaker, deliveryStyle: deliveryStyle)
        case .design: return .design(voiceDescription: designBrief, deliveryStyle: deliveryStyle)
        case .clone:
            guard let cloneReference else { throw CLIError("clone reference unavailable") }
            return .clone(reference: cloneReference)
        }
    }

    private static func text(for len: String) -> String? {
        corpus.first { $0.len == len }?.text
    }

    private static func runSummarizer(diagnostics: URL, label: String) {
        guard let scriptURL = locateSummarizer() else {
            note("(summarizer scripts/summarize_generation_telemetry.py not found from \(FileManager.default.currentDirectoryPath); run it manually on \(diagnostics.path))")
            return
        }
        note("aggregating →")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var pargs = ["python3", scriptURL.path, diagnostics.path]
        if !label.isEmpty { pargs += ["--label", label] }
        p.arguments = pargs
        try? p.run()
        p.waitUntilExit()
    }

    /// Resolve the repo-relative summarizer by walking up from cwd (mirrors
    /// manifest discovery), so bench works from any subdirectory of the repo.
    private static func locateSummarizer() -> URL? {
        let rel = "scripts/summarize_generation_telemetry.py"
        let cwd = FileManager.default.currentDirectoryPath
        if FileManager.default.fileExists(atPath: cwd + "/" + rel) { return URL(fileURLWithPath: cwd + "/" + rel) }
        return CLIRuntime.findUpwards(relativePath: rel, from: cwd)
    }

    private static func runDeliveryProsodyAnalysis(diagnostics: URL) {
        let rel = "scripts/bench_delivery_prosody.py"
        let cwd = FileManager.default.currentDirectoryPath
        var scriptURL: URL?
        if FileManager.default.fileExists(atPath: cwd + "/" + rel) {
            scriptURL = URL(fileURLWithPath: cwd + "/" + rel)
        } else {
            scriptURL = CLIRuntime.findUpwards(relativePath: rel, from: cwd)
        }
        guard let scriptURL else {
            note("(delivery prosody script not found from \(FileManager.default.currentDirectoryPath); skip)")
            return
        }
        note("prosody analysis for delivery cells →")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", scriptURL.path, diagnostics.path]
        try? p.run()
        p.waitUntilExit()
    }

    /// --ledger: capture the summarizer's one-line Markdown ledger row and append
    /// it to benchmarks/HISTORY.md (the perf-over-time ledger). The committed-log
    /// guard caps benchmarks/ files at 256 KB — a ledger of rows stays well under.
    private static func appendLedgerRow(diagnostics: URL, label: String) {
        guard let scriptURL = locateSummarizer() else { note("(--ledger: summarizer not found; skip)"); return }
        let cwd = FileManager.default.currentDirectoryPath
        let historyURL: URL?
        if FileManager.default.fileExists(atPath: cwd + "/benchmarks/HISTORY.md") {
            historyURL = URL(fileURLWithPath: cwd + "/benchmarks/HISTORY.md")
        } else {
            historyURL = CLIRuntime.findUpwards(relativePath: "benchmarks/HISTORY.md", from: cwd)
        }
        guard let historyURL else { note("(--ledger: benchmarks/HISTORY.md not found; skip)"); return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var pargs = ["python3", scriptURL.path, diagnostics.path, "--ledger-row"]
        if !label.isEmpty { pargs += ["--label", label] }
        p.arguments = pargs
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { note("(--ledger: \(error.localizedDescription))"); return }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0,
              let row = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !row.isEmpty else {
            note("(--ledger: summarizer produced no row)"); return
        }
        if let fh = try? FileHandle(forWritingTo: historyURL) {
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            if let d = (row + "\n").data(using: .utf8) { fh.write(d) }
            note("ledger row appended → \(historyURL.path)")
        } else {
            note("(--ledger: could not open \(historyURL.path) for append)")
        }
    }

    private static func canonicalForceClass(_ raw: String) throws -> String {
        switch raw.lowercased() {
        case "floor_8gb_mac", "8gb", "8": return "floor_8gb_mac"
        case "mid_16gb_mac", "16gb", "16": return "mid_16gb_mac"
        case "high_memory_mac", "high": return "high_memory_mac"
        case "iphone_pro", "iphone": return "iphone_pro"
        default:
            throw CLIError("invalid --force-class '\(raw)' (use 8gb | 16gb | high | iphone, or the canonical *_mac names)")
        }
    }

    /// The shipped app's real (non-debug) data dir — never auto-cleared.
    private static func realAppDataDir() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/Application Support"), isDirectory: true)
        return base.appendingPathComponent("QwenVoice", isDirectory: true)
    }

    /// Clear this run's diagnostics, but refuse to wipe the shipped app's real
    /// data dir unless --force (bench forces QWENVOICE_DEBUG=1 so the default
    /// resolves to QwenVoice-Debug; this guards an explicit --data-dir <real>).
    private static func clearDiagnosticsIfSafe(dataDir: URL, force: Bool) throws {
        if !force, dataDir.standardizedFileURL.path == realAppDataDir().standardizedFileURL.path {
            throw CLIError("refusing to clear diagnostics in the real app data dir (\(dataDir.path)); pass --keep to append or --force to override")
        }
        // Start clean so the aggregate reflects only this run.
        try? FileManager.default.removeItem(at: dataDir.appendingPathComponent("diagnostics", isDirectory: true))
    }

    struct TTFCRow: Encodable {
        let mode: String
        let variant: String
        let modelID: String
        let firstChunkMS: Double?
    }

    /// Fail fast if any requested (mode × variant) model isn't installed — so a
    /// missing model is reported up front, not after part of the matrix has run.
    @MainActor
    private static func preflightModels(runtime: CLIRuntime, modes: [String], variants: [String], dataDir: URL) throws {
        let modelsDir = dataDir.appendingPathComponent("models", isDirectory: true)
        var missing: [String] = []
        for modeStr in modes {
            guard let mode = GenerationMode(rawValue: modeStr) else { continue }
            for variantStr in variants {
                let quality = variantStr.lowercased() == "quality"
                guard let id = try? runtime.modelID(mode: mode, quality: quality) else { continue }
                if case .available = runtime.registry.availability(forModelID: id, in: modelsDir) { continue }
                missing.append(id)
            }
        }
        guard missing.isEmpty else {
            let uniq = Array(Set(missing)).sorted().joined(separator: ", ")
            throw CLIError("preflight: missing models — \(uniq). Install them in the app (Settings → Model Downloads), or point --data-dir at a populated models dir.")
        }
    }

    /// Print the engine first-chunk-latency table (stderr) + write a sidecar JSON.
    private static func reportTTFC(_ rows: [TTFCRow], diagnostics: URL) {
        guard !rows.isEmpty else { return }
        FileHandle.standardError.write(Data(
            "\nEngine first-chunk latency (TTFC, ms) — warm streaming probe (engine-side, not app/XPC TTFA)\n".utf8))
        for r in rows {
            let ms = r.firstChunkMS.map { String(format: "%.0f", $0) } ?? "-"
            FileHandle.standardError.write(Data("  \(r.mode)/\(r.variant)\t\(ms)\n".utf8))
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(rows) {
            try? FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
            let url = diagnostics.appendingPathComponent("bench-ttfc.json")
            try? data.write(to: url)
            note("wrote \(url.path)")
        }
    }

    private static func parseList(_ s: String?) -> [String]? {
        guard let s, !s.isEmpty else { return nil }
        return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    static func printHelp() {
        print("""
        vocello bench — drive the perf/quality matrix headlessly + aggregate

        Usage:
          vocello bench [--modes custom,design,clone] [--variants speed,quality] \\
                        [--lengths short,medium,long] [--warm 3] [options]

        Per cell: 1 cold (medium) for Custom/Design + N warm per length; Voice
        Cloning is warm-only. Telemetry is forced on; results land in
        <data>/diagnostics and are summarized by scripts/summarize_generation_telemetry.py.

        Measures engine truth — RTF / decode / memory / audioQC. It does NOT capture
        the app's end-to-end through-XPC latency (TTFC/TTFA) or the merged 3-layer row
        (use the app for those); --ttfc adds an engine-side first-chunk probe.
        Prerequisites: the requested models installed; a saved clone voice for clone
        (else clone is auto-skipped).

        Options:
          --modes        comma list (default custom,design,clone)
          --variants     comma list (default speed,quality)
          --lengths      comma list (default short,medium,long)
          --warm         warm reps per (cell × length); default 3
          --voice        (clone) saved voice name; default \(defaultCloneVoice)
          --voice-brief  (design) brief; default the standard narrator brief
          --delivery [list]  add instruct-bearing cells (Custom/Design, warm, medium
                         text, 1 take each): comma list of <preset>[.<intensity>]
                         (e.g. happy.strong,calm.normal); bare flag runs the
                         default set (\(defaultDeliverySet.joined(separator: ","))).
                         Rows are stamped notes.delivery and summarized in their
                         own block so the headline matrix stays comparable; the
                         plain warm takes double as the neutral reference. Also
                         triggers a numpy-only prosody analysis (pitch dynamics,
                         rate variability, pauses, energy roughness) vs the paired
                         neutral take; results appear in the delivery table.
          --label "<n>"  stamp a note on the summary / ledger row
          --ledger       append a one-line row to benchmarks/HISTORY.md (perf ledger)
          --force-class  run a constrained tier on any Mac: 8gb|16gb|high|iphone
          --telemetry    lightweight (default) | verbose (raw per-sample sidecars)
          --ttfc         add an engine first-chunk-latency probe per cell (warm
                         streaming) → table + diagnostics/bench-ttfc.json
          --data-dir     runtime dir; default the debug-isolated folder (full model set)
          --manifest     override path to qwenvoice_contract.json
          --keep         append to existing diagnostics (default: clear first)
          --force        allow clearing even the real (non-debug) app data dir
          --no-summary   skip running the aggregator
          --quiet|--verbose   suppress / expand stderr progress notes
        """)
    }
}
