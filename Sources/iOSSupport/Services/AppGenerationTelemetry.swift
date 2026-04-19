import Foundation
import QwenVoiceCore

struct UITestGenerationTelemetryConfiguration {
    let requestID: String
    let outputDirectory: URL
    let sampleIntervalMS: Int
    let label: String?

    init?(
        requestID: String?,
        outputDirectoryPath: String?,
        sampleIntervalMS: Int?,
        label: String?
    ) {
        guard let requestID,
              !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let outputDirectoryPath,
              !outputDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        self.requestID = requestID
        self.outputDirectory = Self.resolveOutputDirectory(path: outputDirectoryPath)
        self.sampleIntervalMS = max(sampleIntervalMS ?? 50, 1)
        self.label = label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func resolveOutputDirectory(path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if NSString(string: trimmed).isAbsolutePath {
            return URL(fileURLWithPath: trimmed, isDirectory: true)
        }
        return AppPaths.appSupportDir.appendingPathComponent(trimmed, isDirectory: true)
    }
}

struct UITestGenerationRequest {
    let requestID: String?
    let telemetry: UITestGenerationTelemetryConfiguration?

    static func from(_ notification: Notification) -> UITestGenerationRequest {
        let userInfo = notification.userInfo ?? [:]
        let requestID = (userInfo["requestID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let telemetry = UITestGenerationTelemetryConfiguration(
            requestID: requestID,
            outputDirectoryPath: userInfo["telemetryOutputDir"] as? String,
            sampleIntervalMS: userInfo["sampleIntervalMS"] as? Int,
            label: userInfo["telemetryLabel"] as? String
        )
        return UITestGenerationRequest(
            requestID: requestID,
            telemetry: telemetry
        )
    }

    static func uiDrivenIfConfigured(mode: GenerationMode) -> UITestGenerationRequest? {
        let environment = ProcessInfo.processInfo.environment
        let requestID = environment["QVOICE_UI_TEST_REQUEST_ID"]?.nilIfEmpty
        let telemetry = UITestGenerationTelemetryConfiguration(
            requestID: requestID,
            outputDirectoryPath: environment["QVOICE_UI_TEST_TELEMETRY_OUTPUT_DIR"],
            sampleIntervalMS: environment["QVOICE_UI_TEST_SAMPLE_INTERVAL_MS"].flatMap(Int.init),
            label: environment["QVOICE_UI_TEST_TELEMETRY_LABEL"] ?? mode.rawValue
        )
        guard requestID != nil || telemetry != nil else {
            return nil
        }
        return UITestGenerationRequest(
            requestID: requestID,
            telemetry: telemetry
        )
    }
}

@MainActor
final class AppGenerationTelemetryCoordinator {
    static let shared = AppGenerationTelemetryCoordinator()

    private struct TelemetryPoint: Codable {
        let stage: String
        let chunkIndex: Int?
        let capturedAt: String
        let snapshot: IOSMemorySnapshot
    }

    private struct TelemetryReport: Codable {
        let requestID: String
        let mode: String
        let label: String?
        let startedAt: String
        let finishedAt: String
        let succeeded: Bool
        let error: String?
        let benchmarkSample: BenchmarkSample?
        let points: [TelemetryPoint]
    }

    private struct ActiveSession {
        let mode: GenerationMode
        let requestID: String
        let telemetry: UITestGenerationTelemetryConfiguration
        let startedAt: Date
        var points: [TelemetryPoint]
    }

    private let timestampFormatter = ISO8601DateFormatter()
    private var activeSession: ActiveSession?
    private var samplingTask: Task<Void, Never>?

    func begin(
        mode: GenerationMode,
        requestID: String?,
        telemetry: UITestGenerationTelemetryConfiguration?
    ) async {
        samplingTask?.cancel()
        samplingTask = nil
        guard let telemetry else {
            activeSession = nil
            return
        }
        let resolvedRequestID = requestID ?? telemetry.requestID
        activeSession = ActiveSession(
            mode: mode,
            requestID: resolvedRequestID,
            telemetry: telemetry,
            startedAt: Date(),
            points: [
                makePoint(stage: "begin", chunkIndex: nil)
            ]
        )
        samplingTask = Task { [sampleIntervalMS = telemetry.sampleIntervalMS] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(sampleIntervalMS))
                await recordPeriodicSample()
            }
        }
    }

    func recordPreviewChunk(chunkIndex: Int) async {
        guard activeSession != nil else { return }
        activeSession?.points.append(
            makePoint(stage: "preview_chunk", chunkIndex: chunkIndex)
        )
    }

    func recordStage(_ stage: String) async {
        guard activeSession != nil else { return }
        activeSession?.points.append(
            makePoint(stage: stage, chunkIndex: nil)
        )
    }

    func publishSuccess(
        mode: GenerationMode,
        requestID: String?,
        result: GenerationResult
    ) async {
        samplingTask?.cancel()
        samplingTask = nil
        guard var session = activeSession else { return }
        guard session.mode == mode else { return }
        if let requestID, requestID != session.requestID {
            return
        }
        session.points.append(makePoint(stage: "success", chunkIndex: nil))
        writeReport(
            TelemetryReport(
                requestID: session.requestID,
                mode: session.mode.rawValue,
                label: session.telemetry.label,
                startedAt: timestampFormatter.string(from: session.startedAt),
                finishedAt: timestampFormatter.string(from: Date()),
                succeeded: true,
                error: nil,
                benchmarkSample: result.benchmarkSample,
                points: session.points
            ),
            outputDirectory: session.telemetry.outputDirectory
        )
        activeSession = nil
    }

    func publishFailure(
        mode: GenerationMode,
        requestID: String?,
        error: Error
    ) async {
        samplingTask?.cancel()
        samplingTask = nil
        guard var session = activeSession else { return }
        guard session.mode == mode else { return }
        if let requestID, requestID != session.requestID {
            return
        }
        session.points.append(makePoint(stage: "failure", chunkIndex: nil))
        writeReport(
            TelemetryReport(
                requestID: session.requestID,
                mode: session.mode.rawValue,
                label: session.telemetry.label,
                startedAt: timestampFormatter.string(from: session.startedAt),
                finishedAt: timestampFormatter.string(from: Date()),
                succeeded: false,
                error: error.localizedDescription,
                benchmarkSample: nil,
                points: session.points
            ),
            outputDirectory: session.telemetry.outputDirectory
        )
        activeSession = nil
    }

    private func makePoint(stage: String, chunkIndex: Int?) -> TelemetryPoint {
        TelemetryPoint(
            stage: stage,
            chunkIndex: chunkIndex,
            capturedAt: timestampFormatter.string(from: Date()),
            snapshot: IOSMemorySnapshot.capture()
        )
    }

    private func recordPeriodicSample() async {
        guard activeSession != nil else { return }
        activeSession?.points.append(
            makePoint(stage: "sample", chunkIndex: nil)
        )
    }

    private func writeReport(_ report: TelemetryReport, outputDirectory: URL) {
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            let outputURL = outputDirectory.appendingPathComponent(
                "\(report.requestID)_generation_telemetry.json"
            )
            try data.write(to: outputURL, options: .atomic)
        } catch {
            return
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
