import Foundation
import QwenVoiceCore

/// One clip's agy listening verdict — acoustic defect AND adherence (does the
/// audio actually say the text, follow the delivery instruction, and match the
/// voice description). Adherence fields are "yes"/"no"/"unclear"/"na".
struct AgyVerdict: Sendable {
    let clip: String
    let len: String
    let state: String
    let flags: [String]
    /// Bench delivery-cell id (`<preset>.<intensity>`) when the take carried a
    /// delivery instruction; nil for plain matrix takes.
    let delivery: String?
    /// Acoustic adjudication: real_defect | false_positive | uncertain
    let verdict: String
    let heard: String          // AUDIBLE_DEFECT | CLEAN | CANNOT_LISTEN | (raw)
    /// Adherence verdicts (agy multimodal hearing): yes | no | unclear | na.
    let textMatch: String      // do the spoken words match the expected text?
    let deliveryMatch: String  // does the tone/emotion/pace follow the delivery instruction?
    let voiceMatch: String     // does the voice character match the design description?
    let reason: String
}

/// Drives `agy` (Antigravity/Gemini) as the audio ear for review clips. agy's
/// multimodal input rejects the engine's 24 kHz Int16 WAV mime, so we transcode
/// to AAC/m4a (built-in `afconvert`) first, then hand agy the m4a to LISTEN and
/// judge (1) acoustic defect vs false positive, and (2) **adherence**: does the
/// audio say the expected text, follow the delivery instruction, and match the
/// voice-design description. Dev/benchmark workflow only — never part of the
/// shipped app; the product still keeps user audio on-device.
///
/// (A deterministic on-device ASR/WER cross-check via SFSpeechRecognizer is
/// deferred: the `vocello` CLI is a bare `tool` product with no bundle Info.plist
/// usage description, so Speech-framework authorization is unreliable from it.
/// agy's multimodal text-match is the reliable judge over the fixed corpus.)
enum AgyReviewer {
    static var isAvailable: Bool { resolveAgy() != nil && FileManager.default.isExecutableFile(atPath: "/usr/bin/afconvert") }

    @MainActor
    static func review(clip: String, text: String, len: String, state: String, flags: [String],
                       delivery: String? = nil,
                       voiceDescription: String? = nil,
                       deliveryInstruction: String? = nil) -> AgyVerdict {
        func v(_ verdict: String, _ heard: String, _ reason: String,
               textMatch: String = "na", deliveryMatch: String = "na", voiceMatch: String = "na") -> AgyVerdict {
            AgyVerdict(clip: clip, len: len, state: state, flags: flags, delivery: delivery,
                       verdict: verdict, heard: heard, textMatch: textMatch,
                       deliveryMatch: deliveryMatch, voiceMatch: voiceMatch, reason: reason)
        }
        guard let agy = resolveAgy() else { return v("uncertain", "NO_AGY", "agy not found on PATH") }

        // Transcode WAV → m4a (Gemini-friendly mime).
        let tmpDir = NSTemporaryDirectory()
        let m4a = tmpDir + "vocello_review_\(UUID().uuidString).m4a"
        let conv = run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", clip, m4a])
        guard conv.code == 0, FileManager.default.fileExists(atPath: m4a) else {
            return v("uncertain", "CONVERT_FAILED", "afconvert failed: \(conv.out.prefix(120))")
        }
        defer { try? FileManager.default.removeItem(atPath: m4a) }

        // Resolve the delivery instruction text agy judges against: prefer the
        // engine-logged instruction (exact text the model received), else derive
        // from the bench preset id.
        let resolvedDelivery = deliveryInstruction
            ?? delivery.flatMap { Self.deliveryInstruction(for: $0) }

        // Build the question set: acoustic always; text always; delivery + voice
        // only when there's a ground-truth instruction / description to judge.
        let flagList = flags.isEmpty ? "none" : flags.joined(separator: ", ")
        var sections = """
        Listen to the audio at: \(m4a) — actually ANALYZE THE AUDIO ACOUSTICS by hearing it (pitch, loudness, pace, timbre, emotional energy), NOT by reading a text transcript. Use ONLY your own multimodal audio hearing (do NOT use any external/cloud speech-to-text tool, and do NOT read project files). If you can only transcribe and cannot judge the actual sound, say CANNOT_LISTEN.
        EXPECTED TEXT: "\(text)"
        An automated reference-free acoustic detector flagged: \(flagList).
        """
        if let resolvedDelivery {
            sections += "\nREQUESTED DELIVERY (the take was intentionally generated to sound like this): \"\(resolvedDelivery)\""
        }
        if let voiceDescription, !voiceDescription.isEmpty {
            sections += "\nREQUESTED VOICE (the voice was designed from this description): \"\(voiceDescription)\""
        }
        var questions = """
        Judge by listening, then END YOUR REPLY WITH THESE LABELED LINES (one per line, exactly these labels):
        ACOUSTIC: <CLEAN|AUDIBLE_DEFECT|CANNOT_LISTEN>  — is there an unnatural glitch/click/pop/dropout or unnatural silence gap mid-utterance? An intentional whisper or slow emotional pacing that matches the requested delivery is NOT a defect.
        TEXT_MATCH: <YES|NO|UNCLEAR>  — do the spoken words match EXPECTED TEXT (ignoring minor articulation)?
        """
        if resolvedDelivery != nil {
            questions += "\nDELIVERY_MATCH: <YES|NO|UNCLEAR>  — does the emotion/tone/pace/energy clearly reflect REQUESTED DELIVERY (vs sounding flat/neutral or like a different emotion)?"
        }
        if let voiceDescription, !voiceDescription.isEmpty {
            questions += "\nVOICE_MATCH: <YES|NO|UNCLEAR>  — does the voice's character (age, gender, timbre, pitch, accent) match REQUESTED VOICE?"
        }
        let rubric = sections + "\n\n" + questions
            + "\nFirst give ONE short sentence of what you actually hear, then the labeled lines."

        // agy intermittently returns a transcript-only / "cannot hear" reply instead of
        // actually analyzing the audio. Retry once when it fails to yield a usable
        // acoustic verdict, so a flaky judge doesn't pollute the adherence rates.
        var out = ""
        var heard = "UNPARSED"
        for attempt in 1...2 {
            out = run(agy, ["-p", rubric, "--add-dir", tmpDir, "--print-timeout", "5m"], timeoutSeconds: 360).out
            heard = parseLabeled(out, "ACOUSTIC", allow: ["AUDIBLE_DEFECT", "CLEAN", "CANNOT_LISTEN"])
            if heard == "AUDIBLE_DEFECT" || heard == "CLEAN" { break }
            if attempt == 1 { note("  agy returned no clear listening verdict — retrying once…") }
        }
        let verdict: String
        switch heard {
        case "AUDIBLE_DEFECT": verdict = "real_defect"
        case "CLEAN": verdict = "false_positive"
        default: verdict = "uncertain"
        }
        let textMatch = matchToken(parseLabeled(out, "TEXT_MATCH", allow: ["YES", "NO", "UNCLEAR"]))
        let deliveryMatch = resolvedDelivery == nil
            ? "na" : matchToken(parseLabeled(out, "DELIVERY_MATCH", allow: ["YES", "NO", "UNCLEAR"]))
        let voiceMatch = (voiceDescription?.isEmpty ?? true)
            ? "na" : matchToken(parseLabeled(out, "VOICE_MATCH", allow: ["YES", "NO", "UNCLEAR"]))
        return v(verdict, heard, lastMeaningfulLine(out),
                 textMatch: textMatch, deliveryMatch: deliveryMatch, voiceMatch: voiceMatch)
    }

    // MARK: - process + parsing

    private static func resolveAgy() -> String? {
        let home = NSHomeDirectory()
        for c in ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
        where FileManager.default.isExecutableFile(atPath: c) { return c }
        let (out, code) = run("/usr/bin/env", ["which", "agy"])
        let p = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return (code == 0 && !p.isEmpty) ? p : nil
    }

    /// Run a process, capturing combined stdout/stderr via a temp file (no pipe
    /// deadlock on large agent output). Blocks until exit — `waitUntilExit()` runs
    /// synchronously on the @MainActor (review can be a multi-minute agy call).
    /// Benign here: `vocello` is a single-caller CLI with nothing else on the main
    /// actor, and the review pass is intentionally sequential.
    @discardableResult
    private static func run(_ exe: String, _ args: [String], timeoutSeconds: Int? = nil) -> (out: String, code: Int32) {
        let logURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vocello_proc_\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let fh = try? FileHandle(forWritingTo: logURL)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let fh { p.standardOutput = fh; p.standardError = fh }
        do { try p.run() } catch {
            try? fh?.close(); try? FileManager.default.removeItem(at: logURL)
            return ("launch failed: \(error.localizedDescription)", -1)
        }
        // HARD wall-clock timeout. agy's `--print-timeout` only bounds when it
        // prints, not the process — a stuck agy otherwise hangs the whole review
        // run forever on `waitUntilExit()` (observed: 55 min on one clip). Kill it
        // (SIGTERM, then SIGKILL) so a hang degrades to an "uncertain" verdict.
        if let timeoutSeconds {
            let killer = DispatchWorkItem {
                guard p.isRunning else { return }
                p.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: killer)
            p.waitUntilExit()
            killer.cancel()
        } else {
            p.waitUntilExit()
        }
        try? fh?.close()
        let out = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: logURL)
        return (out, p.terminationStatus)
    }

    /// Resolve a bench delivery-cell id (`<preset>.<intensity>`) back to the
    /// preset's instruction string for the listening rubric. Returns nil for
    /// ids that no longer match a shipped preset (the id itself is then shown).
    static func deliveryInstruction(for id: String) -> String? {
        let parts = id.split(separator: ".").map(String.init)
        guard let preset = EmotionPreset.preset(id: parts.first) else { return nil }
        let intensity = parts.count > 1
            ? EmotionIntensity.allCases.first(where: { $0.rpcValue == parts[1] })
            : EmotionIntensity.normal
        return preset.instruction(for: intensity ?? .normal)
    }

    /// Parse the token from the LAST line beginning with `<label>:` (the rubric
    /// asks agy to end with exactly these labeled lines). Anchoring to the labeled
    /// line avoids prose elsewhere that merely mentions a token misclassifying.
    private static func parseLabeled(_ out: String, _ label: String, allow: [String]) -> String {
        let prefix = "\(label):"
        guard let line = out.split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces).uppercased() })
            .last(where: { $0.hasPrefix(prefix) })
        else { return "UNPARSED" }
        let token = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "*", with: "")  // strip stray markdown bold
            .trimmingCharacters(in: .whitespaces)
        // The token may be followed by an em-dash explanation; take the first word.
        let firstWord = token.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "—" }).first.map(String.init) ?? token
        return allow.contains(firstWord) ? firstWord : "UNPARSED"
    }

    /// Normalize a YES/NO/UNCLEAR token to a lower-case match value.
    private static func matchToken(_ token: String) -> String {
        switch token {
        case "YES": return "yes"
        case "NO": return "no"
        case "UNCLEAR": return "unclear"
        default: return "unclear"
        }
    }

    private static func lastMeaningfulLine(_ out: String) -> String {
        let labels = ["ACOUSTIC:", "TEXT_MATCH:", "DELIVERY_MATCH:", "VOICE_MATCH:", "HEARD:"]
        let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty && !labels.contains(where: { line.uppercased().hasPrefix($0) })
            }
        return String((lines.last ?? "").prefix(240))
    }
}

/// `vocello review` — adjudicate review clips by ear via agy: acoustic defects
/// AND adherence (text / delivery / voice-description match).
enum ReviewCommand {
    @MainActor
    static func run(_ argv: [String]) async throws {
        let args = Args(argv)
        if args.flag("help") { printHelp(); return }
        guard AgyReviewer.isAvailable else {
            throw CLIError("agy and/or afconvert not available — `agy` must be on PATH and /usr/bin/afconvert present")
        }

        if let clip = args.string("clip") {
            let path = (clip as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { throw CLIError("clip not found: \(path)") }
            let text = args.string("text") ?? ""
            let flags = (args.string("flags") ?? "").split(separator: ",").map(String.init)
            note("reviewing \(path) via agy…")
            let r = AgyReviewer.review(clip: path, text: text, len: "?", state: "?", flags: flags,
                                       delivery: args.string("delivery"),
                                       voiceDescription: args.string("voice-description"),
                                       deliveryInstruction: args.string("delivery-instruction"))
            printVerdict(r)
            return
        }

        // --diag <dir>: review every flagged + adherence clip from a bench run.
        let diag = (args.string("diag").map { ($0 as NSString).expandingTildeInPath })
            ?? CLIPaths.dataDirectory(override: nil).appendingPathComponent("diagnostics").path
        reviewFlagged(diagnosticsDir: diag)
    }

    /// Discover the review clips under a bench run's diagnostics dir (acoustically
    /// flagged AND adherence cells), have agy listen to each (sequential — agy is
    /// heavy), print verdicts, and write the review log. Shared by `review --diag`
    /// and `bench --review`.
    @MainActor
    @discardableResult
    static func reviewFlagged(diagnosticsDir: String) -> [AgyVerdict] {
        let clips = FlaggedClips.discover(diagnosticsDir: diagnosticsDir)
        guard !clips.isEmpty else {
            note("no review clips found under \(diagnosticsDir)")
            return []
        }
        note("reviewing \(clips.count) clip(s) via agy (sequential; agy is heavy)…")
        var verdicts: [AgyVerdict] = []
        for f in clips {
            let r = AgyReviewer.review(clip: f.clip, text: f.text, len: f.len, state: f.state,
                                       flags: f.flags, delivery: f.delivery,
                                       voiceDescription: f.voiceDescription,
                                       deliveryInstruction: f.deliveryInstruction)
            printVerdict(r)
            verdicts.append(r)
        }
        FlaggedClips.writeReviewLog(verdicts, diagnosticsDir: diagnosticsDir)
        return verdicts
    }

    static func printVerdict(_ r: AgyVerdict) {
        let mark = r.verdict == "real_defect" ? "✗ REAL DEFECT" : r.verdict == "false_positive" ? "✓ acoustically clean" : "? uncertain"
        let cell = r.delivery.map { "\(r.len)/\(r.state)/\($0)" } ?? "\(r.len)/\(r.state)"
        var adh: [String] = []
        if r.textMatch != "na" { adh.append("text:\(r.textMatch)") }
        if r.deliveryMatch != "na" { adh.append("delivery:\(r.deliveryMatch)") }
        if r.voiceMatch != "na" { adh.append("voice:\(r.voiceMatch)") }
        let adhStr = adh.isEmpty ? "" : "  {\(adh.joined(separator: " "))}"
        let flagStr = r.flags.isEmpty ? "" : " " + r.flags.joined(separator: ",")
        print("\(mark)  [\(cell)]\(flagStr)\(adhStr) — \(r.reason)")
    }

    static func printHelp() {
        print("""
        vocello review — adjudicate clips by ear (agy multimodal listening): acoustic
        defects AND adherence (text / delivery / voice-description match).

        Usage:
          vocello review --clip <wav> [--text "…"] [--flags dropout:469ms]
                         [--delivery happy.strong] [--delivery-instruction "…"] [--voice-description "…"]
          vocello review --diag <diagnostics-dir>     # review all flagged + adherence clips from a bench run

        --delivery / --delivery-instruction tell agy what delivery the take was asked
        for (so an intentional whisper isn't judged a defect, AND agy can score whether
        the delivery was actually followed). --voice-description lets agy score whether
        a Voice Design voice matches its brief. In --diag mode these are read from the
        engine telemetry notes automatically.

        Transcodes each clip to m4a (afconvert) and hands it to `agy` to LISTEN. Judges
        ACOUSTIC (defect vs natural), TEXT_MATCH, DELIVERY_MATCH, VOICE_MATCH. Dev
        workflow only. Writes verdicts to <diag>/review/review.jsonl in --diag mode.
        """)
    }
}

/// A review clip discovered from a bench run's diagnostics + outputs.
/// `delivery` is the bench delivery-cell id (`<preset>.<intensity>`) when the
/// take carried a delivery instruction; `voiceDescription`/`deliveryInstruction`
/// are the engine-logged ground truth for adherence judging.
struct FlaggedClip {
    let clip: String
    let text: String
    let len: String
    let state: String
    let flags: [String]
    let delivery: String?
    let voiceDescription: String?
    let deliveryInstruction: String?
}

/// Correlates engine telemetry rows to the bench output WAVs by the
/// `<mode>_<modelID>_<len>_<state>[_d-<delivery>]_<n>.wav` naming convention,
/// one representative clip per cell. Reviews a cell when it is EITHER acoustically
/// flagged (audioQC warn/fail) OR an adherence target (carries a delivery
/// instruction, or is a Voice Design take with a description) — adherence
/// failures produce acoustically-clean audio the QC detector never flags, so
/// gating only on audioQC made them invisible.
enum FlaggedClips {
    static func lenBucket(_ chars: Int) -> String {
        chars == 0 ? "n/a" : chars < 70 ? "short" : chars > 220 ? "long" : "medium"
    }

    static func discover(diagnosticsDir: String) -> [FlaggedClip] {
        let enginePath = (diagnosticsDir as NSString).appendingPathComponent("engine/generations.jsonl")
        guard let content = try? String(contentsOfFile: enginePath, encoding: .utf8) else { return [] }
        let benchOut = ((diagnosticsDir as NSString).deletingLastPathComponent as NSString).appendingPathComponent("outputs/bench")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: benchOut)) ?? []
        var seen = Set<String>()
        var result: [FlaggedClip] = []
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            let mode = row["mode"] as? String ?? "?"
            let notes = row["notes"] as? [String: Any]
            let qc = row["audioQC"] as? [String: Any]
            let verdict = qc?["verdict"] as? String
            let acousticFlag = verdict == "warn" || verdict == "fail"
            let delivery = (notes?["delivery"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let voiceDescription = (notes?["voiceDescription"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let deliveryInstruction = (notes?["deliveryInstruction"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // Review this cell if it is acoustically flagged OR an adherence target
            // (delivery instruction present, or a design take with a description).
            let isAdherenceTarget = delivery != nil || deliveryInstruction != nil
                || (mode == "design" && voiceDescription != nil)
            guard acousticFlag || isAdherenceTarget else { continue }

            let modelID = (row["modelID"] as? String ?? "?").split(separator: "/").last.map(String.init) ?? "?"
            let state = row["warmState"] as? String ?? "?"
            let chars = Int(notes?["promptChars"] as? String ?? "0") ?? 0
            let len = lenBucket(chars)
            let key = "\(mode)|\(modelID)|\(len)|\(state)|\(delivery ?? "")|\((voiceDescription ?? "").prefix(40))"
            if seen.contains(key) { continue }
            seen.insert(key)
            // Delivery takes carry a `_d-<delivery>` token after the state; a
            // plain row must NOT pick up a delivery file (the audio differs by
            // design — e.g. a whisper take would wrongly "clear" a plain flag),
            // so the plain pattern requires the rep index right after the state.
            let prefix: String
            let matches: (String) -> Bool
            if let delivery {
                prefix = "\(mode)_\(modelID)_\(len)_\(state)_d-\(delivery)_"
                matches = { $0.hasPrefix(prefix) && $0.hasSuffix(".wav") }
            } else {
                prefix = "\(mode)_\(modelID)_\(len)_\(state)_"
                matches = { f in
                    guard f.hasPrefix(prefix), f.hasSuffix(".wav") else { return false }
                    return f.dropFirst(prefix.count).first?.isNumber == true
                }
            }
            guard let f = files.filter(matches).sorted().first else { continue }
            result.append(FlaggedClip(
                clip: (benchOut as NSString).appendingPathComponent(f),
                text: BenchCommand.corpus.first { $0.len == len }?.text ?? "",
                len: len, state: state, flags: (qc?["flags"] as? [String]) ?? [],
                delivery: delivery,
                voiceDescription: voiceDescription,
                deliveryInstruction: deliveryInstruction))
        }
        return result
    }

    static func writeReviewLog(_ verdicts: [AgyVerdict], diagnosticsDir: String) {
        let dir = (diagnosticsDir as NSString).appendingPathComponent("review")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent("review.jsonl"))
        var lines = ""
        for v in verdicts {
            var obj: [String: Any] = [
                "clip": (v.clip as NSString).lastPathComponent, "len": v.len, "state": v.state,
                "flags": v.flags, "verdict": v.verdict, "heard": v.heard,
                "textMatch": v.textMatch, "deliveryMatch": v.deliveryMatch, "voiceMatch": v.voiceMatch,
                "reason": v.reason,
            ]
            if let delivery = v.delivery { obj["delivery"] = delivery }
            if let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) {
                lines += s + "\n"
            }
        }
        try? lines.write(to: url, atomically: true, encoding: .utf8)
        note("wrote \(url.path)")
    }
}
