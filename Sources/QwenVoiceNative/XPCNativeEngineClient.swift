@preconcurrency import Combine
import QwenVoiceCore
import Foundation
import OSLog

enum EngineTransportError: LocalizedError, Equatable, Sendable {
    case interrupted
    case invalidated
    case timedOut(commandName: String)
    case staleOrMismatchedReply(id: UUID)
    case invalidReply

    var errorDescription: String? {
        switch self {
        case .interrupted:
            return "The engine service connection was interrupted."
        case .invalidated:
            return "The engine service connection was invalidated."
        case .timedOut(let commandName):
            return "The engine service request timed out while running \(commandName)."
        case .staleOrMismatchedReply(let id):
            return "The engine service returned a stale or mismatched reply for request \(id.uuidString)."
        case .invalidReply:
            return "The engine service returned an invalid reply."
        }
    }
}

struct XPCNativeEngineTransportHandlers: Sendable {
    let onEventData: @Sendable (Data) -> Void
    let onRemoteError: @Sendable (Error) -> Void
    let onInterrupted: @Sendable () -> Void
    let onInvalidated: @Sendable () -> Void
}

protocol XPCNativeEngineTransporting: AnyObject, Sendable {
    func resume()
    func invalidate()
    func perform(_ payload: Data, reply: @escaping @Sendable (Data) -> Void)
}

typealias XPCNativeEngineTransportFactory = @Sendable (XPCNativeEngineTransportHandlers) -> any XPCNativeEngineTransporting
typealias XPCNativeEngineTimeoutResolver = @Sendable (EngineCommand) -> Duration?

private final class BatchProgressHandlerBox: @unchecked Sendable {
    let handler: @Sendable (Double?, String) -> Void

    init(handler: @escaping @Sendable (Double?, String) -> Void) {
        self.handler = handler
    }
}

private final class PendingRequestBox: @unchecked Sendable {
    let commandName: String
    let resume: @Sendable (Result<EngineReply, Error>) -> Void
    var timeoutTask: Task<Void, Never>?

    init(
        commandName: String,
        resume: @escaping @Sendable (Result<EngineReply, Error>) -> Void
    ) {
        self.commandName = commandName
        self.resume = resume
    }
}

private final class XPCNativeEngineClientEventSink: NSObject, QwenVoiceEngineClientEventXPCProtocol {
    private let onEvent: @Sendable (Data) -> Void

    init(onEvent: @escaping @Sendable (Data) -> Void) {
        self.onEvent = onEvent
    }

    func handleEvent(_ payload: Data) {
        onEvent(payload)
    }
}

private final class XPCServiceTransport: NSObject, XPCNativeEngineTransporting, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let eventSink: XPCNativeEngineClientEventSink
    private let handlers: XPCNativeEngineTransportHandlers

    init(handlers: XPCNativeEngineTransportHandlers) {
        self.handlers = handlers

        let sink = XPCNativeEngineClientEventSink(onEvent: handlers.onEventData)
        self.eventSink = sink
        let connection = NSXPCConnection(serviceName: QwenVoiceEngineServiceBundleIdentifier)
        connection.setCodeSigningRequirement(
            EngineServiceTrustPolicy.serviceRequirementForCurrentBundle()
        )
        connection.remoteObjectInterface = NSXPCInterface(with: QwenVoiceEngineServiceXPCProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: QwenVoiceEngineClientEventXPCProtocol.self)
        connection.exportedObject = sink
        self.connection = connection

        super.init()

        connection.interruptionHandler = { [handlers] in
            handlers.onInterrupted()
        }
        connection.invalidationHandler = { [handlers] in
            handlers.onInvalidated()
        }
    }

    func resume() {
        connection.resume()
    }

    func invalidate() {
        connection.invalidate()
    }

    func perform(_ payload: Data, reply: @escaping @Sendable (Data) -> Void) {
        let rawProxy = connection.remoteObjectProxyWithErrorHandler { [handlers] error in
            handlers.onRemoteError(error)
        }
        guard let proxy = rawProxy as? QwenVoiceEngineServiceXPCProtocol else {
            let mismatch = NSError(
                domain: "com.qwenvoice.xpc",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Remote XPC proxy does not conform to QwenVoiceEngineServiceXPCProtocol",
                ]
            )
            handlers.onRemoteError(mismatch)
            reply(Data())
            return
        }
        proxy.perform(payload, withReply: reply)
    }
}

actor XPCNativeEngineCoordinator {
    private struct ActiveConnection {
        let id: UUID
        let transport: any XPCNativeEngineTransporting
    }

    private static let logger = Logger(
        subsystem: "com.qwenvoice.app",
        category: "XPCNativeEngineClient"
    )
    private static let signposter = OSSignposter(
        subsystem: "com.qwenvoice.app",
        category: "xpc"
    )

    private let onSnapshot: @Sendable (TTSEngineSnapshot) -> Void
    private let onChunk: @Sendable (GenerationEvent) -> Void
    private let transportFactory: XPCNativeEngineTransportFactory
    private let timeoutResolver: XPCNativeEngineTimeoutResolver

    private var activeConnection: ActiveConnection?
    private var didInitializeCurrentConnection = false
    private var initializedAppSupportDirectory: URL?
    private var batchProgressHandlers: [UUID: BatchProgressHandlerBox] = [:]
    private var pendingRequests: [UUID: PendingRequestBox] = [:]
    private var inFlightBestEffortKeys: Set<String> = []
    private let reconnectDelays: [Duration]
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?

    init(
        onSnapshot: @escaping @Sendable (TTSEngineSnapshot) -> Void,
        onChunk: @escaping @Sendable (GenerationEvent) -> Void,
        transportFactory: @escaping XPCNativeEngineTransportFactory = { handlers in
            XPCServiceTransport(handlers: handlers)
        },
        timeoutResolver: @escaping XPCNativeEngineTimeoutResolver = { command in
            command.transportTimeout
        },
        reconnectDelays: [Duration] = [.milliseconds(250), .seconds(1)]
    ) {
        self.onSnapshot = onSnapshot
        self.onChunk = onChunk
        self.transportFactory = transportFactory
        self.timeoutResolver = timeoutResolver
        self.reconnectDelays = reconnectDelays
    }

    func initialize(appSupportDirectory: URL) async throws {
        initializedAppSupportDirectory = appSupportDirectory
        _ = try await send(.initialize(appSupportDirectoryPath: appSupportDirectory.path))
    }

    func send(_ command: EngineCommand) async throws -> EngineReply {
        cancelReconnectTaskIfNeeded()
        return try await send(command, cancelsReconnectTask: false)
    }

    private func send(_ command: EngineCommand, cancelsReconnectTask: Bool) async throws -> EngineReply {
        if cancelsReconnectTask {
            cancelReconnectTaskIfNeeded()
        }
        let transport = ensureConnection()
        switch command {
        case .initialize(let path):
            initializedAppSupportDirectory = URL(fileURLWithPath: path)
            let reply = try await perform(transport: transport, command: command)
            applyReplySideEffects(reply)
            didInitializeCurrentConnection = true
            return reply
        default:
            if !didInitializeCurrentConnection, let initializedAppSupportDirectory {
                let initializationReply = try await perform(
                    transport: transport,
                    command: .initialize(appSupportDirectoryPath: initializedAppSupportDirectory.path)
                )
                applyReplySideEffects(initializationReply)
                didInitializeCurrentConnection = true
            }
            let reply = try await perform(transport: transport, command: command)
            applyReplySideEffects(reply)
            return reply
        }
    }

    func registerBatchProgressHandler(
        id: UUID,
        handler: (@Sendable (Double?, String) -> Void)?
    ) {
        if let handler {
            batchProgressHandlers[id] = BatchProgressHandlerBox(handler: handler)
        } else {
            batchProgressHandlers.removeValue(forKey: id)
        }
    }

    func clearBatchProgressHandler(id: UUID) {
        batchProgressHandlers.removeValue(forKey: id)
    }

    func fireAndForget(_ command: EngineCommand) {
        let deduplicationKey = bestEffortDeduplicationKey(for: command)
        if let deduplicationKey {
            guard inFlightBestEffortKeys.insert(deduplicationKey).inserted else {
                Self.logger.debug(
                    "Skipping duplicate best-effort command '\(command.transportName, privacy: .public)' with key \(deduplicationKey, privacy: .public)."
                )
                return
            }
        }

        Task { [command, deduplicationKey] in
            await performBestEffort(command, deduplicationKey: deduplicationKey)
        }
    }

    private func performBestEffort(
        _ command: EngineCommand,
        deduplicationKey: String?
    ) async {
        defer {
            if let deduplicationKey {
                inFlightBestEffortKeys.remove(deduplicationKey)
            }
        }
        do {
            _ = try await send(command)
        } catch {
            Self.logger.error(
                "Best-effort command '\(command.transportName, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func handleEventData(_ data: Data, from connectionID: UUID) {
        guard isCurrentConnection(connectionID) else {
            Self.logger.debug(
                "Ignoring engine event from stale connection \(connectionID.uuidString, privacy: .public)."
            )
            return
        }

        do {
            let event = try EngineServiceCodec.decode(EngineEventEnvelope.self, from: data)
            switch event {
            case .snapshot(let snapshot):
                onSnapshot(snapshot)
            case .generationChunk(let generationEvent):
                emitChunkProbeEvents(for: generationEvent)
                onChunk(generationEvent)
            case .batchProgress(let update):
                guard let handler = batchProgressHandlers[update.commandID] else { return }
                Task { @MainActor in
                    handler.handler(update.fraction, update.message)
                }
            }
        } catch {
            Self.logger.error("Unreadable engine event payload: \(error.localizedDescription, privacy: .public)")
            handleDisconnect(
                connectionID: connectionID,
                transportError: .invalidReply,
                message: "The engine service sent an unreadable event: \(error.localizedDescription)"
            )
        }
    }

    /// Cross-layer chunk probes: emit `[Probe.Engine] event=chunk_emitted`
    /// using the embedded engine timestamp + `[Probe.Transport] event=chunk_delivered`
    /// using the wall-clock at receive time. The bench helper joins these
    /// with `[Probe.UI] event=chunk_consumed` (emitted by AudioPlayerViewModel)
    /// on `seq` to produce per-chunk cross-layer latency aggregates.
    private func emitChunkProbeEvents(for generationEvent: GenerationEvent) {
        guard let probe = generationEvent.probeMetadata else { return }
        let transportAtMS = Date().timeIntervalSince1970 * 1000.0
        let audioSeconds = generationEvent.chunkDurationSeconds ?? 0
        var engineDetails: [(String, String)] = [
            ("seq", "\(probe.seq)"),
            ("audio_s", String(format: "%.3f", audioSeconds)),
            ("infer_ms", String(format: "%.3f", probe.inferMS)),
            ("engine_at_ms", String(format: "%.3f", probe.engineEmittedAtMS)),
        ]
        // Engine probe Phase 1: per-chunk sub-stage breakdown when
        // available. Fields elide cleanly for legacy chunks / non-Qwen3
        // backends (probe metadata exists but sub-stages are nil).
        if let talker = probe.talkerForwardMS {
            engineDetails.append(("talker_forward_ms", String(format: "%.3f", talker)))
        }
        if let codePredictor = probe.codePredictorMS {
            engineDetails.append(("code_predictor_ms", String(format: "%.3f", codePredictor)))
        }
        if let audioDecoder = probe.audioDecoderMS {
            engineDetails.append(("audio_decoder_ms", String(format: "%.3f", audioDecoder)))
        }
        // Engine probe Phase 2a: eval cadence + EOS read + audio
        // chunk eval — the work between the Phase 1 stages.
        if let streamStepEval = probe.streamStepEvalMS {
            engineDetails.append(("stream_step_eval_ms", String(format: "%.3f", streamStepEval)))
        }
        if let streamStepEOSRead = probe.streamStepEOSReadMS {
            engineDetails.append(("stream_step_eos_read_ms", String(format: "%.3f", streamStepEOSRead)))
        }
        if let audioChunkEval = probe.audioChunkEvalMS {
            engineDetails.append(("audio_chunk_eval_ms", String(format: "%.3f", audioChunkEval)))
        }
        logProbeEvent("Engine", event: "chunk_emitted", orderedDetails: engineDetails)
        logProbeEvent("Transport", event: "chunk_delivered", details: [
            "seq": "\(probe.seq)",
            "transport_at_ms": String(format: "%.3f", transportAtMS),
            "xpc_latency_ms": String(format: "%.3f", transportAtMS - probe.engineEmittedAtMS),
        ])
    }

    func handleRemoteError(_ error: Error, from connectionID: UUID) {
        handleDisconnect(
            connectionID: connectionID,
            transportError: .invalidated,
            message: error.localizedDescription
        )
    }

    func handleConnectionInterrupted(for connectionID: UUID) {
        handleDisconnect(
            connectionID: connectionID,
            transportError: .interrupted,
            message: EngineTransportError.interrupted.localizedDescription
        )
    }

    func handleConnectionInvalidated(for connectionID: UUID) {
        handleDisconnect(
            connectionID: connectionID,
            transportError: .invalidated,
            message: EngineTransportError.invalidated.localizedDescription
        )
    }

#if QW_TEST_SUPPORT
    func invalidateForTesting(shouldReconnect: Bool = false) {
        guard let connectionID = activeConnection?.id else { return }
        handleDisconnect(
            connectionID: connectionID,
            transportError: .invalidated,
            message: EngineTransportError.invalidated.localizedDescription,
            allowsRecovery: shouldReconnect
        )
    }
#endif

    private func ensureConnection() -> ActiveConnection {
        if let activeConnection {
            return activeConnection
        }

        let connectionID = UUID()
        let handlers = XPCNativeEngineTransportHandlers(
            onEventData: { [weak self] payload in
                Task {
                    await self?.handleEventData(payload, from: connectionID)
                }
            },
            onRemoteError: { [weak self] error in
                Task {
                    await self?.handleRemoteError(error, from: connectionID)
                }
            },
            onInterrupted: { [weak self] in
                Task {
                    await self?.handleConnectionInterrupted(for: connectionID)
                }
            },
            onInvalidated: { [weak self] in
                Task {
                    await self?.handleConnectionInvalidated(for: connectionID)
                }
            }
        )

        let transport = transportFactory(handlers)
        transport.resume()
        let connection = ActiveConnection(id: connectionID, transport: transport)
        activeConnection = connection
        didInitializeCurrentConnection = false
        return connection
    }

    private func perform(
        transport: ActiveConnection,
        command: EngineCommand
    ) async throws -> EngineReply {
        let signpostState = Self.signposter.beginInterval("XPC Engine Command")
        defer {
            Self.signposter.endInterval("XPC Engine Command", signpostState)
        }
        let requestEnvelope = EngineRequestEnvelope(id: UUID(), command: command)
        let payload = try EngineServiceCodec.encode(requestEnvelope)

        Self.signposter.emitEvent("XPC Engine Command Sent")
        Self.logger.debug("Sending engine command '\(command.transportName, privacy: .public)' with id \(requestEnvelope.id.uuidString, privacy: .public)")

        return try await withCheckedThrowingContinuation { continuation in
            let pendingRequest = PendingRequestBox(
                commandName: command.transportName,
                resume: { result in
                    continuation.resume(with: result)
                }
            )
            if let timeout = timeoutResolver(command) {
                pendingRequest.timeoutTask = Task { [requestID = requestEnvelope.id] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self.handleTimeout(for: requestID)
                }
            }
            pendingRequests[requestEnvelope.id] = pendingRequest

            transport.transport.perform(payload) { [weak self] replyData in
                Task {
                    Self.signposter.emitEvent("XPC Engine Reply Received")
                    await self?.handleReplyData(replyData, from: transport.id)
                }
            }
        }
    }

    private func handleReplyData(_ data: Data, from connectionID: UUID) {
        guard isCurrentConnection(connectionID) else {
            Self.logger.debug(
                "Ignoring engine reply from stale connection \(connectionID.uuidString, privacy: .public)."
            )
            return
        }

        let envelope: EngineReplyEnvelope
        do {
            envelope = try EngineServiceCodec.decode(EngineReplyEnvelope.self, from: data)
        } catch {
            Self.logger.error("Unreadable engine reply payload: \(error.localizedDescription, privacy: .public)")
            handleDisconnect(
                connectionID: connectionID,
                transportError: .invalidReply,
                message: EngineTransportError.invalidReply.localizedDescription
            )
            return
        }

        guard let pendingRequest = pendingRequests.removeValue(forKey: envelope.id) else {
            let transportError = EngineTransportError.staleOrMismatchedReply(id: envelope.id)
            Self.logger.warning("\(transportError.localizedDescription, privacy: .public)")
            return
        }

        pendingRequest.timeoutTask?.cancel()

        if case .failure(let error) = envelope.reply {
            pendingRequest.resume(.failure(error))
        } else {
            pendingRequest.resume(.success(envelope.reply))
        }
    }

    private func handleTimeout(for requestID: UUID) {
        guard let pendingRequest = pendingRequests.removeValue(forKey: requestID) else { return }
        pendingRequest.timeoutTask?.cancel()
        let error = EngineTransportError.timedOut(commandName: pendingRequest.commandName)
        Self.logger.error("\(error.localizedDescription, privacy: .public)")
        pendingRequest.resume(.failure(error))
    }

    private func handleDisconnect(
        connectionID: UUID,
        transportError: EngineTransportError,
        message: String?,
        allowsRecovery: Bool = true
    ) {
        guard let connectionToInvalidate = disconnectCurrentConnectionIfNeeded(connectionID: connectionID) else {
            Self.logger.debug(
                "Ignoring disconnect cleanup from stale connection \(connectionID.uuidString, privacy: .public)."
            )
            return
        }
        connectionToInvalidate.invalidate()
        didInitializeCurrentConnection = false
        batchProgressHandlers.removeAll()
        inFlightBestEffortKeys.removeAll()

        let pendingRequestBoxes = pendingRequests.values
        pendingRequests.removeAll()
        let pendingCommandNames = pendingRequestBoxes.map(\.commandName).joined(separator: ",")
        let visibleMessage = message ?? transportError.localizedDescription
        let canRecover = allowsRecovery
            && isRecoverableDisconnect(transportError)
            && initializedAppSupportDirectory != nil
            && !reconnectDelays.isEmpty

        Self.logger.error(
            "Disconnect cleanup: \(visibleMessage, privacy: .public); pending=\(pendingRequestBoxes.count, privacy: .public); commands=\(pendingCommandNames, privacy: .public); recoveryScheduled=\(canRecover, privacy: .public)."
        )

        for pendingRequest in pendingRequestBoxes {
            pendingRequest.timeoutTask?.cancel()
            pendingRequest.resume(.failure(transportError))
        }

        if canRecover {
            publishRecoveringSnapshot()
            scheduleReconnect()
        } else {
            publishUnavailableSnapshot(message: visibleMessage)
        }
    }

    private func isCurrentConnection(_ connectionID: UUID) -> Bool {
        activeConnection?.id == connectionID
    }

    private func disconnectCurrentConnectionIfNeeded(connectionID: UUID) -> (any XPCNativeEngineTransporting)? {
        guard activeConnection?.id == connectionID else { return nil }
        let transport = activeConnection?.transport
        activeConnection = nil
        return transport
    }

    private func applyReplySideEffects(_ reply: EngineReply) {
        guard case .snapshot(let snapshot) = reply else { return }
        onSnapshot(snapshot)
    }

    private func isRecoverableDisconnect(_ error: EngineTransportError) -> Bool {
        switch error {
        case .interrupted, .invalidated:
            true
        case .timedOut, .staleOrMismatchedReply, .invalidReply:
            false
        }
    }

    private func publishRecoveringSnapshot() {
        onSnapshot(
            TTSEngineSnapshot(
                isReady: false,
                loadState: .starting,
                clonePreparationState: .idle,
                visibleErrorMessage: "Reconnecting engine…"
            )
        )
    }

    private func publishUnavailableSnapshot(message: String) {
        onSnapshot(
            TTSEngineSnapshot(
                isReady: false,
                loadState: .failed(message: message),
                clonePreparationState: .idle,
                visibleErrorMessage: message
            )
        )
    }

    private func cancelReconnectTaskIfNeeded() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectAttempt += 1

        let attempt = reconnectAttempt
        guard attempt <= reconnectDelays.count,
              let initializedAppSupportDirectory else {
            reconnectTask = nil
            publishUnavailableSnapshot(
                message: "Engine unavailable. Try generating again to reconnect the engine."
            )
            return
        }

        let delay = reconnectDelays[attempt - 1]
        reconnectTask = Task { [attempt, initializedAppSupportDirectory] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self.performReconnectAttempt(
                attempt: attempt,
                appSupportDirectory: initializedAppSupportDirectory
            )
        }
    }

    private func performReconnectAttempt(attempt: Int, appSupportDirectory: URL) async {
        guard reconnectAttempt == attempt else { return }

        do {
            _ = try await send(
                .initialize(appSupportDirectoryPath: appSupportDirectory.path),
                cancelsReconnectTask: false
            )
            _ = try await send(.ping, cancelsReconnectTask: false)
            reconnectTask = nil
            reconnectAttempt = 0
            Self.logger.notice(
                "Engine service reconnect attempt \(attempt, privacy: .public) completed."
            )
        } catch {
            guard reconnectAttempt == attempt else { return }
            Self.logger.error(
                "Engine service reconnect attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)."
            )
            scheduleReconnect()
        }
    }

    private func bestEffortDeduplicationKey(for command: EngineCommand) -> String? {
        switch command {
        case .ensureModelLoadedIfNeeded(let id):
            "ensureModelLoadedIfNeeded|\(id)"
        case .prewarmModelIfNeeded(let request):
            "prewarmModelIfNeeded|\(GenerationSemantics.prewarmIdentityKey(for: request))"
        case .prefetchInteractiveReadinessIfNeeded(let request, let customPrewarmDepth):
            "prefetchInteractiveReadinessIfNeeded|\(GenerationSemantics.prewarmIdentityKey(for: request))|depth=\(customPrewarmDepth ?? "default")"
        default:
            nil
        }
    }
}

public final class XPCNativeEngineClient: MacTTSEngine, @unchecked Sendable {
    private let snapshotSubject: CurrentValueSubject<TTSEngineSnapshot, Never>
    private let coordinator: XPCNativeEngineCoordinator

    public convenience init() {
        self.init(onChunk: { event in
            GenerationChunkBroker.publish(event)
        })
    }

    convenience init(onChunk: @escaping @Sendable (GenerationEvent) -> Void) {
        self.init(
            transportFactory: { handlers in
                XPCServiceTransport(handlers: handlers)
            },
            timeoutResolver: { command in
                command.transportTimeout
            },
            onChunk: onChunk
        )
    }

    init(
        transportFactory: @escaping XPCNativeEngineTransportFactory,
        timeoutResolver: @escaping XPCNativeEngineTimeoutResolver = { command in
            command.transportTimeout
        },
        onChunk: @escaping @Sendable (GenerationEvent) -> Void = { event in
            GenerationChunkBroker.publish(event)
        },
        reconnectDelays: [Duration] = [.milliseconds(250), .seconds(1)]
    ) {
        let initialSnapshot = TTSEngineSnapshot(
            isReady: false,
            loadState: .idle,
            clonePreparationState: .idle,
            visibleErrorMessage: nil
        )
        self.snapshotSubject = CurrentValueSubject(initialSnapshot)
        self.coordinator = XPCNativeEngineCoordinator(
            onSnapshot: { [snapshotSubject] snapshot in
                snapshotSubject.send(snapshot)
            },
            onChunk: onChunk,
            transportFactory: transportFactory,
            timeoutResolver: timeoutResolver,
            reconnectDelays: reconnectDelays
        )
    }

    public var snapshot: TTSEngineSnapshot {
        snapshotSubject.value
    }

    public var snapshotPublisher: AnyPublisher<TTSEngineSnapshot, Never> {
        snapshotSubject.eraseToAnyPublisher()
    }

    public func initialize(appSupportDirectory: URL) async throws {
        try await coordinator.initialize(appSupportDirectory: appSupportDirectory)
    }

    public func ping() async throws -> Bool {
        let reply = try await coordinator.send(.ping)
        switch reply {
        case .bool(let value):
            return value
        case .capabilities:
            return true
        default:
            throw EngineTransportError.invalidReply
        }
    }

    public func loadModel(id: String) async throws {
        _ = try await coordinator.send(.loadModel(id: id))
    }

    public func unloadModel() async throws {
        _ = try await coordinator.send(.unloadModel)
    }

    public func ensureModelLoadedIfNeeded(id: String) async {
        await coordinator.fireAndForget(.ensureModelLoadedIfNeeded(id: id))
    }

    public func prewarmModelIfNeeded(for request: GenerationRequest) async {
        await coordinator.fireAndForget(.prewarmModelIfNeeded(request: request))
    }

    public func prefetchInteractiveReadinessIfNeeded(
        for request: GenerationRequest
    ) async -> InteractivePrefetchDiagnostics? {
        await prefetchInteractiveReadinessIfNeeded(for: request, customPrewarmDepth: nil)
    }

    public func prefetchInteractiveReadinessIfNeeded(
        for request: GenerationRequest,
        customPrewarmDepth: String?
    ) async -> InteractivePrefetchDiagnostics? {
        do {
            let reply = try await coordinator.send(
                .prefetchInteractiveReadinessIfNeeded(
                    request: request,
                    customPrewarmDepth: customPrewarmDepth
                )
            )
            guard case .interactivePrefetchDiagnostics(let diagnostics) = reply else {
                throw EngineTransportError.invalidReply
            }
            return diagnostics
        } catch {
            return nil
        }
    }

    public func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {
        _ = try await coordinator.send(.ensureCloneReferencePrimed(modelID: modelID, reference: reference))
    }

    public func cancelClonePreparationIfNeeded() async {
        await coordinator.fireAndForget(.cancelClonePreparationIfNeeded)
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        do {
            let reply = try await coordinator.send(.generate(request: request))
            guard case .generationResult(let result) = reply else {
                throw EngineTransportError.invalidReply
            }
            return result
        } catch {
            throw Self.remappedTransportError(error)
        }
    }

    public func generateBatch(
        _ requests: [GenerationRequest],
        progressHandler: (@Sendable (Double?, String) -> Void)?
    ) async throws -> [GenerationResult] {
        let commandID = UUID()
        await coordinator.registerBatchProgressHandler(id: commandID, handler: progressHandler)
        defer {
            Task {
                await coordinator.clearBatchProgressHandler(id: commandID)
            }
        }

        do {
            let reply = try await coordinator.send(.generateBatch(commandID: commandID, requests: requests))
            guard case .generationResults(let results) = reply else {
                throw EngineTransportError.invalidReply
            }
            return results
        } catch {
            throw Self.remappedTransportError(error)
        }
    }

    public func cancelActiveGeneration() async throws {
        _ = try await coordinator.send(.cancelActiveGeneration)
    }

    public func listPreparedVoices() async throws -> [PreparedVoice] {
        let reply = try await coordinator.send(.listPreparedVoices)
        guard case .preparedVoices(let voices) = reply else {
            throw EngineTransportError.invalidReply
        }
        return voices
    }

    public func enrollPreparedVoice(name: String, audioPath: String, transcript: String?) async throws -> PreparedVoice {
        let reply = try await coordinator.send(
            .enrollPreparedVoice(name: name, audioPath: audioPath, transcript: transcript)
        )
        guard case .preparedVoice(let voice) = reply else {
            throw EngineTransportError.invalidReply
        }
        return voice
    }

    public func deletePreparedVoice(id: String) async throws {
        _ = try await coordinator.send(.deletePreparedVoice(id: id))
    }

    public func clearGenerationActivity() {
        let clearedSnapshot = TTSEngineSnapshot(
            isReady: snapshot.isReady,
            loadState: snapshot.loadState.currentModelID.map { .loaded(modelID: $0) } ?? .idle,
            clonePreparationState: snapshot.clonePreparationState,
            visibleErrorMessage: snapshot.visibleErrorMessage
        )
        snapshotSubject.send(clearedSnapshot)
        Task {
            await coordinator.fireAndForget(.clearGenerationActivity)
        }
    }

    public func clearVisibleError() {
        let clearedSnapshot = TTSEngineSnapshot(
            isReady: snapshot.isReady,
            loadState: snapshot.loadState,
            clonePreparationState: snapshot.clonePreparationState,
            visibleErrorMessage: nil
        )
        snapshotSubject.send(clearedSnapshot)
        Task {
            await coordinator.fireAndForget(.clearVisibleError)
        }
    }

#if QW_TEST_SUPPORT
    func debugInvalidateConnectionForTesting(shouldReconnect: Bool = false) async {
        await coordinator.invalidateForTesting(shouldReconnect: shouldReconnect)
    }
#endif

    private static func remappedTransportError(_ error: Error) -> Error {
        guard let remoteError = error as? RemoteErrorPayload,
              remoteError.code == .cancelled else {
            return error
        }
        return CancellationError()
    }
}

private extension EngineCommand {
    var transportName: String {
        switch self {
        case .initialize:
            "initialize"
        case .ping:
            "ping"
        case .loadModel:
            "loadModel"
        case .unloadModel:
            "unloadModel"
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
        case .generateBatch:
            "generateBatch"
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
        }
    }

    var transportTimeout: Duration? {
        switch self {
        case .generate, .generateBatch:
            nil
        case .initialize, .loadModel, .unloadModel, .ensureModelLoadedIfNeeded,
             .prewarmModelIfNeeded, .prefetchInteractiveReadinessIfNeeded, .ensureCloneReferencePrimed:
            .seconds(180)
        case .ping, .cancelClonePreparationIfNeeded, .cancelActiveGeneration,
             .listPreparedVoices, .enrollPreparedVoice, .deletePreparedVoice,
             .clearGenerationActivity, .clearVisibleError:
            .seconds(10)
        }
    }
}

#if DEBUG
/// Mirror of `AudioPlayerViewModel.logLivePreviewEvent`. Writes a
/// `[Probe.<layer>] event=<name> key=value ...` line to stderr
/// (line-buffered) so the desktop-UI bench helper picks up cross-layer
/// chunk timings in the same `nohup Vocello > /tmp/vocello-bench.log`
/// stream that already captures the `[LivePreview]` trace. DEBUG-only
/// — release builds compile to a no-op.
fileprivate func logProbeEvent(
    _ layer: String,
    event: String,
    details: KeyValuePairs<String, String> = [:]
) {
    var line = "[Probe.\(layer)] event=\(event)"
    for (key, value) in details {
        line += " \(key)=\(value)"
    }
    line += "\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

/// Variant for callers that need to assemble the field set dynamically
/// (e.g. Engine probe Phase 1 — sub-stage timings only included when
/// the chunk metadata carries them). Uses `[(String, String)]` because
/// `KeyValuePairs` is literal-only.
fileprivate func logProbeEvent(
    _ layer: String,
    event: String,
    orderedDetails: [(String, String)]
) {
    var line = "[Probe.\(layer)] event=\(event)"
    for (key, value) in orderedDetails {
        line += " \(key)=\(value)"
    }
    line += "\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}
#else
fileprivate func logProbeEvent(
    _ layer: String,
    event: String,
    details: KeyValuePairs<String, String> = [:]
) {}

fileprivate func logProbeEvent(
    _ layer: String,
    event: String,
    orderedDetails: [(String, String)]
) {}
#endif
