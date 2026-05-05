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

    func register(cancel: @escaping @Sendable () -> Void) -> UUID {
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

@MainActor
private final class RuntimeContext: @unchecked Sendable {
    let appSupportDirectory: URL
    let engine: MLXTTSEngine
    var cancellables: Set<AnyCancellable> = []
    var lastPublishedEvent: GenerationEvent?
    /// Audit Finding #1 — long-running Task that drains the
    /// engine's lossless `events` AsyncStream and publishes each
    /// event over XPC in order. Replaces the prior
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

    private static let encodedFailureFallback: Data = {
        do {
            return try EngineServiceCodec.encode(
                EngineReplyEnvelope(
                    id: UUID(),
                    reply: .failure(
                        RemoteErrorPayload(message: "The engine service failed to encode its reply.")
                    )
                )
            )
        } catch {
            EngineServiceHost.logger.fault(
                "Failed to pre-encode engine-service failure fallback: \(error.localizedDescription, privacy: .public)"
            )
            return Data()
        }
    }()

    private let sessionLock = NSLock()
    private let activeGenerationCoordinator = ServiceActiveGenerationCoordinator()
    private var activeSession: ActiveSession?
    private var runtimeContext: RuntimeContext?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let sessionID = UUID()
        newConnection.setCodeSigningRequirement(
            EngineServiceTrustPolicy.clientRequirement()
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
        Task { @MainActor [weak self, payload] in
            guard let self else { return }
            let response = await self.handleCommandPayload(payload)
            let encodedResponse = (try? EngineServiceCodec.encode(response))
                ?? Self.encodedFailureFallback
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
        case .initialize(let appSupportDirectoryPath):
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
            let generationID = await activeGenerationCoordinator.register {
                generationTask.cancel()
            }
            defer {
                Task {
                    await self.activeGenerationCoordinator.finish(id: generationID)
                }
            }
            return .generationResult(try await generationTask.value)
        case .generateBatch(let commandID, let requests):
            guard !requests.isEmpty else {
                return .generationResults([])
            }
            let runtimeContext = try requireRuntimeContext()
            let generationTask = Task { @MainActor [weak self] in
                let batchRequests = requests.map { Self.batchRequest(from: $0) }
                let results = try await runtimeContext.engine.generateBatch(batchRequests) { fraction, message in
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
            let generationID = await activeGenerationCoordinator.register {
                generationTask.cancel()
            }
            defer {
                Task {
                    await self.activeGenerationCoordinator.finish(id: generationID)
                }
            }
            return .generationResults(try await generationTask.value)
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
        let runtime = try NativeRuntimeFactory.make(
            registry: registry,
            paths: .rooted(at: appSupportDirectory),
            storeVersionSeed: Self.storeVersionSeed()
        )
        let runtimeContext = RuntimeContext(
            appSupportDirectory: appSupportDirectory,
            engine: runtime.engine
        )

        // Snapshot publishing — `loadState`, `clonePreparationState`,
        // `visibleErrorMessage` changes need to flow over XPC so the
        // client's UI bindings stay live. This sink fires on every
        // `@Published` change including `latestEvent` — that's
        // harmless redundancy because `Self.snapshot(for:)` does NOT
        // include `latestEvent`, so we only re-publish the same
        // engine state on chunk events. The chunk-delivery transport
        // moved to the AsyncStream consumer below; only snapshots
        // travel here now.
        runtime.engine.objectWillChange
            .sink { [weak self, weak runtimeContext] _ in
                Task { @MainActor [weak self, weak runtimeContext] in
                    guard let self, let runtimeContext else { return }
                    self.publish(.snapshot(Self.snapshot(for: runtimeContext.engine)))
                }
            }
            .store(in: &runtimeContext.cancellables)

        // Audit Finding #1 — chunk delivery via the engine's
        // lossless AsyncStream. The producer (`MLXTTSEngine`'s
        // `eventSink` callback) yields every event into
        // `engine.events`; this Task drains the stream serially
        // and publishes each event over XPC in the exact order
        // they were yielded. No slot-sampling, no dedup,
        // no race window.
        let engine = runtime.engine
        runtimeContext.eventForwardingTask = Task { [weak self, weak runtimeContext] in
            for await event in engine.events {
                guard let self, let runtimeContext else { return }
                await MainActor.run {
                    self.publish(.generationChunk(event))
                    runtimeContext.lastPublishedEvent = event
                }
            }
        }

        // Cancel any prior context's forwarding task before we
        // replace the slot. Without this, the prior task races
        // the new one publishing into the same XPC channel.
        self.runtimeContext?.eventForwardingTask?.cancel()
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
        sessionLock.lock()
        let previousSessionID = activeSession?.id
        activeSession = ActiveSession(id: id, eventSink: eventSink)
        sessionLock.unlock()

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
            await contextAtSessionEnd?.engine.cancelClonePreparationIfNeeded()
            contextAtSessionEnd?.engine.clearGenerationActivity()
            try? await contextAtSessionEnd?.engine.unloadModel()
            // Only clear the host's runtime-context slot if the context that
            // ended is STILL the active one — otherwise a newer session has
            // already taken it over and we must not clobber its state.
            if self.runtimeContext === contextAtSessionEnd {
                self.runtimeContext = nil
            }
        }
    }

    @discardableResult
    private func clearActiveSessionIfNeeded(sessionID: UUID) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        guard activeSession?.id == sessionID else { return false }
        activeSession = nil
        return true
    }

    private func publish(_ event: EngineEventEnvelope, toSessionID: UUID? = nil) {
        let eventSink: QwenVoiceEngineClientEventXPCProtocol?
        sessionLock.lock()
        if let toSessionID {
            eventSink = activeSession?.id == toSessionID ? activeSession?.eventSink : nil
        } else {
            eventSink = activeSession?.eventSink
        }
        sessionLock.unlock()

        guard let eventSink else { return }
        guard let payload = try? EngineServiceCodec.encode(event) else {
            Self.logger.error("Failed to encode engine-service event payload.")
            return
        }
        eventSink.handleEvent(payload)
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

    private static func batchRequest(from request: GenerationRequest) -> GenerationRequest {
        guard !request.shouldStream else { return request }
        return GenerationRequest(
            mode: request.mode,
            modelID: request.modelID,
            text: request.text,
            outputPath: request.outputPath,
            shouldStream: true,
            streamingInterval: request.streamingInterval,
            batchIndex: request.batchIndex,
            batchTotal: request.batchTotal,
            streamingTitle: request.streamingTitle,
            benchmarkOptions: request.benchmarkOptions,
            payload: request.payload
        )
    }

    private static func normalizedBatchResult(from result: GenerationResult) -> GenerationResult {
        if let streamSessionDirectoryURL = result.streamSessionDirectoryURL {
            try? FileManager.default.removeItem(at: streamSessionDirectoryURL)
        }
        return GenerationResult(
            audioPath: result.audioPath,
            durationSeconds: result.durationSeconds,
            streamSessionDirectory: nil,
            benchmarkSample: normalizedBatchBenchmarkSample(from: result.benchmarkSample)
        )
    }

    private static func normalizedBatchBenchmarkSample(
        from benchmarkSample: BenchmarkSample?
    ) -> BenchmarkSample? {
        guard let benchmarkSample else { return nil }
        return BenchmarkSample(
            engineKind: benchmarkSample.engineKind,
            routingPolicy: benchmarkSample.routingPolicy,
            warmState: benchmarkSample.warmState,
            tokenCount: benchmarkSample.tokenCount,
            processingTimeSeconds: benchmarkSample.processingTimeSeconds,
            peakMemoryUsage: benchmarkSample.peakMemoryUsage,
            streamingUsed: false,
            preparedCloneUsed: benchmarkSample.preparedCloneUsed,
            cloneCacheHit: benchmarkSample.cloneCacheHit,
            firstChunkMs: nil,
            peakResidentMB: benchmarkSample.peakResidentMB,
            peakPhysFootprintMB: benchmarkSample.peakPhysFootprintMB,
            residentStartMB: benchmarkSample.residentStartMB,
            residentEndMB: benchmarkSample.residentEndMB,
            compressedPeakMB: benchmarkSample.compressedPeakMB,
            headroomStartMB: benchmarkSample.headroomStartMB,
            headroomEndMB: benchmarkSample.headroomEndMB,
            headroomMinMB: benchmarkSample.headroomMinMB,
            gpuAllocatedPeakMB: benchmarkSample.gpuAllocatedPeakMB,
            gpuRecommendedWorkingSetMB: benchmarkSample.gpuRecommendedWorkingSetMB,
            telemetryEnabled: benchmarkSample.telemetryEnabled,
            telemetrySamples: benchmarkSample.telemetrySamples,
            telemetryStageMarks: benchmarkSample.telemetryStageMarks,
            timingsMS: benchmarkSample.timingsMS,
            booleanFlags: benchmarkSample.booleanFlags,
            stringFlags: benchmarkSample.stringFlags,
            backendPerformance: benchmarkSample.backendPerformance
        )
    }
}
