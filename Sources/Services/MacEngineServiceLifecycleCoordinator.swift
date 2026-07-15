import Foundation
import QwenVoiceCore
import QwenVoiceNative

/// Decides when to retire the XPC engine service on memory-constrained Macs
/// — the one memory-reclaim lever process separation uniquely enables.
///
/// Model unload (the engine's adaptive idle-unload) returns the weights, but
/// MLX heap fragmentation and Metal shader caches stay resident in the
/// service for its lifetime. On a pressured 8 GB Mac that's real memory the
/// UI needs. Exiting the service returns ALL of it; the client treats the
/// exit as expected (no error UI) and lazily relaunches on next use, so the
/// only cost is a slightly colder next generation on a tier whose idle-unload
/// already made the next generation cold.
///
/// Trigger rule (deliberately conservative, first iteration):
///   deviceClass == floor8GBMac (incl. forced)
///   AND loadState == .idle (idle-unload already fired, or nothing loaded)
///   AND no active generation
///   AND (a hardTrim pressure event was observed since the last generation
///        OR the engine has been idle > the dwell threshold)
///   → after a 30 s grace with no activity → retire.
/// Activity (snapshot leaving idle, generation starting) disarms everything.
@MainActor
final class MacEngineServiceLifecycleCoordinator {
    private let deviceClass: NativeDeviceMemoryClass
    private let monitor: NativeMemoryPressureMonitor
    private let retirementGrace: Duration
    private let idleDwellThreshold: Duration

    private weak var ttsEngineStore: TTSEngineStore?
    private weak var warmupCoordinator: MacGenerationWarmupCoordinator?

    private var hardTrimSinceLastGeneration = false
    private var idleSince: ContinuousClock.Instant?
    /// Grace timer once eligible.
    private var armedTask: Task<Void, Never>?
    /// Wake-up while idle-but-not-yet-eligible (nothing else re-fires
    /// `observe` during a quiet idle stretch).
    private var dwellRecheckTask: Task<Void, Never>?
    private var pressureEventTask: Task<Void, Never>?

    /// Dev override for the idle dwell (seconds) so retirement can be
    /// exercised without an 8-minute wait: QWENVOICE_ENGINE_RETIRE_DWELL_SECONDS.
    private static var defaultIdleDwell: Duration {
        if let raw = RuntimeDebugGate.value(for: "QWENVOICE_ENGINE_RETIRE_DWELL_SECONDS"),
           let seconds = Int(raw), seconds > 0 {
            return .seconds(seconds)
        }
        return .seconds(300)
    }

    init(
        deviceClass: NativeDeviceMemoryClass = NativeMemoryPolicyResolver.deviceClass(),
        retirementGrace: Duration = .seconds(30),
        idleDwellThreshold: Duration = MacEngineServiceLifecycleCoordinator.defaultIdleDwell
    ) {
        self.deviceClass = deviceClass
        self.retirementGrace = retirementGrace
        self.idleDwellThreshold = idleDwellThreshold
        self.monitor = NativeMemoryPressureMonitor(
            label: "com.qwenvoice.app.engine-lifecycle-pressure"
        )
        guard deviceClass == .floor8GBMac else { return }
        monitor.start()
        pressureEventTask = Task { [weak self, monitor] in
            for await level in monitor.events {
                guard let self else { return }
                if level == .hardTrim {
                    self.hardTrimSinceLastGeneration = true
                    self.evaluate()
                }
            }
        }
    }

    deinit {
        armedTask?.cancel()
        dwellRecheckTask?.cancel()
        pressureEventTask?.cancel()
        // Stop the kernel DispatchSource + finish the stream, not just the consumer.
        monitor.stop()
    }

    /// Feed every snapshot / activity change here (ContentView's existing
    /// engine-snapshot observation point).
    func observe(
        snapshot: TTSEngineSnapshot,
        hasActiveGeneration: Bool,
        ttsEngineStore: TTSEngineStore,
        warmupCoordinator: MacGenerationWarmupCoordinator
    ) {
        guard deviceClass == .floor8GBMac else { return }
        self.ttsEngineStore = ttsEngineStore
        self.warmupCoordinator = warmupCoordinator

        if hasActiveGeneration {
            hardTrimSinceLastGeneration = false
            idleSince = nil
            disarm()
            return
        }

        guard case .idle = snapshot.loadState, snapshot.isReady else {
            idleSince = nil
            disarm()
            return
        }

        if idleSince == nil {
            idleSince = ContinuousClock.now
        }
        evaluate()
    }

    /// Run the trigger rule; arms the grace timer when eligible, otherwise
    /// schedules a dwell re-check (observe() won't re-fire on a quiet idle).
    private func evaluate() {
        guard deviceClass == .floor8GBMac,
              let ttsEngineStore,
              case .idle = ttsEngineStore.snapshot.loadState,
              !ttsEngineStore.hasActiveGeneration,
              let idleSince else { return }

        let dwelled = idleSince.duration(to: .now)
        if hardTrimSinceLastGeneration || dwelled >= idleDwellThreshold {
            arm()
        } else if dwellRecheckTask == nil {
            let remaining = idleDwellThreshold - dwelled + .seconds(1)
            dwellRecheckTask = Task { @MainActor [weak self] in
                defer { self?.dwellRecheckTask = nil }
                try? await Task.sleep(for: remaining)
                guard !Task.isCancelled else { return }
                self?.evaluate()
            }
        }
    }

    private func arm() {
        guard armedTask == nil else { return }
        armedTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: self?.retirementGrace ?? .seconds(30))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            defer { self.armedTask = nil }
            guard let ttsEngineStore = self.ttsEngineStore,
                  case .idle = ttsEngineStore.snapshot.loadState,
                  !ttsEngineStore.hasActiveGeneration else { return }

            // Keep the warm coordinator from immediately relaunching the
            // fresh-idle service (its admission policy also defers warms
            // while pressured, which is what makes retirement stick).
            self.warmupCoordinator?.cancelPendingWarmup()

            let retired = await ttsEngineStore.retireServiceIfIdle()
            if retired {
                self.hardTrimSinceLastGeneration = false
                self.idleSince = nil
                Self.recordRetirement()
            }
        }
    }

    private func disarm() {
        armedTask?.cancel()
        armedTask = nil
        dwellRecheckTask?.cancel()
        dwellRecheckTask = nil
    }

    /// One JSONL event per retirement (diagnostics/app/native-events.jsonl);
    /// the next generation's `warmState: .cold` row quantifies the cost.
    private static func recordRetirement() {
        guard TelemetryGate.appProcessIntendedEnabled else { return }
        let appSupportDirectory = AppPaths.appSupportDir
        Task.detached(priority: .background) {
            let event: [String: Any] = [
                "event": "engine_service_retired",
                "recordedAt": ISO8601DateFormatter().string(from: Date()),
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: event),
                  var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"
            let dir = appSupportDirectory.appendingPathComponent("diagnostics/app", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("native-events.jsonl")
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? line.data(using: .utf8)?.write(to: url)
            }
        }
    }
}
