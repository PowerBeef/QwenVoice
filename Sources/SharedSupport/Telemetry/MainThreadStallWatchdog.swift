import Foundation

/// Measures main-thread responsiveness during generation — the project's
/// "does the UI lag under engine load" KPI.
///
/// Mechanism: a utility-QoS `DispatchSourceTimer` ticks every 100 ms and
/// dispatches a no-op block to the main queue, measuring the block's arrival
/// latency. A saturated main thread delays the measurement block itself,
/// which is exactly the metric we want: how late a user event would be
/// serviced right now. Stalls are bucketed at >50 ms (noticeable) and
/// >250 ms (a visible hang per Apple's hang-detection threshold).
///
/// Lifecycle: `begin()`/`end()` are refcounted so overlapping generations
/// (e.g. batch + single) share one timer. Callers only invoke it when
/// `TelemetryGate` is on (same convention as `AppGenerationTimeline`), so
/// shipped non-debug runs never start the timer. The whole thing costs one
/// no-op main-queue block per 100 ms while a generation is active.
final class MainThreadStallWatchdog: @unchecked Sendable {
    struct Report {
        let stallCount50: Int
        let stallCount250: Int
        let maxStallMS: Int
        let heartbeatCount: Int

        var asCounters: [String: Int] {
            [
                "uiStallCount50": stallCount50,
                "uiStallCount250": stallCount250,
                "uiMaxStallMS": maxStallMS,
                "uiHeartbeats": heartbeatCount,
            ]
        }
    }

    static let shared = MainThreadStallWatchdog()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.qwenvoice.ui-watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var activeSessions = 0

    private var stallCount50 = 0
    private var stallCount250 = 0
    private var maxStallMS = 0
    private var heartbeatCount = 0

    private init() {}

    /// Start (or join) a measurement session.
    func begin() {
        lock.lock()
        defer { lock.unlock() }
        activeSessions += 1
        guard timer == nil else { return }

        stallCount50 = 0
        stallCount250 = 0
        maxStallMS = 0
        heartbeatCount = 0

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let sentAt = ContinuousClock.now
            DispatchQueue.main.async {
                let latency = sentAt.duration(to: ContinuousClock.now)
                let ms = Int(Double(latency.components.seconds) * 1_000
                    + Double(latency.components.attoseconds) / 1_000_000_000_000_000)
                self.lock.lock()
                self.heartbeatCount += 1
                if ms > 50 { self.stallCount50 += 1 }
                if ms > 250 { self.stallCount250 += 1 }
                if ms > self.maxStallMS { self.maxStallMS = ms }
                self.lock.unlock()
            }
        }
        source.resume()
        timer = source
    }

    /// Leave the session; returns the accumulated report when the last
    /// participant leaves (nil while other generations are still active,
    /// or when `end()` is called without a matching `begin()`).
    @discardableResult
    func end() -> Report? {
        lock.lock()
        defer { lock.unlock() }
        guard activeSessions > 0 else { return nil }
        activeSessions -= 1
        guard activeSessions == 0 else { return nil }

        timer?.cancel()
        timer = nil
        return Report(
            stallCount50: stallCount50,
            stallCount250: stallCount250,
            maxStallMS: maxStallMS,
            heartbeatCount: heartbeatCount
        )
    }
}
