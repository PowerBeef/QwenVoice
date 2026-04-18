import Foundation

enum NativeRuntimeStage: String, Sendable {
    case upstreamModelLoad = "upstream_model_load"
    case prewarm = "prewarm"
    case streamStartup = "stream_startup"
    case firstChunk = "first_chunk"
    case streamCompleted = "stream_completed"
    case streamFailed = "stream_failed"
    case unload = "unload"
}

actor NativeTelemetryRecorder {
    private let startUptimeSeconds: TimeInterval
    private var stageMarks: [NativeTelemetryStageMark] = []

    init(startUptimeSeconds: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.startUptimeSeconds = startUptimeSeconds
    }

    func mark(stage: String, metadata: [String: String] = [:]) {
        stageMarks.append(
            NativeTelemetryStageMark(
                tMS: elapsedMilliseconds,
                stage: stage,
                metadata: metadata
            )
        )
    }

    func snapshot() -> [NativeTelemetryStageMark] {
        stageMarks.sorted { lhs, rhs in
            if lhs.tMS == rhs.tMS {
                return lhs.stage < rhs.stage
            }
            return lhs.tMS < rhs.tMS
        }
    }

    func reset() {
        stageMarks.removeAll(keepingCapacity: false)
    }

    private var elapsedMilliseconds: Int {
        Int((ProcessInfo.processInfo.systemUptime - startUptimeSeconds) * 1_000)
    }
}

extension NativeTelemetryRecorder {
    func mark(stage: NativeRuntimeStage, metadata: [String: String] = [:]) {
        mark(stage: stage.rawValue, metadata: metadata)
    }
}

struct NativeTelemetrySummary: Sendable {
    let totalTimeMS: Int
    let stageMarks: [NativeTelemetryStageMark]
}

actor NativeTelemetrySampler {
    private let startUptimeSeconds: TimeInterval

    init(startUptimeSeconds: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.startUptimeSeconds = startUptimeSeconds
    }

    func stop(stageMarks: [NativeTelemetryStageMark]) -> NativeTelemetrySummary {
        NativeTelemetrySummary(
            totalTimeMS: Int((ProcessInfo.processInfo.systemUptime - startUptimeSeconds) * 1_000),
            stageMarks: stageMarks.sorted { lhs, rhs in
                if lhs.tMS == rhs.tMS {
                    return lhs.stage < rhs.stage
                }
                return lhs.tMS < rhs.tMS
            }
        )
    }
}
