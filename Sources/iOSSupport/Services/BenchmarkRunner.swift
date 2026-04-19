import Foundation
import os
import QwenVoiceCore

/// Lightweight in-app benchmark runner activated by the `QVOICE_BENCHMARK` environment variable.
/// Calls the engine API directly — no UI automation, no XCUITest, no app relaunches.
@MainActor
final class BenchmarkRunner {
    static let environmentKey = "QVOICE_BENCHMARK"
    private static let runIDEnvironmentKey = "QVOICE_BENCHMARK_RUN_ID"
    private static let scenarioFileName = "scenarios.json"
    private static let resultFileName = "benchmark_results.json"

    struct ScenarioDefinition: Codable {
        let id: String
        let mode: String
        let modelID: String
        let text: String
        let speaker: String?
        let voiceDescription: String?
        let deliveryStyle: String?
        let requiresColdStart: Bool?
    }

    struct ScenarioResult: Codable {
        let scenarioID: String
        let mode: String
        let succeeded: Bool
        let error: String?
        let wallClockMs: Int
        let firstChunkMs: Int?
        let processingTimeSeconds: Double?
        let peakResidentMB: Double?
        let peakPhysFootprintMB: Double?
        let compressedPeakMB: Double?
        let residentStartMB: Double?
        let residentEndMB: Double?
        let headroomStartMB: Double?
        let headroomEndMB: Double?
        let headroomMinMB: Double?
        let gpuAllocatedPeakMB: Double?
        let gpuRecommendedWorkingSetMB: Double?
        let telemetrySampleCount: Int?
        let telemetrySamples: [TelemetrySample]?
        let telemetryStageMarks: [NativeTelemetryStageMark]?
        let audioDurationSeconds: Double?
        let warmState: String?
        let timingsMS: [String: Int]
        let booleanFlags: [String: Bool]
    }

    struct Report: Codable {
        let schemaVersion: String
        let deviceModel: String
        let osVersion: String
        let timestamp: String
        let appSupportDirectory: String
        let scenarioSource: String
        let scenarios: [ScenarioResult]
    }

    /// Benchmark triggers if ANY of these are true:
    /// 1. `--benchmark` launch argument
    /// 2. `QVOICE_BENCHMARK` environment variable
    /// 3. Trigger file exists at `<AppSupport>/benchmarks/trigger`
    static var isEnabled: Bool {
        CommandLine.arguments.contains("--benchmark")
            || ProcessInfo.processInfo.environment[environmentKey] != nil
            || FileManager.default.fileExists(atPath: triggerFilePath.path)
    }

    /// Remove the trigger file so the benchmark doesn't re-run on next normal launch.
    static func consumeTrigger() {
        try? FileManager.default.removeItem(at: triggerFilePath)
    }

    private static var triggerFilePath: URL {
        benchmarkDirectory
            .appendingPathComponent("trigger")
    }

    private static let logger = Logger(subsystem: "com.qvoice.ios", category: "Benchmark")

    private let engine: TTSEngineStore

    init(engine: TTSEngineStore) {
        self.engine = engine
    }

    func run() async {
        Self.consumeTrigger()
        Self.logger.notice("[Benchmark] Starting benchmark suite")

        let (scenarios, scenarioSource) = Self.loadScenarios()
        var results: [ScenarioResult] = []

        for scenario in scenarios {
            Self.logger.notice("[Benchmark] Running: \(scenario.id)")
            let result = await runScenario(scenario)
            results.append(result)

            if result.succeeded {
                Self.logger.notice("[Benchmark] \(scenario.id): OK  firstChunk=\(result.firstChunkMs ?? -1)ms  peak=\(String(format: "%.0f", result.peakPhysFootprintMB ?? 0))MB  wall=\(result.wallClockMs)ms")
            } else {
                Self.logger.error("[Benchmark] \(scenario.id): FAILED  \(result.error ?? "unknown")")
            }
        }

        let report = Report(
            schemaVersion: "1.0",
            deviceModel: machineIdentifier(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            appSupportDirectory: AppPaths.appSupportDir.path,
            scenarioSource: scenarioSource,
            scenarios: results
        )

        writeReport(report)
        printSummary(results)
        Self.logger.notice("[Benchmark] BENCHMARK_COMPLETE")
    }

    // MARK: - Scenario Definitions

    private struct Scenario {
        let id: String
        let mode: GenerationMode
        let modelID: String
        let text: String
        let speaker: String?
        let voiceDescription: String?
        let deliveryStyle: String?
        let requiresColdStart: Bool
    }

    private static var benchmarkDirectory: URL {
        let root = AppPaths.appSupportDir.appendingPathComponent("benchmarks", isDirectory: true)
        guard let runID = benchmarkRunID else {
            return root
        }
        return root.appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
    }

    private static var scenarioFileURL: URL {
        benchmarkDirectory.appendingPathComponent(scenarioFileName)
    }

    private static var resultFileURL: URL {
        benchmarkDirectory.appendingPathComponent(resultFileName)
    }

    private static var benchmarkRunID: String? {
        let raw = ProcessInfo.processInfo.environment[runIDEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private static let longText = """
    Artificial intelligence has transformed how we interact with technology. \
    Large language models can now understand context, generate creative content, \
    and assist with complex reasoning tasks that were previously thought to require \
    human intelligence. The rapid pace of advancement continues to surprise researchers \
    and practitioners alike, opening new possibilities across every industry.
    """

    private static let scenarios: [Scenario] = [
        // Cold/warm pairs for Custom Voice
        Scenario(
            id: "custom_short_cold",
            mode: .custom,
            modelID: "pro_custom",
            text: "Hello world.",
            speaker: "vivian",
            voiceDescription: nil,
            deliveryStyle: "Normal tone",
            requiresColdStart: true
        ),
        Scenario(
            id: "custom_short_warm",
            mode: .custom,
            modelID: "pro_custom",
            text: "Hello world.",
            speaker: "vivian",
            voiceDescription: nil,
            deliveryStyle: "Normal tone",
            requiresColdStart: false
        ),
        Scenario(
            id: "custom_long_cold",
            mode: .custom,
            modelID: "pro_custom",
            text: longText,
            speaker: "vivian",
            voiceDescription: nil,
            deliveryStyle: "Warm, bright, and enthusiastic.",
            requiresColdStart: true
        ),
        Scenario(
            id: "custom_long_warm",
            mode: .custom,
            modelID: "pro_custom",
            text: longText,
            speaker: "vivian",
            voiceDescription: nil,
            deliveryStyle: "Warm, bright, and enthusiastic.",
            requiresColdStart: false
        ),
        // Cold/warm pairs for Voice Design
        Scenario(
            id: "design_short_cold",
            mode: .design,
            modelID: "pro_design",
            text: "Hello world.",
            speaker: nil,
            voiceDescription: "A clear, steady female narrator with a natural conversational tone.",
            deliveryStyle: "Normal tone",
            requiresColdStart: true
        ),
        Scenario(
            id: "design_short_warm",
            mode: .design,
            modelID: "pro_design",
            text: "Hello world.",
            speaker: nil,
            voiceDescription: "A clear, steady female narrator with a natural conversational tone.",
            deliveryStyle: "Normal tone",
            requiresColdStart: false
        ),
        Scenario(
            id: "design_long_cold",
            mode: .design,
            modelID: "pro_design",
            text: longText,
            speaker: nil,
            voiceDescription: "A clear, steady female narrator with a natural conversational tone.",
            deliveryStyle: "Warm and expressive with a bright conversational delivery.",
            requiresColdStart: true
        ),
        Scenario(
            id: "design_long_warm",
            mode: .design,
            modelID: "pro_design",
            text: longText,
            speaker: nil,
            voiceDescription: "A clear, steady female narrator with a natural conversational tone.",
            deliveryStyle: "Warm and expressive with a bright conversational delivery.",
            requiresColdStart: false
        ),
    ]

    private static func loadScenarios() -> ([Scenario], String) {
        let fileURL = scenarioFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return (scenarios, "defaults")
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let definitions = try JSONDecoder().decode([ScenarioDefinition].self, from: data)
            let loaded = try definitions.map { definition in
                guard let mode = GenerationMode(rawValue: definition.mode.lowercased()) else {
                    throw ScenarioLoadError.invalidMode(definition.mode, scenarioID: definition.id)
                }
                return Scenario(
                    id: definition.id,
                    mode: mode,
                    modelID: definition.modelID,
                    text: definition.text,
                    speaker: definition.speaker,
                    voiceDescription: definition.voiceDescription,
                    deliveryStyle: definition.deliveryStyle,
                    requiresColdStart: definition.requiresColdStart ?? false
                )
            }
            guard !loaded.isEmpty else {
                throw ScenarioLoadError.emptyFile
            }
            return (loaded, fileURL.path)
        } catch {
            Self.logger.error("[Benchmark] Failed to load scenarios from \(fileURL.path): \(error.localizedDescription)")
            return (scenarios, "defaults (scenario load failed)")
        }
    }

    private enum ScenarioLoadError: LocalizedError {
        case invalidMode(String, scenarioID: String)
        case emptyFile

        var errorDescription: String? {
            switch self {
            case .invalidMode(let mode, let scenarioID):
                return "Invalid generation mode '\(mode)' in scenario '\(scenarioID)'."
            case .emptyFile:
                return "Scenario file is empty."
            }
        }
    }

    // MARK: - Execution

    private func runScenario(_ scenario: Scenario) async -> ScenarioResult {
        let outputDir = AppPaths.outputsDir
            .appendingPathComponent(scenario.mode == .custom ? "CustomVoice" : "VoiceDesign", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let outputPath = outputDir
            .appendingPathComponent("benchmark_\(scenario.id).wav")
            .path

        let payload: GenerationRequest.Payload
        switch scenario.mode {
        case .custom:
            payload = .custom(speakerID: scenario.speaker ?? "vivian", deliveryStyle: scenario.deliveryStyle)
        case .design:
            payload = .design(voiceDescription: scenario.voiceDescription ?? "", deliveryStyle: scenario.deliveryStyle)
        case .clone:
            return makeFailedResult(scenario, error: "Clone benchmarks not supported")
        }

        let request = GenerationRequest(
            mode: scenario.mode,
            modelID: scenario.modelID,
            text: scenario.text,
            outputPath: outputPath,
            shouldStream: true,
            streamingInterval: 0.32,
            payload: payload
        )

        // Force cold start by unloading model before this scenario
        if scenario.requiresColdStart {
            Self.logger.notice("[Benchmark] Unloading model for cold start: \(scenario.id)")
            try? await engine.unloadModel()
        }

        let wallStart = ContinuousClock.now

        do {
            try await engine.loadModel(id: scenario.modelID)

            if scenario.mode == .design {
                await engine.prewarmModelIfNeeded(for: request)
            }

            let result = try await engine.generate(request)
            let wallMs = wallStart.elapsedMs

            let b = result.benchmarkSample
            return ScenarioResult(
                scenarioID: scenario.id,
                mode: scenario.mode.rawValue,
                succeeded: true,
                error: nil,
                wallClockMs: wallMs,
                firstChunkMs: b?.firstChunkMs,
                processingTimeSeconds: b?.processingTimeSeconds,
                peakResidentMB: b?.peakResidentMB,
                peakPhysFootprintMB: b?.peakPhysFootprintMB,
                compressedPeakMB: b?.compressedPeakMB,
                residentStartMB: b?.residentStartMB,
                residentEndMB: b?.residentEndMB,
                headroomStartMB: b?.headroomStartMB,
                headroomEndMB: b?.headroomEndMB,
                headroomMinMB: b?.headroomMinMB,
                gpuAllocatedPeakMB: b?.gpuAllocatedPeakMB,
                gpuRecommendedWorkingSetMB: b?.gpuRecommendedWorkingSetMB,
                telemetrySampleCount: b?.telemetrySamples?.count,
                telemetrySamples: b?.telemetrySamples,
                telemetryStageMarks: b?.telemetryStageMarks,
                audioDurationSeconds: result.durationSeconds,
                warmState: b?.warmState?.rawValue,
                timingsMS: b?.timingsMS ?? [:],
                booleanFlags: b?.booleanFlags ?? [:]
            )
        } catch {
            let wallMs = wallStart.elapsedMs
            return makeFailedResult(scenario, wallMs: wallMs, error: error.localizedDescription)
        }
    }

    private func makeFailedResult(_ scenario: Scenario, wallMs: Int = 0, error: String) -> ScenarioResult {
        let snapshot = IOSMemorySnapshot.capture()
        let telemetrySample = TelemetrySample(
            tMS: wallMs,
            residentMB: snapshot.residentMB,
            physFootprintMB: snapshot.physFootprintMB,
            compressedMB: snapshot.compressedMB,
            headroomMB: snapshot.availableHeadroomMB,
            gpuAllocatedMB: snapshot.gpuAllocatedMB,
            gpuRecommendedWorkingSetMB: snapshot.gpuRecommendedWorkingSetMB,
            threads: 0,
            stage: "benchmark_failed"
        )
        return ScenarioResult(
            scenarioID: scenario.id,
            mode: scenario.mode.rawValue,
            succeeded: false,
            error: error,
            wallClockMs: wallMs,
            firstChunkMs: nil,
            processingTimeSeconds: nil,
            peakResidentMB: snapshot.residentMB,
            peakPhysFootprintMB: snapshot.physFootprintMB,
            compressedPeakMB: snapshot.compressedMB,
            residentStartMB: snapshot.residentMB,
            residentEndMB: snapshot.residentMB,
            headroomStartMB: snapshot.availableHeadroomMB,
            headroomEndMB: snapshot.availableHeadroomMB,
            headroomMinMB: snapshot.availableHeadroomMB,
            gpuAllocatedPeakMB: snapshot.gpuAllocatedMB,
            gpuRecommendedWorkingSetMB: snapshot.gpuRecommendedWorkingSetMB,
            telemetrySampleCount: 1,
            telemetrySamples: [telemetrySample],
            telemetryStageMarks: [],
            audioDurationSeconds: nil,
            warmState: nil,
            timingsMS: [:],
            booleanFlags: [:]
        )
    }

    // MARK: - Output

    private func writeReport(_ report: Report) {
        let outputURL = Self.resultFileURL
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            try? data.write(to: outputURL, options: .atomic)
            Self.logger.notice("[Benchmark] Results written to \(outputURL.path)")
        }
    }

    private func printSummary(_ results: [ScenarioResult]) {
        Self.logger.notice("[Benchmark] ── Summary ──────────────────────────────────")
        for r in results {
            let status = r.succeeded ? "OK" : "FAIL"
            let firstChunk = r.firstChunkMs.map { "\($0)ms" } ?? "n/a"
            let peak = r.peakPhysFootprintMB.map { String(format: "%.0fMB", $0) } ?? "n/a"
            let headroom = r.headroomMinMB.map { String(format: "%.0fMB", $0) } ?? "n/a"
            let wall = "\(r.wallClockMs)ms"
            let warm = r.warmState ?? "n/a"
            Self.logger.notice("[Benchmark] \(r.scenarioID): \(status)  state=\(warm)  firstChunk=\(firstChunk)  peakMem=\(peak)  minHeadroom=\(headroom)  wall=\(wall)")

            // Log cold-start phase breakdown when timing data is available
            if !r.timingsMS.isEmpty {
                let phases: [(String, String)] = [
                    ("load_model", "load"),
                    ("cache_prepare", "cache"),
                    ("mlx_model_load", "mlxLoad"),
                    ("talker_parameter_eval", "paramEval"),
                    ("talker_decoder_layers_eval", "decoderEval"),
                    ("prewarm_model", "prewarm"),
                    ("first_audio_ready", "firstAudio"),
                    ("generation", "gen"),
                ]
                let parts = phases.compactMap { key, label -> String? in
                    guard let ms = r.timingsMS[key] else { return nil }
                    return "\(label)=\(ms)ms"
                }
                if !parts.isEmpty {
                    Self.logger.notice("[Benchmark]   phases: \(parts.joined(separator: "  "))")
                }
            }

            // Log relevant boolean flags for cache/trust diagnostics
            let diagnosticFlags = ["prepared_model_cache_hit", "trusted_prepared_checkpoint", "custom_dedicated_prewarm_skipped"]
            let flagParts = diagnosticFlags.compactMap { key -> String? in
                guard let value = r.booleanFlags[key] else { return nil }
                return "\(key)=\(value)"
            }
            if !flagParts.isEmpty {
                Self.logger.notice("[Benchmark]   flags: \(flagParts.joined(separator: "  "))")
            }
        }
        Self.logger.notice("[Benchmark] ────────────────────────────────────────────")
    }

    private nonisolated func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingCString: $0) ?? "unknown"
            }
        }
    }
}

private extension ContinuousClock.Instant {
    var elapsedMs: Int {
        let d = duration(to: .now)
        let components = d.components
        return Int(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000)
    }
}
