@preconcurrency import Combine
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
        let proxy = connection.remoteObjectProxyWithErrorHandler { [handlers] error in
            handlers.onRemoteError(error)
        } as! QwenVoiceEngineServiceXPCProtocol
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

    private let onSnapshot: @Sendable (TTSEngineSnapshot) -> Void
    private let onChunk: @Sendable (GenerationEvent) -> Void
    private let transportFactory: XPCNativeEngineTransportFactory
    private let timeoutResolver: XPCNativeEngineTimeoutResolver

    private var activeConnection: ActiveConnection?
    private var didInitializeCurrentConnection = false
    private var initializedAppSupportDirectory: URL?
    private var batchProgressHandlers: [UUID: BatchProgressHandlerBox] = [:]
    private var pendingRequests: [UUID: PendingRequestBox] = [:]

    init(
        onSnapshot: @escaping @Sendable (TTSEngineSnapshot) -> Void,
        onChunk: @escaping @Sendable (GenerationEvent) -> Void,
        transportFactory: @escaping XPCNativeEngineTransportFactory = { handlers in
            XPCServiceTransport(handlers: handlers)
        },
        timeoutResolver: @escaping XPCNativeEngineTimeoutResolver = { command in
            command.transportTimeout
        }
    ) {
        self.onSnapshot = onSnapshot
        self.onChunk = onChunk
        self.transportFactory = transportFactory
        self.timeoutResolver = timeoutResolver
    }

    func initialize(appSupportDirectory: URL) async throws {
        initializedAppSupportDirectory = appSupportDirectory
        _ = try await send(.initialize(appSupportDirectoryPath: appSupportDirectory.path))
    }

    func send(_ command: EngineCommand) async throws -> EngineReply {
        let transport = ensureConnection()
        switch command {
        case .initialize(let path):
            initializedAppSupportDirectory = URL(fileURLWithPath: path)
            let reply = try await perform(transport: transport, command: command)
            didInitializeCurrentConnection = true
            return reply
        default:
            if !didInitializeCurrentConnection, let initializedAppSupportDirectory {
                _ = try await perform(
                    transport: transport,
                    command: .initialize(appSupportDirectoryPath: initializedAppSupportDirectory.path)
                )
                didInitializeCurrentConnection = true
            }
            return try await perform(transport: transport, command: command)
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
        Task {
            do {
                _ = try await send(command)
            } catch {
                Self.logger.error(
                    "Best-effort command '\(command.transportName, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func invalidateForTesting() {
        guard let connectionID = activeConnection?.id else { return }
        handleConnectionInvalidated(for: connectionID)
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
        let requestEnvelope = EngineRequestEnvelope(id: UUID(), command: command)
        let payload = try EngineServiceCodec.encode(requestEnvelope)

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
        message: String?
    ) {
        if let message {
            Self.logger.error("Disconnect cleanup: \(message, privacy: .public)")
        }

        guard let connectionToInvalidate = disconnectCurrentConnectionIfNeeded(connectionID: connectionID) else {
            Self.logger.debug(
                "Ignoring disconnect cleanup from stale connection \(connectionID.uuidString, privacy: .public)."
            )
            return
        }
        connectionToInvalidate.invalidate()
        didInitializeCurrentConnection = false
        batchProgressHandlers.removeAll()

        let pendingRequestBoxes = pendingRequests.values
        pendingRequests.removeAll()
        for pendingRequest in pendingRequestBoxes {
            pendingRequest.timeoutTask?.cancel()
            pendingRequest.resume(.failure(transportError))
        }

        let visibleMessage = message ?? transportError.localizedDescription
        onSnapshot(
            TTSEngineSnapshot(
                isReady: false,
                loadState: .failed(message: visibleMessage),
                clonePreparationState: .idle,
                visibleErrorMessage: visibleMessage
            )
        )
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
}

public final class XPCNativeEngineClient: MacTTSEngine, @unchecked Sendable {
    private let snapshotSubject: CurrentValueSubject<TTSEngineSnapshot, Never>
    private let coordinator: XPCNativeEngineCoordinator

    public init() {
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
            onChunk: { event in
                GenerationChunkBroker.publish(event)
            }
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
        guard case .bool(let value) = reply else {
            throw EngineTransportError.invalidReply
        }
        return value
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

    public func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {
        _ = try await coordinator.send(.ensureCloneReferencePrimed(modelID: modelID, reference: reference))
    }

    public func cancelClonePreparationIfNeeded() async {
        await coordinator.fireAndForget(.cancelClonePreparationIfNeeded)
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        let reply = try await coordinator.send(.generate(request: request))
        guard case .generationResult(let result) = reply else {
            throw EngineTransportError.invalidReply
        }
        return result
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

        let reply = try await coordinator.send(.generateBatch(commandID: commandID, requests: requests))
        guard case .generationResults(let results) = reply else {
            throw EngineTransportError.invalidReply
        }
        return results
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

    #if DEBUG
    func debugInvalidateConnectionForTesting() async {
        await coordinator.invalidateForTesting()
    }
    #endif
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
             .prewarmModelIfNeeded, .ensureCloneReferencePrimed:
            .seconds(180)
        case .ping, .cancelClonePreparationIfNeeded, .cancelActiveGeneration,
             .listPreparedVoices, .enrollPreparedVoice, .deletePreparedVoice,
             .clearGenerationActivity, .clearVisibleError:
            .seconds(10)
        }
    }
}
