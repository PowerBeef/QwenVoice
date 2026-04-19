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

@MainActor
private final class RuntimeContext: @unchecked Sendable {
    let appSupportDirectory: URL
    let engine: MLXTTSEngine
    var cancellables: Set<AnyCancellable> = []
    var lastPublishedEvent: GenerationEvent?

    init(appSupportDirectory: URL, engine: MLXTTSEngine) {
        self.appSupportDirectory = appSupportDirectory
        self.engine = engine
    }
}

final class VocelloEngineExtensionHost: NSObject, VocelloEngineExtensionXPCProtocol, @unchecked Sendable {
    private struct ActiveSession {
        let id: UUID
        let eventSink: VocelloEngineClientEventXPCProtocol
    }

    private static let logger = Logger(
        subsystem: "com.qvoice.ios.engine-extension",
        category: "VocelloEngineExtensionHost"
    )

    private let sessionLock = NSLock()
    private var activeSession: ActiveSession?
    private var runtimeContext: RuntimeContext?

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
        Task { @MainActor in
            let response = await handleCommandPayload(payload)
            let encodedResponse = (try? ExtensionEngineCodec.encode(response))
                ?? (try! ExtensionEngineCodec.encode(
                    ExtensionEngineReplyEnvelope(
                        id: UUID(),
                        reply: .failure(
                            ExtensionRemoteErrorPayload(
                                message: "The Vocello engine extension failed to encode its reply."
                            )
                        )
                    )
                ))
            replyHandler.reply(encodedResponse)
        }
    }

    @MainActor
    private func handleCommandPayload(_ payload: Data) async -> ExtensionEngineReplyEnvelope {
        do {
            let request = try ExtensionEngineCodec.decode(ExtensionEngineRequestEnvelope.self, from: payload)
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
        case .initialize(let appSupportDirectoryPath):
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
        case .prefetchInteractiveReadinessIfNeeded(let request):
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
            return .generationResult(try await requireRuntimeContext().engine.generate(request))
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
            .resolvedForPlatform(.iOS)
        let runtime = try NativeRuntimeFactory.make(
            registry: registry,
            paths: .rooted(at: appSupportDirectory),
            storeVersionSeed: Self.storeVersionSeed(),
            customPrewarmPolicy: .skipDedicatedCustomPrewarm,
            qwenPreparedLoadProfile: .streamingOnly
        )
        let runtimeContext = RuntimeContext(
            appSupportDirectory: appSupportDirectory,
            engine: runtime.engine
        )

        runtime.engine.objectWillChange
            .sink { [weak self, weak runtimeContext] _ in
                Task { @MainActor [weak self, weak runtimeContext] in
                    guard let self, let runtimeContext else { return }
                    let snapshot = Self.snapshot(for: runtimeContext.engine)
                    self.publish(.snapshot(snapshot))
                    if runtimeContext.lastPublishedEvent != runtimeContext.engine.latestEvent,
                       let latestEvent = runtimeContext.engine.latestEvent {
                        runtimeContext.lastPublishedEvent = latestEvent
                        self.publish(.generationChunk(latestEvent))
                    }
                }
            }
            .store(in: &runtimeContext.cancellables)

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
        guard clearActiveSessionIfNeeded(sessionID: sessionID) else {
            Self.logger.debug(
                "Ignoring disconnect from stale engine-extension session \(sessionID.uuidString, privacy: .public)."
            )
            return
        }

        Self.logger.error("\(message, privacy: .public)")
        Task { @MainActor in
            await self.runtimeContext?.engine.cancelClonePreparationIfNeeded()
            self.runtimeContext?.engine.clearGenerationActivity()
            try? await self.runtimeContext?.engine.unloadModel()
            self.runtimeContext = nil
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
        let session: ActiveSession?
        sessionLock.lock()
        if let sessionID {
            session = activeSession?.id == sessionID ? activeSession : nil
        } else {
            session = activeSession
        }
        sessionLock.unlock()

        guard let session else { return }
        guard let payload = try? ExtensionEngineCodec.encode(event) else {
            Self.logger.error("Failed to encode engine-extension event payload.")
            return
        }
        session.eventSink.handleEvent(payload)
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
        let bundleIdentifier = bundle.bundleIdentifier ?? "com.qvoice.ios.engine-extension"
        let marketingVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let buildVersion = bundle.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "0"
        return "\(bundleIdentifier)|\(marketingVersion)|\(buildVersion)"
    }
}
