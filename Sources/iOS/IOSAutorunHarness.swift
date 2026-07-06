import Foundation
import QwenVoiceCore
import UIKit

/// Headless on-device generation harness — the iOS analog of `vocello bench`.
///
/// Fires **only** when `QVOICE_IOS_AUTORUN` is present and non-empty in the launch
/// environment, so it ships completely inert (a normal user launch never sets it).
/// `scripts/ios_device.sh bench` sets it — together with `QWENVOICE_DEBUG=1` (lights
/// up `TelemetryGate`, so the engine appends its decode/RTF/audioQC row to
/// `diagnostics/engine/generations.jsonl`) and `QVOICE_IOS_DEVICE_RUN_ID=<runID>`
/// (tags the run) — launches the app over `devicectl`, polls for the completion
/// sentinel, then pulls the App-Group `diagnostics/` tree and runs the summarizer.
///
/// Spec format (the env value): `<mode>:<variant>:<text>`, e.g.
/// `custom:speed:Hello from Vocello on device`. `mode ∈ custom|design|clone`,
/// `variant ∈ speed|quality` (iPhone resolves speed-only regardless), and the text is
/// everything after the second `:` (so it may itself contain colons). Forgiving:
/// a bare `1`/`on`/`true`/`yes`, a bare mode, or a partial spec all fall back to
/// sensible defaults.
///
/// Optional companion env `QVOICE_IOS_AUTORUN_LANG` sets the UI language picker
/// equivalent (`english`, `french`, `auto`, …) on the generation request. Omitted
/// behaves like Auto. `scripts/ios_device.sh lang-bench` sets it per matrix cell.
///
/// The harness drives the same in-process `TTSEngineStore.generate(_:)` the UI uses —
/// no UI interaction — then writes `diagnostics/<runID>/autorun-done.json`. It never
/// calls `exit()`; the app stays up so the script can pull the diagnostics container.
@MainActor
enum IOSAutorunHarness {
    private static let environmentKey = "QVOICE_IOS_AUTORUN"
    private static let runIDKey = "QVOICE_IOS_DEVICE_RUN_ID"
    private static let languageEnvKey = "QVOICE_IOS_AUTORUN_LANG"

    /// Default benchmark sentence — long enough to exercise streaming chunking,
    /// free of any personal/sensitive content.
    private static let defaultText =
        "Vocello on-device autorun check. The quick brown fox jumps over the lazy dog, "
        + "then pauses, takes a breath, and reads one more sentence aloud."
    /// Default Voice Design brief when a `design` run supplies only text.
    private static let defaultVoiceBrief =
        "A warm, friendly narrator with a calm, measured pace."

    struct Spec {
        var mode: GenerationMode
        var variant: ModelVariantKind
        var text: String
    }

    /// True when the launch environment requested an autorun.
    static var isRequested: Bool {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !raw.isEmpty
    }

    /// Kick off the autorun if requested. Safe to call once after engine init;
    /// no-op when `QVOICE_IOS_AUTORUN` is unset. Runs detached on the MainActor so it
    /// doesn't block app startup.
    static func runIfRequested(engine: TTSEngineStore) {
        guard isRequested else { return }
        // Crash-capture lane verification: deliberately fault so MetricKit captures the
        // crash and the `scripts/ios_device.sh crashes --test` flow can symbolicate it
        // against the preserved build dSYM. Ships inert (only set by the test verb).
        if ProcessInfo.processInfo.environment["QVOICE_IOS_CRASH_TEST"] == "1" {
            print("[autorun] QVOICE_IOS_CRASH_TEST=1 → deliberate crash for the capture/symbolication lane")
            fatalError("QVOICE_IOS_CRASH_TEST: deliberate crash for the on-device crash-capture lane")
        }
        let spec = parseSpec(ProcessInfo.processInfo.environment[environmentKey] ?? "")
        let uiLanguageHint = trimmedEnvironmentValue(languageEnvKey)
        // Record calls + lifecycle transitions for the sentinel so a doomed run
        // self-reports its cause ("call arrived at t=42s"). Autorun-only → inert
        // on user launches.
        IOSInterruptionRecorder.shared.start()
        Task { @MainActor in
            await run(spec: spec, uiLanguageHint: uiLanguageHint, engine: engine)
        }
    }

    // MARK: - Spec parsing

    static func parseSpec(_ raw: String) -> Spec {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var spec = Spec(mode: .custom, variant: .speed, text: defaultText)
        guard !["", "1", "on", "true", "yes"].contains(trimmed.lowercased()) else {
            return spec
        }
        let parts = trimmed
            .split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            .map(String.init)
        if let first = parts.first, let mode = GenerationMode(rawValue: first.lowercased()) {
            spec.mode = mode
        }
        if parts.count >= 2 {
            switch parts[1].lowercased() {
            case "quality", "hq": spec.variant = .quality
            case "speed", "fast", "": spec.variant = .speed
            default: break
            }
        }
        if parts.count >= 3, !parts[2].isEmpty {
            spec.text = parts[2]
        }
        return spec
    }

    // MARK: - Run

    private static func run(spec: Spec, uiLanguageHint: String?, engine: TTSEngineStore) async {
        let runID = safeRunID(from: ProcessInfo.processInfo.environment[runIDKey]) ?? "autorun"
        let generationID = UUID()
        let startedAt = Date()
        print(
            "[autorun] start mode=\(spec.mode.rawValue) variant=\(spec.variant.rawValue) "
            + "runID=\(runID) lang=\(uiLanguageHint ?? "auto") chars=\(spec.text.count)"
        )

        // Device/bundle fields read here (MainActor) — UIDevice is MainActor-isolated,
        // so they cannot be struct property defaults under Swift 6 strict concurrency.
        let device = UIDevice.current
        var record = SentinelRecord(
            runID: runID,
            generationID: generationID.uuidString,
            mode: spec.mode.rawValue,
            variant: spec.variant.rawValue,
            text: spec.text,
            startedAt: ISO8601DateFormatter().string(from: startedAt),
            uiLanguageHint: uiLanguageHint,
            deviceModel: device.model,
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            bundleVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildVersion: Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String
        )

        do {
            guard let model = ModelDescriptor.model(for: spec.mode) else {
                throw HarnessError("no model in the contract for mode '\(spec.mode.rawValue)'")
            }
            record.modelID = model.id
            record.modelName = model.name

            let payload = try await buildPayload(spec: spec, model: model, engine: engine)

            print("[autorun] loading \(model.id)…")
            try await engine.loadModel(id: model.id)

            // Clone requires the reference primed (the optimized `voiceClonePrompt`) BEFORE
            // generate — mirrors `VoiceCloningCoordinator`. With proactive warm now gated on
            // the memory band (not blanket-disabled on hardware), this actually runs on device.
            if case .clone(let reference) = payload {
                print("[autorun] priming clone reference…")
                do {
                    try await engine.ensureCloneReferencePrimed(modelID: model.id, reference: reference)
                } catch {
                    print("[autorun] clone prime degraded: \(error.localizedDescription)")
                }
            }

            let outputPath = makeOutputPath(runID: runID, model: model)
            let request = GenerationRequest(
                mode: spec.mode,
                modelID: model.id,
                text: spec.text,
                outputPath: outputPath,
                shouldStream: true,
                streamingInterval: GenerationSemantics.appStreamingInterval,
                languageHint: uiLanguageHint,
                payload: payload,
                generationID: generationID
            )
            record.resolvedLanguageHint = GenerationSemantics.qwenLanguageHint(for: request)

            print("[autorun] generating… resolvedLanguage=\(record.resolvedLanguageHint ?? "?")")
            let t0 = Date()
            let result = try await engine.generate(request)
            let wall = Date().timeIntervalSince(t0)
            let rtf = wall > 0 ? result.durationSeconds / wall : 0

            record.status = "ok"
            record.audioPath = result.audioPath
            record.durationSeconds = result.durationSeconds
            record.wallSeconds = wall
            record.realtimeFactor = rtf
            record.finishReason = result.finishReason?.rawValue
            print(String(
                format: "[autorun] ✓ %.2fs audio · rtf=%.2f · finish=%@",
                result.durationSeconds, rtf, result.finishReason?.rawValue ?? "?"
            ))
        } catch is CancellationError {
            record.status = "error"
            record.error = "cancelled"
            print("[autorun] ✗ cancelled")
        } catch {
            record.status = "error"
            record.error = error.localizedDescription
            print("[autorun] ✗ \(error.localizedDescription)")
        }

        record.finishedAt = ISO8601DateFormatter().string(from: Date())
        let interruptions = IOSInterruptionRecorder.shared.snapshot()
        if !interruptions.isEmpty {
            record.interruptions = interruptions
        }
        writeSentinel(record, runID: runID)
    }

    @MainActor
    private static func buildPayload(
        spec: Spec,
        model: ModelDescriptor,
        engine: TTSEngineStore
    ) async throws -> GenerationRequest.Payload {
        switch spec.mode {
        case .custom:
            return .custom(
                speakerID: ModelDescriptor.defaultSpeaker,
                deliveryStyle: nil
            )
        case .design:
            return .design(
                voiceDescription: defaultVoiceBrief,
                deliveryStyle: nil
            )
        case .clone:
            let voices = try await engine.listPreparedVoices()
            if let voice = voices.first {
                return .clone(
                    reference: CloneReference(
                        audioPath: voice.audioPath,
                        transcript: nil,
                        preparedVoiceID: voice.id
                    )
                )
            }
            // Headless-bench fallback: no enrolled voice → use a bundled English
            // voice-preview clip as the clone reference. Clone needs a TRANSCRIPT to build
            // the optimized voiceClonePrompt (NativeCloneSupport: createVoiceClonePrompt),
            // so this only uses aiden/ryan — generated from the exact known phrase below
            // (voice-previews/README.md). Exercises the clone encoder + generation path +
            // memory fit (the point of a clone bench); NOT a quality reference (real cloning
            // uses a user-enrolled recording). Lets `ios_device.sh bench clone:…` run with
            // nothing enrolled.
            if let previewURL = bundledPreviewReferenceURL() {
                print("[autorun] clone: no saved voice — using bundled preview reference \(previewURL.lastPathComponent)")
                return .clone(
                    reference: CloneReference(
                        audioPath: previewURL.path,
                        transcript: bundledPreviewReferenceTranscript,
                        preparedVoiceID: nil
                    )
                )
            }
            throw HarnessError("clone autorun needs a saved voice or a bundled English preview reference (none found)")
        }
    }

    /// The exact phrase the English voice-previews were generated from
    /// (`voice-previews/README.md`) — the matching transcript clone needs to build the
    /// optimized voiceClonePrompt.
    private static let bundledPreviewReferenceTranscript = "Hello, this is a sample of my voice."

    /// A bundled ENGLISH preview WAV usable as a fallback clone reference for benching
    /// (`Sources/Resources/voice-previews/<id>.wav`). Restricted to aiden/ryan because only
    /// those have a documented transcript (the non-English previews use unknown text, and a
    /// mismatched transcript degrades/blocks clone conditioning). Returns the first present.
    private static func bundledPreviewReferenceURL() -> URL? {
        for id in ["aiden", "ryan"] {
            if let url = Bundle.main.url(forResource: id, withExtension: "wav", subdirectory: "voice-previews")
                ?? Bundle.main.url(forResource: id, withExtension: "wav") {
                return url
            }
        }
        return nil
    }

    private static func trimmedEnvironmentValue(_ key: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    // MARK: - Paths & sentinel

    private static func makeOutputPath(runID: String, model: ModelDescriptor) -> String {
        let dir = AppPaths.outputsDir
            .appendingPathComponent(model.outputSubfolder, isDirectory: true)
            .appendingPathComponent("autorun", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(runID).wav", isDirectory: false).path
    }

    private static func writeSentinel(_ record: SentinelRecord, runID: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(record)) ?? Data()

        // 1) Canonical: the App-Group diagnostics dir, where the engine also writes its
        //    telemetry (`diagnostics/engine/generations.jsonl`).
        let groupRunDir = AppPaths.appSupportDir
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        writeData(data, to: groupRunDir.appendingPathComponent("autorun-done.json", isDirectory: false),
                  label: "sentinel (app-group)")

        // 2) Pullable mirror in the app's OWN container. devicectl `copy from
        //    --domain-type appDataContainer` CAN pull this, but it CANNOT pull the
        //    App-Group container (confirmed: any source there fails with a bogus
        //    "File paths cannot contain '..'"). scripts/ios_device.sh pulls
        //    `Library/Caches/Vocello/diagnostics` from appDataContainer, so the bench
        //    needs the sentinel + the engine telemetry here too.
        guard let pullableRoot = IOSPullableDiagnosticsMirror.pullableRoot else { return }
        writeData(data, to: pullableRoot.appendingPathComponent(runID, isDirectory: true)
                    .appendingPathComponent("autorun-done.json", isDirectory: false),
                  label: "sentinel (pullable)")
        IOSPullableDiagnosticsMirror.syncEngineTelemetry(
            from: AppPaths.appSupportDir.appendingPathComponent("diagnostics", isDirectory: true),
            into: pullableRoot
        )
    }

    private static func writeData(_ data: Data, to url: URL, label: String) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            print("[autorun] \(label) → \(url.path)")
        } catch {
            print("[autorun] could not write \(label): \(error.localizedDescription)")
        }
    }

    /// Mirror `IOSDeviceDiagnosticsRecorder` / `MLXTTSEngine` run-ID sanitization so
    /// the sentinel lands in the same `diagnostics/<runID>/` directory.
    private static func safeRunID(from rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let safe = trimmed.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "_"
        }
        return String(safe)
    }

    private struct HarnessError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private struct SentinelRecord: Codable {
        // `var` (not `let`) for the defaulted fields: a `let` with an initial value is
        // skipped by Codable decode (warning) and, for the device fields, a default
        // expression touching MainActor `UIDevice` would be evaluated in the nonisolated
        // synthesized init (Swift 6 error). So defaults stay literal/`var`, and device/
        // bundle fields are passed in from the @MainActor call site.
        var schemaVersion = 1
        let runID: String
        let generationID: String
        let mode: String
        let variant: String
        let text: String
        let startedAt: String
        var finishedAt: String?
        var status = "error"
        var uiLanguageHint: String?
        var resolvedLanguageHint: String?
        var modelID: String?
        var modelName: String?
        var audioPath: String?
        var durationSeconds: Double?
        var wallSeconds: Double?
        var realtimeFactor: Double?
        var finishReason: String?
        var error: String?
        /// Calls + lifecycle transitions observed during the run (see
        /// `IOSInterruptionRecorder`) — explains doomed runs. Omitted when clean.
        var interruptions: [IOSInterruptionRecorder.Event]?
        let deviceModel: String
        let systemName: String
        let systemVersion: String
        let bundleVersion: String?
        let buildVersion: String?
    }
}
