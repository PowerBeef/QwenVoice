import Combine
import Foundation
import OSLog
import QwenVoiceCore

private final class ExtensionReplyHandlerBox: @unchecked Sendable {
    let reply: (Data) -> Void

    init(reply: @escaping (Data) -> Void) {
        self.reply = reply
    }
}

private actor ExtensionActiveGenerationCoordinator {
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
    /// AsyncStream and publishes events over the extension XPC channel
    /// in order while the consumer stays active. Mirrors the macOS
    /// `EngineServiceHost` fix landed
    /// in commit `c951d4c`. The producer side
    /// (`MLXTTSEngine.events`) is shared across both transports
    /// via `QwenVoiceCore`. Cancelled when the `RuntimeContext`
    /// is replaced (only when `appSupportDirectory` differs).
    var eventForwardingTask: Task<Void, Never>?

    init(appSupportDirectory: URL, engine: MLXTTSEngine) {
        self.appSupportDirectory = appSupportDirectory
        self.engine = engine
    }
}

/// Adapts the ExtensionKit / XPC wire protocol to the in-process `TTSEngine`.
/// One per extension: it accepts incoming connections from the app, forwards
/// generation/model requests to the engine, and streams events back over XPC —
/// the iOS analogue of the macOS `EngineServiceHost`.
final class VocelloEngineExtensionHost: NSObject, VocelloEngineExtensionXPCProtocol, @unchecked Sendable {
    private struct ActiveSession {
        let id: UUID
        let eventSink: VocelloEngineClientEventXPCProtocol
    }

    private static let logger = Logger(
        subsystem: "com.patricedery.vocello.engine-extension",
        category: "VocelloEngineExtensionHost"
    )

    /// Encodes a failure-shaped reply that preserves the original request id
    /// so the iPhone client matches the reply to its pending request and
    /// resolves the in-flight continuation. Mirrors the macOS host's
    /// `encodeFailureFallback(for:underlyingError:)` — see that helper for
    /// the full rationale.
    private static func encodeFailureFallback(for requestID: UUID, underlyingError: Error) -> Data {
        let fallback = ExtensionEngineReplyEnvelope(
            id: requestID,
            reply: .failure(
                ExtensionRemoteErrorPayload(
                    message: "The Vocello engine extension failed to encode its reply: \(underlyingError.localizedDescription)"
                )
            )
        )
        do {
            return try ExtensionEngineCodec.encode(fallback)
        } catch {
            VocelloEngineExtensionHost.logger.fault(
                "Failed to encode engine-extension failure fallback for id \(requestID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return Data()
        }
    }

    private let sessionLock = NSLock()
    private let activeGenerationCoordinator = ExtensionActiveGenerationCoordinator()
    private var activeSession: ActiveSession?
    private var runtimeContext: RuntimeContext?
    private var droppedEncodeEventCount = 0

    func accept(connection: NSXPCConnection) -> Bool {
        let sessionID = UUID()
        connection.exportedInterface = NSXPCInterface(with: VocelloEngineExtensionXPCProtocol.self)
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(with: VocelloEngineClientEventXPCProtocol.self)
        let eventSink = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.handleSessionEnded(
                sessionID: sessionID,
                message: "Engine-extension event sink remote error: \(error.localizedDescription)"
            )
        } as? VocelloEngineClientEventXPCProtocol
        guard let eventSink else {
            Self.logger.error("Failed to create event sink for Vocello engine-extension session.")
            return false
        }

        activateSession(id: sessionID, eventSink: eventSink)
        connection.invalidationHandler = { [weak self] in
            self?.handleSessionEnded(
                sessionID: sessionID,
                message: "Vocello engine-extension session invalidated."
            )
        }
        connection.interruptionHandler = { [weak self] in
            self?.handleSessionEnded(
                sessionID: sessionID,
                message: "Vocello engine-extension session interrupted."
            )
        }
        connection.resume()

        Task { @MainActor [weak self] in
            guard let self, let runtimeContext = self.runtimeContext else { return }
            self.publish(.snapshot(Self.snapshot(for: runtimeContext.engine)), toSessionID: sessionID)
        }

        return true
    }

    func perform(_ payload: Data, withReply reply: @escaping (Data) -> Void) {
        let replyHandler = ExtensionReplyHandlerBox(reply: reply)
        Task.detached(priority: .userInitiated) { [weak self, payload] in
            guard let self else { return }
            let response = await self.handleCommandPayload(payload)
            let encodedResponse: Data
            do {
                encodedResponse = try ExtensionEngineCodec.encode(response)
            } catch {
                Self.logger.error(
                    "Failed to encode engine-extension reply (id \(response.id.uuidString, privacy: .public)): \(error.localizedDescription, privacy: .public)"
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
    private func handleCommandPayload(_ payload: Data) async -> ExtensionEngineReplyEnvelope {
        do {
            let request = try ExtensionEngineCodec.decode(ExtensionEngineRequestEnvelope.self, from: payload)
#if DEBUG
            print("[VocelloEngineExtensionHost] command=\(Self.commandName(for: request.command))")
#endif
            do {
                return ExtensionEngineReplyEnvelope(
                    id: request.id,
                    reply: try await perform(request.command)
                )
            } catch {
                return ExtensionEngineReplyEnvelope(
                    id: request.id,
                    reply: .failure(ExtensionRemoteErrorPayload.make(for: error))
                )
            }
        } catch {
            Self.logger.error("Failed to decode engine-extension request envelope: \(error.localizedDescription, privacy: .public)")
            return ExtensionEngineReplyEnvelope(
                id: UUID(),
                reply: .failure(ExtensionRemoteErrorPayload.make(for: error))
            )
        }
    }

    @MainActor
    private func perform(_ command: ExtensionEngineCommand) async throws -> ExtensionEngineReply {
        switch command {
        case .initialize(let appSupportDirectoryPath, let telemetryMode, let forcedMemoryClass):
            // App-resolved telemetry MODE (env + persisted gesture flag) reaches this
            // separate extension process only via the handshake. One-way latch; carries
            // `verbose` so the raw-sample sidecar can fire here too.
            TelemetryGate.applyHandshakeMode(NativeTelemetryMode(rawValue: telemetryMode) ?? .off)
            // Benchmark tier override (env doesn't cross to this process either) —
            // forces the constrained-tier code paths so memory pressure is measurable.
            NativeDeviceClassGate.applyHandshakeForcedClass(forcedMemoryClass)
            let appSupportDirectory = URL(fileURLWithPath: appSupportDirectoryPath, isDirectory: true)
            let runtimeContext = try makeOrReuseRuntimeContext(appSupportDirectory: appSupportDirectory)
            try await runtimeContext.engine.initialize(appSupportDirectory: appSupportDirectory)
            return .snapshot(Self.snapshot(for: runtimeContext.engine))
        case .ping:
            _ = try await requireRuntimeContext().engine.ping()
            return .capabilities(.iOSExtensionDefault)
        case .loadModel(let id):
            try await requireRuntimeContext().engine.loadModel(id: id)
            return .void
        case .unloadModel:
            try await requireRuntimeContext().engine.unloadModel()
            return .void
        case .prepareAudio(let request):
            return .audioNormalizationResult(
                try await requireRuntimeContext().engine.prepareAudio(request)
            )
        case .ensureModelLoadedIfNeeded(let id):
            try await requireRuntimeContext().engine.ensureModelLoadedIfNeeded(id: id)
            return .void
        case .prewarmModelIfNeeded(let request):
            try await requireRuntimeContext().engine.prewarmModelIfNeeded(for: request)
            return .void
        case .prefetchInteractiveReadinessIfNeeded(let request, _):
            return .interactivePrefetchDiagnostics(
                try await requireRuntimeContext().engine.prefetchInteractiveReadinessIfNeeded(for: request)
                    ?? InteractivePrefetchDiagnostics(
                        timingsMS: [:],
                        booleanFlags: [:],
                        requestKey: nil
                    )
            )
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
        case .captureMemorySnapshot(let role):
            return .memorySnapshot(IOSMemorySnapshot.capture(role: role))
        case .trimMemory(let level, let reason):
            try await requireRuntimeContext().engine.trimMemory(level: level, reason: reason)
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
            .resolvedForPlatform(.iOS, deviceClass: .iPhonePro)
        let runtime = try NativeRuntimeFactory.make(
            registry: registry,
            paths: .rooted(at: appSupportDirectory),
            storeVersionSeed: Self.storeVersionSeed(),
            customPrewarmPolicy: .skipDedicatedCustomPrewarm,
            qwenPreparedLoadProfile: .iOSProductionDefault
        )
        let runtimeContext = RuntimeContext(
            appSupportDirectory: appSupportDirectory,
            engine: runtime.engine
        )

        // Snapshot publishing — `loadState`,
        // `clonePreparationState`, `visibleErrorMessage` changes
        // need to flow over the extension XPC channel so the
        // iPhone client's UI bindings stay live. Chunk delivery is
        // handled by the AsyncStream below; this sink suppresses
        // unchanged snapshots produced by chunk-only `latestEvent`
        // updates.
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

        // Chunk-capable diagnostic delivery via the engine's ordered
        // AsyncStream. Mirrors the macOS `EngineServiceHost` transport:
        // the previous `objectWillChange.sink` slot-sampler could drop
        // a trailing diagnostic `.chunk` when `NativeStreamingSynthesisSession.run`
        // emitted `.completed` back-to-back — the dedup guard
        // `lastPublishedEvent != engine.latestEvent` saw the slot
        // already overwritten by `.completed` and suppressed the
        // chunk read. The AsyncStream consumer drains the stream
        // serially while active. Preview-audio chunks are never
        // dropped here. No slot-sampling, no dedup, no race window.
        let eventStream = runtime.engine.events
        runtimeContext.eventForwardingTask = Task.detached(priority: .utility) { [weak self, weak runtimeContext, appSupportDirectory, eventStream] in
            var expectedChunkSequence: UInt64 = 0
            var gapDetectionGenerationID: UUID?
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
                    }
                    expectedChunkSequence = max(expectedChunkSequence, sequence)
                }
                let stripped = event.withoutPreviewAudioPayload()
                self.publish(.generationChunk(event))
                await MainActor.run {
                    runtimeContext.lastPublishedEvent = stripped
                }
            }
        }

        // Cancel any prior context's forwarding task before we
        // replace the slot, otherwise the prior task races the
        // new one publishing into the same XPC channel.
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

    private func activateSession(id: UUID, eventSink: VocelloEngineClientEventXPCProtocol) {
        sessionLock.lock()
        let previousSessionID = activeSession?.id
        activeSession = ActiveSession(id: id, eventSink: eventSink)
        sessionLock.unlock()

        if let previousSessionID, previousSessionID != id {
            Self.logger.notice(
                "Replacing active engine-extension session \(previousSessionID.uuidString, privacy: .public) with \(id.uuidString, privacy: .public)."
            )
        } else {
            Self.logger.debug("Activated engine-extension session \(id.uuidString, privacy: .public).")
        }
    }

    private func handleSessionEnded(sessionID: UUID, message: String) {
#if DEBUG
        print("[VocelloEngineExtensionHost] session ended: \(message)")
#endif
        guard clearActiveSessionIfNeeded(sessionID: sessionID) else {
            Self.logger.debug(
                "Ignoring disconnect from stale engine-extension session \(sessionID.uuidString, privacy: .public)."
            )
            return
        }

        Self.logger.error("\(message, privacy: .public)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let contextAtSessionEnd = self.runtimeContext
            await self.activeGenerationCoordinator.cancelCurrent()
            await contextAtSessionEnd?.engine.cancelClonePreparationIfNeeded()
            contextAtSessionEnd?.engine.clearGenerationActivity()
            try? await contextAtSessionEnd?.engine.unloadModel()
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

    private func publish(_ event: ExtensionEngineEventEnvelope, toSessionID sessionID: UUID? = nil) {
#if DEBUG
        let eventSinkEnabled = ProcessInfo.processInfo.environment["QVOICE_IOS_EXTENSION_ENABLE_EVENT_SINK"] == "1"
#else
        let eventSinkEnabled = false
#endif
        guard eventSinkEnabled else { return }

        let session: ActiveSession?
        sessionLock.lock()
        if let sessionID {
            session = activeSession?.id == sessionID ? activeSession : nil
        } else {
            session = activeSession
        }
        sessionLock.unlock()

        guard let session else { return }
        do {
            let payload = try ExtensionEngineCodec.encode(event)
            session.eventSink.handleEvent(payload)
        } catch {
            sessionLock.lock()
            droppedEncodeEventCount += 1
            let droppedCount = droppedEncodeEventCount
            let diagnosticsDirectory = runtimeContext?.appSupportDirectory
            sessionLock.unlock()

            Self.logger.error(
                "Failed to encode engine-extension event payload (droppedCount=\(droppedCount, privacy: .public)): \(error.localizedDescription, privacy: .public)"
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
            .appendingPathComponent("engine-extension", isDirectory: true)
        let url = diagnosticsDirectory.appendingPathComponent("native-events.jsonl", isDirectory: false)
        let record: [String: String] = [
            "event": "engine_extension_chunk_gap",
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
            logger.error("Failed to record chunk gap event: \(error.localizedDescription, privacy: .public)")
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
            .appendingPathComponent("engine-extension", isDirectory: true)
        let url = diagnosticsDirectory.appendingPathComponent("native-events.jsonl", isDirectory: false)
        let record: [String: String] = [
            "event": "engine_extension_encode_dropped",
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
        let bundleIdentifier = bundle.bundleIdentifier ?? "com.patricedery.vocello.engine-extension"
        let marketingVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let buildVersion = bundle.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "0"
        return "\(bundleIdentifier)|\(marketingVersion)|\(buildVersion)"
    }

    private static func commandName(for command: ExtensionEngineCommand) -> String {
        switch command {
        case .initialize:
            "initialize"
        case .ping:
            "ping"
        case .loadModel:
            "loadModel"
        case .unloadModel:
            "unloadModel"
        case .prepareAudio:
            "prepareAudio"
        case .ensureModelLoadedIfNeeded:
            "ensureModelLoadedIfNeeded"
        case .prewarmModelIfNeeded:
            "prewarmModelIfNeeded"
        case .prefetchInteractiveReadinessIfNeeded:
            "prefetchInteractiveReadinessIfNeeded"
        case .ensureCloneReferencePrimed:
            "ensureCloneReferencePrimed"
        case .cancelClonePreparationIfNeeded:
            "cancelClonePreparationIfNeeded"
        case .generate:
            "generate"
        case .cancelActiveGeneration:
            "cancelActiveGeneration"
        case .listPreparedVoices:
            "listPreparedVoices"
        case .enrollPreparedVoice:
            "enrollPreparedVoice"
        case .deletePreparedVoice:
            "deletePreparedVoice"
        case .clearGenerationActivity:
            "clearGenerationActivity"
        case .clearVisibleError:
            "clearVisibleError"
        case .captureMemorySnapshot:
            "captureMemorySnapshot"
        case .trimMemory:
            "trimMemory"
        }
    }
}
