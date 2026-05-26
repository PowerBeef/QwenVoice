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

    private let sessionLock = NSLock()
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
        Task { @MainActor [weak self, payload] in
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
        // match the iOS extension's policy (which has done this since
        // launch — see VocelloEngineExtensionHost. The prewarm cost
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

        // Chunk delivery via the engine's ordered AsyncStream. The
        // producer (`MLXTTSEngine`'s
        // `eventSink` callback) yields every event into
        // `engine.events`; this Task drains the stream serially while
        // active. Preview-audio chunks are never dropped here. No
        // slot-sampling, no dedup, no race window.
        let engine = runtime.engine
        runtimeContext.eventForwardingTask = Task { [weak self, weak runtimeContext] in
            for await event in engine.events {
                guard let self, let runtimeContext else { return }
                await MainActor.run {
                    self.publish(.generationChunk(event))
                    runtimeContext.lastPublishedEvent = event.withoutPreviewAudioPayload()
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
        do {
            let payload = try EngineServiceCodec.encode(event)
            eventSink.handleEvent(payload)
        } catch {
            sessionLock.lock()
            droppedEncodeEventCount += 1
            let droppedCount = droppedEncodeEventCount
            let diagnosticsDirectory = runtimeContext?.appSupportDirectory
            sessionLock.unlock()

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
        do {
            try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                if let encoded = line.data(using: .utf8) {
                    try handle.write(contentsOf: encoded)
                }
                try handle.close()
            } else {
                try line.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            logger.error("Failed to record dropped encode event: \(error.localizedDescription, privacy: .public)")
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
