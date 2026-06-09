import Foundation
import QwenVoiceCore

/// Collects the **user-perceived** generation milestones — submit → first chunk
/// delivered → first audible playback → completion — and writes the app-layer row
/// of the unified telemetry artifact, keyed by the app-minted `generationID` so it
/// joins the middle/engine rows.
///
/// `@MainActor` because every hook site already runs on the main actor
/// (`AudioPlayerViewModel`, the generate coordinators), so recording a milestone is
/// a synchronous dictionary write with no actor hop on the hot chunk path. The only
/// off-main work is the final JSONL write, dispatched via `Task.detached`.
///
/// Lives in `SharedSupport` so both the macOS and iOS app surfaces use it; the
/// per-target `AppPaths` resolves the correct app-support directory in each build.
@MainActor
final class AppGenerationTimeline {
    static let shared = AppGenerationTimeline()

    private struct Marks {
        let submittedAt: ContinuousClock.Instant
        var firstChunkAt: ContinuousClock.Instant?
        var firstAudibleAt: ContinuousClock.Instant?
        var mode: String?
    }

    private var marksByID: [String: Marks] = [:]
    /// Generations currently holding a `MainThreadStallWatchdog` session —
    /// kept separately from `marksByID` so the watchdog refcount stays
    /// balanced through evictions and failures.
    private var watchdogSessions: Set<String> = []
    private let clock = ContinuousClock()
    /// Backstop against unbounded growth if a `completed` is ever missed.
    private static let maxTrackedGenerations = 16

    private init() {}

    func recordSubmitted(id: UUID?, mode: String?) {
        guard TelemetryGate.appProcessIntendedEnabled else { return }
        guard let key = id?.uuidString else { return }
        if marksByID.count >= Self.maxTrackedGenerations {
            marksByID.removeAll(keepingCapacity: true)
            for _ in watchdogSessions { MainThreadStallWatchdog.shared.end() }
            watchdogSessions.removeAll(keepingCapacity: true)
        }
        marksByID[key] = Marks(submittedAt: clock.now, mode: mode)
        if watchdogSessions.insert(key).inserted {
            MainThreadStallWatchdog.shared.begin()
        }
    }

    /// Balance the watchdog/marks for a generation that failed or was
    /// cancelled before `recordCompleted` — call from coordinator catch
    /// paths. No app-layer row is written for failures (unchanged behavior).
    func recordFailed(id: UUID?) {
        guard let key = id?.uuidString else { return }
        marksByID.removeValue(forKey: key)
        if watchdogSessions.remove(key) != nil {
            MainThreadStallWatchdog.shared.end()
        }
    }

    /// `id` is the player's session id string (== `generationID.uuidString` whenever
    /// the app minted one, which it now always does). First call per id wins.
    func recordFirstChunk(id: String?) {
        guard let id, var marks = marksByID[id], marks.firstChunkAt == nil else { return }
        marks.firstChunkAt = clock.now
        marksByID[id] = marks
    }

    func recordFirstAudible(id: String?) {
        guard let id, var marks = marksByID[id], marks.firstAudibleAt == nil else { return }
        marks.firstAudibleAt = clock.now
        marksByID[id] = marks
    }

    func recordCompleted(
        id: UUID?,
        mode: String?,
        usedStreaming: Bool,
        finishReason: String?,
        summary: TelemetrySummary?
    ) {
        guard TelemetryGate.appProcessIntendedEnabled else { return }
        guard let key = id?.uuidString else { return }
        let now = clock.now
        let marks = marksByID.removeValue(forKey: key)

        // UI-responsiveness KPI: the report is only available when this is
        // the last active generation (overlapping generations share one
        // watchdog window, so per-generation attribution isn't meaningful —
        // the counters are simply omitted on all but the closing row).
        var counters: [String: Int] = [:]
        if watchdogSessions.remove(key) != nil,
           let report = MainThreadStallWatchdog.shared.end() {
            counters = report.asCounters
        }

        var timingsMS: [String: Int] = [:]
        if let marks {
            timingsMS["submitToCompletedMS"] = Self.milliseconds(from: marks.submittedAt, to: now)
            if let firstChunkAt = marks.firstChunkAt {
                timingsMS["submitToFirstChunkMS"] = Self.milliseconds(from: marks.submittedAt, to: firstChunkAt)
            }
            if let firstAudibleAt = marks.firstAudibleAt {
                timingsMS["submitToFirstAudibleMS"] = Self.milliseconds(from: marks.submittedAt, to: firstAudibleAt)
            }
        }

        let record = GenerationTelemetryRecord(
            generationID: key,
            layer: .app,
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            mode: mode ?? marks?.mode,
            usedStreaming: usedStreaming,
            finishReason: finishReason,
            summary: summary,
            timingsMS: timingsMS,
            counters: counters
        )
        let appSupportDirectory = AppPaths.appSupportDir
        Task.detached(priority: .background) {
            await GenerationTelemetryJSONLSink.shared.write(
                record: record,
                appSupportDirectory: appSupportDirectory,
                subdirectory: "app"
            )
        }
    }

    private static func milliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Int {
        let duration = start.duration(to: end)
        let components = duration.components
        // 1 ms == 1e15 attoseconds.
        let millis = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return Int(millis.rounded())
    }
}
