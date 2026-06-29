import Combine
import Foundation
import OSLog
import QwenVoiceCore
import QwenVoiceEngineSupport

private final class EngineReplyHandlerBox: @unchecked Sendable {
    let reply: (Data) -> Void

    init(reply: @escaping (Data) -> Void) {
        self.reply = reply
    }
}

private actor ServiceActiveGenerationCoordinator {
    private struct ActiveGeneration {
        let id: UUID
        let cancel: @Sendable () -> Void
    }

    private var activeGeneration: ActiveGeneration?

    var hasActive: Bool {
        activeGeneration != nil
    }

    func register(cancel: @escaping @Sendable () -> Void) throws -> UUID {
        guard activeGeneration == nil else {
            throw TTSEngineError.generationFailed(
                "The engine is already generating audio. Wait for it to finish or cancel it before starting another generation."
            )
        }
        let id = UUID()
        activeGeneration = ActiveGeneration(id: id, cancel: cancel)
        return id
    }

    func finish(id: UUID) {
        guard activeGeneration?.id == id else { return }
        activeGeneration = nil
    }

    func cancelCurrent() {
        let cancel = activeGeneration?.cancel
        activeGeneration = nil
        cancel?()
    }
}

/// Serializes diagnostic JSONL appends so concurrent detached Tasks don't
/// interleave partial lines or race on file-handle creation.
private actor DiagnosticEventRecorder {
    func append(line: String, to url: URL) {
        guard TelemetryGate.resolvedEnabled else { return }
        let diagnosticsDirectory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let encoded = line.data(using: .utf8) {
                    try handle.write(contentsOf: encoded)
                }
            } else {
                try line.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            diagnosticEventLogger.error("Failed to record diagnostic event: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private let diagnosticEventRecorder = DiagnosticEventRecorder()
private let diagnosticEventLogger = Logger(
    subsystem: "com.qwenvoice.app",
    category: "DiagnosticEventRecorder"
)

@MainActor
private final class RuntimeContext: @unchecked Sendable {
    let appSupportDirectory: URL
    let engine: MLXTTSEngine
    var cancellables: Set<AnyCancellable> = []
    var lastPublishedEvent: GenerationEvent?
    var lastPublishedSnapshot: TTSEngineSnapshot?
    /// Long-running Task that drains the engine's bounded `events`
    /// AsyncStream and publishes each event over XPC in order while the
    /// consumer stays active. Replaces the prior
    /// `objectWillChange.sink` slot-sampling path that could
    /// silently drop the trailing `.chunk` event when
    /// `NativeStreamingSynthesisSession.run` emitted it
    /// back-to-back with `.completed`. Cancelled when the
    /// `RuntimeContext` is replaced (only happens on a fresh
    /// `appSupportDirectory`); otherwise lives for the host's
    /// lifetime.
    var eventForwardingTask: Task<Void, Never>?

    init(appSupportDirectory: URL, engine: MLXTTSEngine) {
        self.appSupportDirectory = appSupportDirectory
        self.engine = engine
    }
}

final class EngineServiceHost: NSObject, NSXPCListenerDelegate, QwenVoiceEngineServiceXPCProtocol, @unchecked Sendable {
    static let shared = EngineServiceHost()

    private struct ActiveSession {
        let id: UUID
        let eventSink: QwenVoiceEngineClientEventXPCProtocol
    }

    private static let logger = Logger(
        subsystem: "com.qwenvoice.app",
        category: "EngineServiceHost"
    )

    /// Encodes a failure-shaped reply that preserves the original request id
    /// so the client can match it to the pending request and resolve the
    /// in-flight continuation. The previous implementation used a static
    /// pre-encoded constant with a random `UUID()`, which the client silently
    /// dropped (no pending request matched the id) — leaving `.generate` and
    /// `.generateBatch` calls (which carry no transport timeout) hung
    /// indefinitely whenever response encoding failed (e.g., a non-finite
    /// numeric metadata field made it into the payload).
    private static func encodeFailureFallback(for requestID: UUID, underlyingError: Error) -> Data {
        let fallback = EngineReplyEnvelope(
            id: requestID,
            reply: .failure(
                RemoteErrorPayload(
                    message: "The engine service failed to encode its reply: \(underlyingError.localizedDescription)"
                )
            )
        )
        do {
            return try EngineServiceCodec.encode(fallback)
        } catch {
            EngineServiceHost.logger.fault(
                "Failed to encode engine-service failure fallback for id \(requestID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            // Degenerate path: even a minimal failure envelope failed to
            // encode. Returning empty Data forces the client into its
            // `invalidReply` disconnect handler, which is preferable to
            // silently dropping the reply because the id doesn't match.
            return Data()
        }
    }

    /// Synchronous-only lock wrapper. `NSLock.lock()`/`unlock()` are marked
    /// `noasync` in recent SDKs, so the host uses this for short critical
    /// sections that are accessed from both sync and async call sites.
    private final class SynchronousLock {
        private let lock = NSLock()
        func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    private let sessionLock = SynchronousLock()
    private let activeGenerationCoordinator = ServiceActiveGenerationCoordinator()
    private var activeSession: ActiveSession?
    private var runtimeContext: RuntimeContext?
    private var droppedEncodeEventCount = 0

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let sessionID = UUID()
        newConnection.setCodeSigningRequirement(
            EngineServiceTrustPolicy.clientRequirementForCurrentBundle()
        )
        newConnection.exportedInterface = NSXPCInterface(with: QwenVoiceEngineServiceXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.remoteObjectInterface = NSXPCInterface(with: QwenVoiceEngineClientEventXPCProtocol.self)
        let eventSink = newConnection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.handleSessionEnded(
                sessionID: sessionID,
                message: "Event sink remote error: \(error.localizedDescription)"
            )
        } as? QwenVoiceEngineClientEventXPCProtocol
        guard let eventSink else {
            Self.logger.error("Failed to create event sink for new engine-service session.")
            return false
        }
        activateSession(id: sessionID, eventSink: eventSink)
        newConnection.invalidationHandler = { [weak self] in
            self?.handleSessionEnded(
                sessionID: sessionID,
                message: "Engine-service session invalidated."
            )
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.handleSessionEnded(
                sessionID: sessionID,
                message: "Engine-service session interrupted."
            )
        }
        newConnection.resume()
        Task { @MainActor [weak self] in
            guard let self, let runtimeContext = self.runtimeContext else { return }
            self.publish(.snapshot(Self.snapshot(for: runtimeContext.engine)), toSessionID: sessionID)
        }
        return true
    }

    func perform(_ payload: Data, withReply reply: @escaping (Data) -> Void) {
        let replyHandler = EngineReplyHandlerBox(reply: reply)
        let capturedSessionID = sessionLock.withLock { activeSession?.id }
        Task.detached(priority: .userInitiated) { [weak self, payload] in
            guard let self else { return }
            let response = await self.handleCommandPayload(payload)
            let encodedResponse: Data
            do {
                encodedResponse = try EngineServiceCodec.encode(response)
            } catch {
                Self.logger.error(
                    "Failed to encode engine-service reply (id \(response.id.uuidString, privacy: .public)): \(error.localizedDescription, privacy: .public)"
                )
                encodedResponse = Self.encodeFailureFallback(
                    for: response.id,
                    underlyingError: error
                )
            }
            let sessionStillActive = self.sessionLock.withLock {
                self.activeSession?.id == capturedSessionID
            }
            guard sessionStillActive else {
                Self.logger.debug("Dropping engine-service reply for a session that is no longer active.")
                return
            }
            replyHandler.reply(encodedResponse)
        }
    }

    @MainActor
    private func handleCommandPayload(_ payload: Data) async -> EngineReplyEnvelope {
        do {
            let request = try EngineServiceCodec.decode(EngineRequestEnvelope.self, from: payload)
            do {
                return EngineReplyEnvelope(
                    id: request.id,
                    reply: try await perform(request.command)
                )
            } catch {
                return EngineReplyEnvelope(
                    id: request.id,
                    reply: .failure(RemoteErrorPayload.make(for: error))
                )
            }
        } catch {
            Self.logger.error("Failed to decode engine request envelope: \(error.localizedDescription, privacy: .public)")
            return EngineReplyEnvelope(
                id: UUID(),
                reply: .failure(RemoteErrorPayload.make(for: error))
            )
        }
    }

    @MainActor
    private func perform(_ command: EngineCommand) async throws -> EngineReply {
        switch command {
        case .initialize(let appSupportDirectoryPath, let telemetryMode, let forcedMemoryClass):
            // The app process resolves the telemetry MODE (env + the persisted 7-tap
            // gesture flag, neither of which crosses the process boundary) and reports
            // it here. One-way latch — enables durable telemetry in this engine-service
            // process, and carries `verbose` so the raw-sample sidecar can fire.
            TelemetryGate.applyHandshakeMode(NativeTelemetryMode(rawValue: telemetryMode) ?? .off)
            // Benchmark tier override (env doesn't cross to this process either) —
            // forces the constrained-tier code paths so memory pressure is measurable.
            NativeDeviceClassGate.applyHandshakeForcedClass(forcedMemoryClass)
            let runtimeContext = try makeOrReuseRuntimeContext(
                appSupportDirectory: URL(fileURLWithPath: appSupportDirectoryPath, isDirectory: true)
            )
            try await runtimeContext.engine.initialize(appSupportDirectory: runtimeContext.appSupportDirectory)
            return .snapshot(Self.snapshot(for: runtimeContext.engine))
        case .ping:
            _ = try await requireRuntimeContext().engine.ping()
            return .capabilities(.macOSXPCDefault)
        case .loadModel(let id):
            try await requireRuntimeContext().engine.loadModel(id: id)
            return .void
        case .unloadModel:
            try await requireRuntimeContext().engine.unloadModel()
            return .void
        case .ensureModelLoadedIfNeeded(let id):
            try await requireRuntimeContext().engine.ensureModelLoadedIfNeeded(id: id)
            return .void
        case .prewarmModelIfNeeded(let request):
            try await requireRuntimeContext().engine.prewarmModelIfNeeded(for: request)
            return .void
        case .prefetchInteractiveReadinessIfNeeded(let request, let customPrewarmDepth):
            let diagnostics = try await requireRuntimeContext().engine.prefetchInteractiveReadinessIfNeeded(
                for: request,
                customPrewarmDepth: customPrewarmDepth
            )
                ?? InteractivePrefetchDiagnostics(
                    timingsMS: [:],
                    booleanFlags: [:],
                    requestKey: nil
                )
            return .interactivePrefetchDiagnostics(diagnostics)
        case .ensureCloneReferencePrimed(let modelID, let reference):
            try await requireRuntimeContext().engine.ensureCloneReferencePrimed(
                modelID: modelID,
                reference: reference
            )
            return .void
        case .cancelClonePreparationIfNeeded:
            try await requireRuntimeContext().engine.cancelClonePreparationIfNeeded()
            return .void
        case .generate(let request):
            let runtimeContext = try requireRuntimeContext()
            let generationTask = Task { @MainActor in
                try await runtimeContext.engine.generate(request)
            }
            let generationID: UUID
            do {
                generationID = try await activeGenerationCoordinator.register {
                    generationTask.cancel()
                }
            } catch {
                generationTask.cancel()
                throw error
            }
            do {
                let result = try await generationTask.value
                await activeGenerationCoordinator.finish(id: generationID)
                return .generationResult(result)
            } catch {
                await activeGenerationCoordinator.finish(id: generationID)
                throw error
            }
        case .generateBatch(let commandID, let requests):
            guard !requests.isEmpty else {
                return .generationResults([])
            }
            let runtimeContext = try requireRuntimeContext()
            let generationTask = Task { @MainActor [weak self] in
                let results = try await runtimeContext.engine.generateBatch(requests) { fraction, message in
                    self?.publish(
                        .batchProgress(
                            EngineBatchProgressUpdate(
                                commandID: commandID,
                                fraction: fraction,
                                message: message
                            )
                        )
                    )
                }
                return results.map(Self.normalizedBatchResult(from:))
            }
            let generationID: UUID
            do {
                generationID = try await activeGenerationCoordinator.register {
                    generationTask.cancel()
                }
            } catch {
                generationTask.cancel()
                throw error
            }
            do {
                let results = try await generationTask.value
                await activeGenerationCoordinator.finish(id: generationID)
                return .generationResults(results)
            } catch {
                await activeGenerationCoordinator.finish(id: generationID)
                throw error
            }
        case .cancelActiveGeneration:
            await activeGenerationCoordinator.cancelCurrent()
            try requireRuntimeContext().engine.clearGenerationActivity()
            return .void
        case .listPreparedVoices:
            return .preparedVoices(try await requireRuntimeContext().engine.listPreparedVoices())
        case .enrollPreparedVoice(let name, let audioPath, let transcript):
            return .preparedVoice(
                try await requireRuntimeContext().engine.enrollPreparedVoice(
                    name: name,
                    audioPath: audioPath,
                    transcript: transcript
                )
            )
        case .deletePreparedVoice(let id):
            try await requireRuntimeContext().engine.deletePreparedVoice(id: id)
            return .void
        case .clearGenerationActivity:
            try requireRuntimeContext().engine.clearGenerationActivity()
            return .void
        case .clearVisibleError:
            try requireRuntimeContext().engine.clearVisibleError()
            return .void
        case .shutdownWhenIdle:
            // Retirement-to-reclaim: exiting is the only way to return MLX
            // heap fragmentation + Metal shader caches to the OS. Refuse
            // while generating; the client treats the exit as expected and
            // relaunches lazily on the next command.
            guard await !activeGenerationCoordinator.hasActive else {
                throw TTSEngineError.generationFailed(
                    "Engine is busy; retirement refused."
                )
            }
            if let runtimeContext {
                try? await runtimeContext.engine.unloadModel()
            }
            // Grace period so the `.void` reply flushes over the wire
            // before the process dies.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) {
                exit(0)
            }
            return .void
        }
    }

    @MainActor
    private func makeOrReuseRuntimeContext(appSupportDirectory: URL) throws -> RuntimeContext {
        if let runtimeContext,
           runtimeContext.appSupportDirectory.standardizedFileURL == appSupportDirectory.standardizedFileURL {
            return runtimeContext
        }

        let manifestURL = try Self.locateManifestURL()
        let registry = try ContractBackedModelRegistry(manifestURL: manifestURL)
            .expandedForPlatform(
                .macOS,
                deviceClass: NativeMemoryPolicyResolver.deviceClass(),
                includeBaseAliases: true
            )
        // Skip the dedicated custom-prewarm step on floor8GBMac to
        // match the iOS in-process engine's policy (which has done this
        // since launch). The prewarm cost
        // moves into the generation proper rather than running upfront,
        // and on a memory-constrained Mac that's the right trade:
        // model load completes faster, peak RSS at startup is lower,
        // and steady-state warm-medium RTF is essentially unaffected
        // (the prewarm work happens once at first generation anyway).
        // mid16GBMac and higher keep `.eager` — there's no benefit
        // to deferring on machines with headroom.
        let customPrewarmPolicy: NativeCustomPrewarmPolicy =
            NativeMemoryPolicyResolver.deviceClass() == .floor8GBMac
                ? .skipDedicatedCustomPrewarm
                : .eager
        let runtime = try NativeRuntimeFactory.make(
            registry: registry,
            paths: .rooted(at: appSupportDirectory),
            storeVersionSeed: Self.storeVersionSeed(),
            customPrewarmPolicy: customPrewarmPolicy
        )
        let runtimeContext = RuntimeContext(
            appSupportDirectory: appSupportDirectory,
            engine: runtime.engine
        )

        // Snapshot publishing — `loadState`, `clonePreparationState`,
        // `visibleErrorMessage` changes need to flow over XPC so the
        // client's UI bindings stay live. Chunk delivery is handled by
        // the AsyncStream below; this sink suppresses unchanged snapshots
        // produced by chunk-only `latestEvent` updates.
        runtime.engine.objectWillChange
            .sink { [weak self, weak runtimeContext] _ in
                Task { @MainActor [weak self, weak runtimeContext] in
                    guard let self, let runtimeContext else { return }
                    let snapshot = Self.snapshot(for: runtimeContext.engine)
                    guard runtimeContext.lastPublishedSnapshot != snapshot else { return }
                    runtimeContext.lastPublishedSnapshot = snapshot
                    self.publish(.snapshot(snapshot))
                }
            }
            .store(in: &runtimeContext.cancellables)

        // Cancel any prior context's forwarding task before we create the new
        // one. Without this ordering, the prior task can race the new one
        // publishing into the same XPC channel.
        self.runtimeContext?.eventForwardingTask?.cancel()

        // Chunk delivery via the engine's ordered AsyncStream. The
        // producer (`MLXTTSEngine`'s
        // `eventSink` callback) yields every event into
        // `engine.events`; this Task drains the stream serially while
        // active. Preview-audio chunks are never dropped here. No
        // slot-sampling, no dedup, no race window.
        let eventStream = runtime.engine.events
        runtimeContext.eventForwardingTask = Task.detached(priority: .utility) { [weak self, weak runtimeContext, appSupportDirectory, eventStream] in
            var expectedChunkSequence: UInt64 = 0
            var gapDetectionGenerationID: UUID?
            // Per-generation middle-layer transport accumulators. Integer/Double
            // arithmetic only on the hot path; the actual JSONL write is deferred to
            // the terminal event and dispatched off this loop (see flush helper),
            // so the unbounded chunk-delivery stream is never blocked on file I/O.
            var transport = EngineServiceTransportAccumulator()
            for await event in eventStream {
                guard let self, let runtimeContext else { return }
                if case .chunk(let chunk) = event, let sequence = chunk.chunkSequence {
                    // chunkSequence restarts at 0 for each generation, so reset
                    // the expected counter when the generation identity changes;
                    // otherwise the gap detector goes dead after generation #1
                    // (and can false-positive on a longer subsequent generation).
                    if chunk.generationID != gapDetectionGenerationID {
                        gapDetectionGenerationID = chunk.generationID
                        expectedChunkSequence = 0
                    }
                    if sequence > expectedChunkSequence + 1 {
                        let expected = expectedChunkSequence + 1
                        // Diagnostics only — never block the chunk-delivery loop
                        // on file I/O (gaps can cluster under buffer pressure).
                        Task.detached(priority: .background) {
                            Self.recordChunkSequenceGap(
                                expected: expected,
                                received: sequence,
                                appSupportDirectory: appSupportDirectory
                            )
                        }
                        transport.gapCount += 1
                    }
                    expectedChunkSequence = max(expectedChunkSequence, sequence)
                }
                // Accumulate transport telemetry; flushes the engine-service record
                // on terminal events (.completed/.failed) and on generation switch.
                transport.observe(
                    event: event,
                    appSupportDirectory: appSupportDirectory
                )
                let stripped = event.withoutPreviewAudioPayload()
                self.publish(.generationChunk(event))
                await MainActor.run {
                    runtimeContext.lastPublishedEvent = stripped
                }
            }
        }

        self.runtimeContext = runtimeContext
        return runtimeContext
    }

    @MainActor
    private func requireRuntimeContext() throws -> RuntimeContext {
        guard let runtimeContext else {
            throw MLXTTSEngineError.notInitialized
        }
        return runtimeContext
    }

    private func activateSession(id: UUID, eventSink: QwenVoiceEngineClientEventXPCProtocol) {
        let previousSessionID = sessionLock.withLock {
            let previous = activeSession?.id
            activeSession = ActiveSession(id: id, eventSink: eventSink)
            return previous
        }

        if let previousSessionID, previousSessionID != id {
            Self.logger.notice(
                "Replacing active engine-service session \(previousSessionID.uuidString, privacy: .public) with \(id.uuidString, privacy: .public)."
            )
        } else {
            Self.logger.debug("Activated engine-service session \(id.uuidString, privacy: .public).")
        }
    }

    private func handleSessionEnded(sessionID: UUID, message: String) {
        guard clearActiveSessionIfNeeded(sessionID: sessionID) else {
            Self.logger.debug(
                "Ignoring disconnect from stale engine-service session \(sessionID.uuidString, privacy: .public)."
            )
            return
        }

        Self.logger.error("\(message, privacy: .public)")
        Task { @MainActor [weak self] in
            guard let self else { return }

            // If another session has already activated (even if it reuses the
            // same RuntimeContext/engine), this cleanup belongs to a stale
            // session and must not mutate engine state. Capture this under
            // sessionLock before touching runtimeContext.
            let anotherSessionActive = self.sessionLock.withLock { self.activeSession != nil }
            guard !anotherSessionActive else {
                Self.logger.debug(
                    "Skipping stale session cleanup because a new session is already active."
                )
                return
            }

            // Capture the runtime context that was active when this session
            // ended. Re-reading `self.runtimeContext` later in this Task is
            // unsafe: another session may have already replaced it (the host
            // is `EngineServiceHost.shared`, a process-wide singleton across
            // every test in the test bundle). Without this capture-and-
            // identity-check, a stale cleanup Task from session A nils out
            // the active runtime context of session B mid-`initialize`,
            // causing the next call from B's client to throw
            // `MLXTTSEngineError.notInitialized`. See the May 2026 fix
            // commit for the full timeline (Tier 4.4).
            let contextAtSessionEnd = self.runtimeContext
            await self.activeGenerationCoordinator.cancelCurrent()
            guard self.isStillTerminatingSession(sessionID) else { return }
            await contextAtSessionEnd?.engine.cancelClonePreparationIfNeeded()
            contextAtSessionEnd?.engine.clearGenerationActivity()
            guard self.isStillTerminatingSession(sessionID) else { return }
            try? await contextAtSessionEnd?.engine.unloadModel()
            guard self.isStillTerminatingSession(sessionID) else { return }
            // Only clear the host's runtime-context slot if the context that
            // ended is STILL the active one — otherwise a newer session has
            // already taken it over and we must not clobber its state.
            if self.runtimeContext === contextAtSessionEnd {
                self.runtimeContext = nil
            }
        }
    }

    /// True while this ended session's cleanup may still safely run: either no session has
    /// reactivated (`activeSession == nil`, the normal case after `clearActiveSessionIfNeeded`),
    /// or the still-active session is this same one. A DIFFERENT active session means a newer
    /// session took over mid-cleanup, so this stale cleanup must abort and not clobber its state.
    private func isStillTerminatingSession(_ sessionID: UUID) -> Bool {
        self.sessionLock.withLock {
            self.activeSession == nil || self.activeSession?.id == sessionID
        }
    }

    @discardableResult
    private func clearActiveSessionIfNeeded(sessionID: UUID) -> Bool {
        sessionLock.withLock {
            guard activeSession?.id == sessionID else { return false }
            activeSession = nil
            return true
        }
    }

    private func publish(_ event: EngineEventEnvelope, toSessionID: UUID? = nil) {
        let eventSink: QwenVoiceEngineClientEventXPCProtocol? = sessionLock.withLock {
            if let toSessionID {
                return activeSession?.id == toSessionID ? activeSession?.eventSink : nil
            } else {
                return activeSession?.eventSink
            }
        }

        guard let eventSink else { return }
        do {
            let payload = try EngineServiceCodec.encode(event)
            eventSink.handleEvent(payload)
        } catch {
            let droppedCount = sessionLock.withLock {
                droppedEncodeEventCount += 1
                return droppedEncodeEventCount
            }
            let diagnosticsDirectory = runtimeContext?.appSupportDirectory

            Self.logger.error(
                "Failed to encode engine-service event payload (droppedCount=\(droppedCount, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
            Self.recordDroppedEncodeEvent(
                error: error,
                droppedCount: droppedCount,
                appSupportDirectory: diagnosticsDirectory
            )
        }
    }

    private static func recordChunkSequenceGap(
        expected: UInt64,
        received: UInt64,
        appSupportDirectory: URL
    ) {
        let diagnosticsDirectory = appSupportDirectory
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent("engine-service", isDirectory: true)
        let url = diagnosticsDirectory.appendingPathComponent("native-events.jsonl", isDirectory: false)
        let record: [String: String] = [
            "event": "engine_service_chunk_gap",
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
            "expectedSequence": String(expected),
            "receivedSequence": String(received),
            "gap": String(received > expected ? received - expected : 0),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: data, encoding: .utf8) else {
            return
        }
        line.append("\n")
        Task.detached(priority: .background) {
            await diagnosticEventRecorder.append(line: line, to: url)
        }
    }

    private static func recordDroppedEncodeEvent(
        error: Error,
        droppedCount: Int,
        appSupportDirectory: URL?
    ) {
        guard let appSupportDirectory else { return }
        let diagnosticsDirectory = appSupportDirectory
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent("engine-service", isDirectory: true)
        let url = diagnosticsDirectory.appendingPathComponent("native-events.jsonl", isDirectory: false)
        let record: [String: String] = [
            "event": "engine_service_encode_dropped",
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
            "droppedCount": String(droppedCount),
            "message": error.localizedDescription,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: data, encoding: .utf8) else {
            return
        }
        line.append("\n")
        Task.detached(priority: .background) {
            await diagnosticEventRecorder.append(line: line, to: url)
        }
    }

    @MainActor
    private static func snapshot(for engine: MLXTTSEngine) -> TTSEngineSnapshot {
        TTSEngineSnapshot(
            isReady: engine.isReady,
            loadState: engine.loadState,
            clonePreparationState: engine.clonePreparationState,
            visibleErrorMessage: engine.visibleErrorMessage
        )
    }

    private static func locateManifestURL() throws -> URL {
        let bundles = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        for bundle in bundles {
            if let url = bundle.url(forResource: "qwenvoice_contract", withExtension: "json") {
                return url
            }
        }
        throw DocumentIOError.missingSource("qwenvoice_contract.json")
    }

    private static func storeVersionSeed(bundle: Bundle = .main) -> String {
        let bundleIdentifier = bundle.bundleIdentifier ?? "com.qwenvoice.app.engine-service"
        let marketingVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let buildVersion = bundle.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "0"
        return "\(bundleIdentifier)|\(marketingVersion)|\(buildVersion)"
    }

    private static func normalizedBatchResult(from result: GenerationResult) -> GenerationResult {
        if let streamSessionDirectoryURL = result.streamSessionDirectoryURL {
            try? FileManager.default.removeItem(at: streamSessionDirectoryURL)
        }
        return GenerationResult(
            audioPath: result.audioPath,
            durationSeconds: result.durationSeconds,
            streamSessionDirectory: nil,
            usedStreaming: false,
            finishReason: result.finishReason
        )
    }
}

/// Accumulates middle-layer (XPC) transport telemetry for one generation as its
/// events stream through the host's forwarding drain, then flushes the
/// engine-service row of the unified telemetry artifact on the terminal event.
///
/// Only integer/Double arithmetic runs on the hot chunk-delivery path; the JSONL
/// write is dispatched off-loop via `Task.detached`, so the unbounded `events`
/// stream is never blocked on file I/O (preserves the no-drop streaming invariant).
private struct EngineServiceTransportAccumulator {
    private var generationID: UUID?
    private var mode: String?
    private var firstChunkUptime: Double?
    private var chunksForwarded = 0
    /// Incremented by the drain's existing gap detector for the current generation.
    var gapCount = 0

    mutating func observe(event: GenerationEvent, appSupportDirectory: URL?) {
        switch event {
        case .chunk(let chunk):
            if chunk.generationID != generationID {
                // New generation: flush the prior one (covers a missing terminal
                // event, e.g. an abrupt cancellation) before starting fresh.
                flush(
                    finishReason: "superseded",
                    usedStreaming: true,
                    notes: [:],
                    appSupportDirectory: appSupportDirectory
                )
                generationID = chunk.generationID
                mode = chunk.mode
                firstChunkUptime = ProcessInfo.processInfo.systemUptime
                chunksForwarded = 0
                gapCount = 0
            }
            chunksForwarded += 1
        case .completed(let result):
            flush(
                finishReason: result.finishReason?.rawValue ?? "completed",
                usedStreaming: result.usedStreaming,
                notes: [:],
                appSupportDirectory: appSupportDirectory
            )
            reset()
        case .failed(let message):
            flush(
                finishReason: "failed",
                usedStreaming: true,
                notes: ["message": message],
                appSupportDirectory: appSupportDirectory
            )
            reset()
        case .progress:
            break
        }
    }

    private mutating func reset() {
        generationID = nil
        mode = nil
        firstChunkUptime = nil
        chunksForwarded = 0
        gapCount = 0
    }

    private func flush(
        finishReason: String,
        usedStreaming: Bool,
        notes: [String: String],
        appSupportDirectory: URL?
    ) {
        guard TelemetryGate.resolvedEnabled else { return }
        guard let generationID, chunksForwarded > 0 else { return }
        var timingsMS: [String: Int] = [:]
        if let firstChunkUptime {
            let spanSeconds = ProcessInfo.processInfo.systemUptime - firstChunkUptime
            let spanMS = Int(spanSeconds * 1_000)
            timingsMS["chunkForwardingSpanMS"] = max(0, spanMS)
            let spanNS = UInt64(spanSeconds * 1_000_000_000)
            timingsMS["chunkForwardingSpanNS"] = Int(min(UInt64(Int.max), spanNS))
        }
        let record = GenerationTelemetryRecord(
            generationID: generationID.uuidString,
            layer: .engineService,
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            mode: mode,
            usedStreaming: usedStreaming,
            finishReason: finishReason,
            timingsMS: timingsMS,
            counters: ["chunksForwarded": chunksForwarded, "chunkGaps": gapCount],
            notes: notes.merging(currentTaskQOSNotes()) { current, _ in current }
        )
        Task.detached(priority: .background) {
            await GenerationTelemetryJSONLSink.shared.write(
                record: record,
                appSupportDirectory: appSupportDirectory,
                subdirectory: "engine-service"
            )
        }
    }
}
