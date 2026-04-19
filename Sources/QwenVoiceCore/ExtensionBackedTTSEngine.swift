import Combine
import ExtensionFoundation
import Foundation
import OSLog

enum ExtensionEngineTransportError: LocalizedError, Equatable, Sendable {
    case interrupted
    case invalidated
    case timedOut(commandName: String)
    case staleOrMismatchedReply(id: UUID)
    case invalidReply

    var errorDescription: String? {
        switch self {
        case .interrupted:
            return "The Vocello engine extension connection was interrupted."
        case .invalidated:
            return "The Vocello engine extension connection was invalidated."
        case .timedOut(let commandName):
            return "The Vocello engine extension request timed out while running \(commandName)."
        case .staleOrMismatchedReply(let id):
            return "The Vocello engine extension returned a stale or mismatched reply for request \(id.uuidString)."
        case .invalidReply:
            return "The Vocello engine extension returned an invalid reply."
        }
    }
}

struct ExtensionEngineTransportHandlers: Sendable {
    let onEventData: @Sendable (Data) -> Void
    let onRemoteError: @Sendable (Error) -> Void
    let onInterrupted: @Sendable () -> Void
    let onInvalidated: @Sendable () -> Void
}

protocol ExtensionEngineTransporting: AnyObject, Sendable {
    func resume()
    func invalidate()
    func perform(_ payload: Data, reply: @escaping @Sendable (Data) -> Void)
}

typealias ExtensionAppIdentityResolver = @Sendable () async throws -> AppExtensionIdentity
typealias ExtensionEngineTransportFactory = @Sendable (ExtensionEngineTransportHandlers) async throws -> any ExtensionEngineTransporting
typealias ExtensionEngineTimeoutResolver = @Sendable (ExtensionEngineCommand) -> Duration?

private final class PendingExtensionRequestBox: @unchecked Sendable {
    let commandName: String
    let resume: @Sendable (Result<ExtensionEngineReply, Error>) -> Void
    var timeoutTask: Task<Void, Never>?

    init(
        commandName: String,
        resume: @escaping @Sendable (Result<ExtensionEngineReply, Error>) -> Void
    ) {
        self.commandName = commandName
        self.resume = resume
    }
}

private final class VocelloEngineClientEventSink: NSObject, VocelloEngineClientEventXPCProtocol {
    private let onEvent: @Sendable (Data) -> Void

    init(onEvent: @escaping @Sendable (Data) -> Void) {
        self.onEvent = onEvent
    }

    func handleEvent(_ payload: Data) {
        onEvent(payload)
    }
}

private final class AppExtensionProcessTransport: NSObject, ExtensionEngineTransporting, @unchecked Sendable {
    private let process: AppExtensionProcess
    private let connection: NSXPCConnection
    private let eventSink: VocelloEngineClientEventSink
    private let handlers: ExtensionEngineTransportHandlers

    init(
        identityResolver: ExtensionAppIdentityResolver,
        handlers: ExtensionEngineTransportHandlers
    ) async throws {
        self.handlers = handlers
        let identity = try await identityResolver()
        let configuration = AppExtensionProcess.Configuration(
            appExtensionIdentity: identity,
            onInterruption: handlers.onInterrupted
        )
        let process = try await AppExtensionProcess(configuration: configuration)
        let connection = try process.makeXPCConnection()
        let eventSink = VocelloEngineClientEventSink(onEvent: handlers.onEventData)

        self.process = process
        self.connection = connection
        self.eventSink = eventSink

        super.init()

        connection.remoteObjectInterface = NSXPCInterface(with: VocelloEngineExtensionXPCProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: VocelloEngineClientEventXPCProtocol.self)
        connection.exportedObject = eventSink
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
        process.invalidate()
    }

    func perform(_ payload: Data, reply: @escaping @Sendable (Data) -> Void) {
        let proxy = connection.remoteObjectProxyWithErrorHandler { [handlers] error in
            handlers.onRemoteError(error)
        } as! VocelloEngineExtensionXPCProtocol
        proxy.perform(payload, withReply: reply)
    }
}

actor ExtensionEngineCoordinator {
    private struct ActiveConnection {
        let id: UUID
        let transport: any ExtensionEngineTransporting
    }

    private static let logger = Logger(
        subsystem: "com.qvoice.ios",
        category: "ExtensionBackedTTSEngine"
    )

    private let onSnapshot: @Sendable (TTSEngineSnapshot) -> Void
    private let onChunk: @Sendable (GenerationEvent) -> Void
    private let transportFactory: ExtensionEngineTransportFactory
    private let timeoutResolver: ExtensionEngineTimeoutResolver

    private var activeConnection: ActiveConnection?
    private var didInitializeCurrentConnection = false
    private var initializedAppSupportDirectory: URL?
    private var pendingRequests: [UUID: PendingExtensionRequestBox] = [:]

    init(
        onSnapshot: @escaping @Sendable (TTSEngineSnapshot) -> Void,
        onChunk: @escaping @Sendable (GenerationEvent) -> Void,
        transportFactory: @escaping ExtensionEngineTransportFactory,
        timeoutResolver: @escaping ExtensionEngineTimeoutResolver = { command in
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

    func send(_ command: ExtensionEngineCommand) async throws -> ExtensionEngineReply {
        let transport = try await ensureConnection()
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

    func fireAndForget(_ command: ExtensionEngineCommand) {
        Task {
            do {
                _ = try await send(command)
            } catch {
                Self.logger.error(
                    "Best-effort engine-extension command '\(command.transportName, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func invalidate() {
        guard let connectionID = activeConnection?.id else { return }
        handleConnectionInvalidated(for: connectionID)
    }

    func handleEventData(_ data: Data, from connectionID: UUID) {
        guard isCurrentConnection(connectionID) else {
            Self.logger.debug(
                "Ignoring engine-extension event from stale connection \(connectionID.uuidString, privacy: .public)."
            )
            return
        }

        do {
            let event = try ExtensionEngineCodec.decode(ExtensionEngineEventEnvelope.self, from: data)
            switch event {
            case .snapshot(let snapshot):
                onSnapshot(snapshot)
            case .generationChunk(let generationEvent):
                onChunk(generationEvent)
            }
        } catch {
            Self.logger.error("Unreadable engine-extension event payload: \(error.localizedDescription, privacy: .public)")
            handleDisconnect(
                connectionID: connectionID,
                transportError: .invalidReply,
                message: "The Vocello engine extension sent an unreadable event: \(error.localizedDescription)"
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
            message: ExtensionEngineTransportError.interrupted.localizedDescription
        )
    }

    func handleConnectionInvalidated(for connectionID: UUID) {
        handleDisconnect(
            connectionID: connectionID,
            transportError: .invalidated,
            message: ExtensionEngineTransportError.invalidated.localizedDescription
        )
    }

    private func ensureConnection() async throws -> ActiveConnection {
        if let activeConnection {
            return activeConnection
        }

        let connectionID = UUID()
        let handlers = ExtensionEngineTransportHandlers(
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

        let transport = try await transportFactory(handlers)
        transport.resume()
        let connection = ActiveConnection(id: connectionID, transport: transport)
        activeConnection = connection
        didInitializeCurrentConnection = false
        return connection
    }

    private func perform(
        transport: ActiveConnection,
        command: ExtensionEngineCommand
    ) async throws -> ExtensionEngineReply {
        let requestEnvelope = ExtensionEngineRequestEnvelope(id: UUID(), command: command)
        let payload = try ExtensionEngineCodec.encode(requestEnvelope)

        Self.logger.debug(
            "Sending engine-extension command '\(command.transportName, privacy: .public)' with id \(requestEnvelope.id.uuidString, privacy: .public)"
        )

        return try await withCheckedThrowingContinuation { continuation in
            let pendingRequest = PendingExtensionRequestBox(
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
                "Ignoring engine-extension reply from stale connection \(connectionID.uuidString, privacy: .public)."
            )
            return
        }

        let envelope: ExtensionEngineReplyEnvelope
        do {
            envelope = try ExtensionEngineCodec.decode(ExtensionEngineReplyEnvelope.self, from: data)
        } catch {
            Self.logger.error("Unreadable engine-extension reply payload: \(error.localizedDescription, privacy: .public)")
            handleDisconnect(
                connectionID: connectionID,
                transportError: .invalidReply,
                message: ExtensionEngineTransportError.invalidReply.localizedDescription
            )
            return
        }

        guard let pendingRequest = pendingRequests.removeValue(forKey: envelope.id) else {
            let transportError = ExtensionEngineTransportError.staleOrMismatchedReply(id: envelope.id)
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
        let error = ExtensionEngineTransportError.timedOut(commandName: pendingRequest.commandName)
        Self.logger.error("\(error.localizedDescription, privacy: .public)")
        pendingRequest.resume(.failure(error))
    }

    private func handleDisconnect(
        connectionID: UUID,
        transportError: ExtensionEngineTransportError,
        message: String?
    ) {
        if let message {
            Self.logger.error("Engine-extension disconnect cleanup: \(message, privacy: .public)")
        }

        guard let connectionToInvalidate = disconnectCurrentConnectionIfNeeded(connectionID: connectionID) else {
            Self.logger.debug(
                "Ignoring engine-extension disconnect cleanup from stale connection \(connectionID.uuidString, privacy: .public)."
            )
            return
        }
        connectionToInvalidate.invalidate()
        didInitializeCurrentConnection = false

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
                loadState: .crashed(visibleMessage),
                clonePreparationState: .idle,
                visibleErrorMessage: visibleMessage
            )
        )
    }

    private func isCurrentConnection(_ connectionID: UUID) -> Bool {
        activeConnection?.id == connectionID
    }

    private func disconnectCurrentConnectionIfNeeded(connectionID: UUID) -> (any ExtensionEngineTransporting)? {
        guard activeConnection?.id == connectionID else { return nil }
        let transport = activeConnection?.transport
        activeConnection = nil
        return transport
    }
}

@MainActor
public final class ExtensionBackedTTSEngine: TTSEngineRuntimeControlling {
    public let modelRegistry: any ModelRegistry

    @Published public private(set) var loadState: EngineLoadState = .idle
    @Published public private(set) var clonePreparationState: ClonePreparationState = .idle
    @Published public private(set) var latestEvent: GenerationEvent?
    public private(set) var visibleErrorMessage: String?

    public var isReady: Bool {
        loadState.isReady
    }

    private let documentIO: any DocumentIO
    private let transportFactory: ExtensionEngineTransportFactory
    private let chunkForwarder: @Sendable (GenerationEvent) -> Void
    private var allowsProactiveWarmOperations = true
    private lazy var coordinator: ExtensionEngineCoordinator = {
        ExtensionEngineCoordinator(
            onSnapshot: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    self?.apply(snapshot)
                }
            },
            onChunk: { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.chunkForwarder(event)
                    self?.latestEvent = event
                }
            },
            transportFactory: transportFactory
        )
    }()

    public convenience init(
        modelRegistry: any ModelRegistry,
        documentIO: any DocumentIO,
        identityResolver: @escaping @Sendable () async throws -> AppExtensionIdentity
    ) {
        self.init(
            modelRegistry: modelRegistry,
            documentIO: documentIO,
            transportFactory: { handlers in
                try await AppExtensionProcessTransport(
                    identityResolver: identityResolver,
                    handlers: handlers
                )
            }
        )
    }

    init(
        modelRegistry: any ModelRegistry,
        documentIO: any DocumentIO,
        transportFactory: @escaping ExtensionEngineTransportFactory,
        onChunk: @escaping @Sendable (GenerationEvent) -> Void = { _ in }
    ) {
        self.modelRegistry = modelRegistry
        self.documentIO = documentIO
        self.transportFactory = transportFactory
        self.chunkForwarder = onChunk
    }

    public func supportDecision(for request: GenerationRequest) -> GenerationSupportDecision {
        switch request.payload {
        case .custom, .design, .clone:
            return .supported(.nativeMLX)
        }
    }

    public func start() {}

    public func stop() {
        Task {
            await coordinator.invalidate()
        }
    }

    public func initialize(appSupportDirectory: URL) async throws {
        let reply = try await coordinator.send(
            .initialize(appSupportDirectoryPath: appSupportDirectory.path)
        )
        guard case .snapshot(let snapshot) = reply else {
            throw ExtensionEngineTransportError.invalidReply
        }
        apply(snapshot)
    }

    public func ping() async throws -> Bool {
        let reply = try await coordinator.send(.ping)
        guard case .bool(let value) = reply else {
            throw ExtensionEngineTransportError.invalidReply
        }
        return value
    }

    public func loadModel(id: String) async throws {
        _ = try await coordinator.send(.loadModel(id: id))
    }

    public func unloadModel() async throws {
        _ = try await coordinator.send(.unloadModel)
    }

    public func prepareAudio(_ request: AudioPreparationRequest) async throws -> AudioNormalizationResult {
        let reply = try await coordinator.send(.prepareAudio(request: request))
        guard case .audioNormalizationResult(let result) = reply else {
            throw ExtensionEngineTransportError.invalidReply
        }
        return result
    }

    public func ensureModelLoadedIfNeeded(id: String) async {
        await coordinator.fireAndForget(.ensureModelLoadedIfNeeded(id: id))
    }

    public func prewarmModelIfNeeded(for request: GenerationRequest) async {
        guard allowsProactiveWarmOperations else { return }
        await coordinator.fireAndForget(.prewarmModelIfNeeded(request: request))
    }

    public func prefetchInteractiveReadinessIfNeeded(
        for request: GenerationRequest
    ) async -> InteractivePrefetchDiagnostics? {
        guard allowsProactiveWarmOperations else { return nil }
        do {
            let reply = try await coordinator.send(.prefetchInteractiveReadinessIfNeeded(request: request))
            guard case .interactivePrefetchDiagnostics(let diagnostics) = reply else {
                return nil
            }
            return diagnostics
        } catch {
            return nil
        }
    }

    public func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {
        guard allowsProactiveWarmOperations else { return }
        _ = try await coordinator.send(.ensureCloneReferencePrimed(modelID: modelID, reference: reference))
    }

    public func cancelClonePreparationIfNeeded() async {
        await coordinator.fireAndForget(.cancelClonePreparationIfNeeded)
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        do {
            let reply = try await coordinator.send(.generate(request: request))
            guard case .generationResult(let result) = reply else {
                throw ExtensionEngineTransportError.invalidReply
            }
            return result
        } catch {
            throw Self.remappedTransportError(error)
        }
    }

    public func listPreparedVoices() async throws -> [PreparedVoice] {
        let reply = try await coordinator.send(.listPreparedVoices)
        guard case .preparedVoices(let voices) = reply else {
            throw ExtensionEngineTransportError.invalidReply
        }
        return voices
    }

    public func enrollPreparedVoice(name: String, audioPath: String, transcript: String?) async throws -> PreparedVoice {
        let reply = try await coordinator.send(
            .enrollPreparedVoice(name: name, audioPath: audioPath, transcript: transcript)
        )
        guard case .preparedVoice(let voice) = reply else {
            throw ExtensionEngineTransportError.invalidReply
        }
        return voice
    }

    public func deletePreparedVoice(id: String) async throws {
        _ = try await coordinator.send(.deletePreparedVoice(id: id))
    }

    public func importReferenceAudio(from sourceURL: URL) throws -> ImportedReferenceAudio {
        try documentIO.importReferenceAudio(from: sourceURL)
    }

    public func exportGeneratedAudio(from sourceURL: URL, to destinationURL: URL) throws -> ExportedDocument {
        try documentIO.exportGeneratedAudio(from: sourceURL, to: destinationURL)
    }

    public func clearGenerationActivity() {
        latestEvent = nil
        Task {
            await coordinator.fireAndForget(.clearGenerationActivity)
        }
    }

    public func clearVisibleError() {
        visibleErrorMessage = nil
        Task {
            await coordinator.fireAndForget(.clearVisibleError)
        }
    }

    public func setVisibleError(_ message: String?) {
        visibleErrorMessage = message
    }

    public func setAllowsProactiveWarmOperations(_ allow: Bool) {
        allowsProactiveWarmOperations = allow
    }

    public func trimMemory(level: NativeMemoryTrimLevel, reason: String) async {
        do {
            _ = try await coordinator.send(.trimMemory(level: level, reason: reason))
        } catch {
            visibleErrorMessage = error.localizedDescription
        }
    }

    private func apply(_ snapshot: TTSEngineSnapshot) {
        loadState = snapshot.loadState
        clonePreparationState = snapshot.clonePreparationState
        visibleErrorMessage = snapshot.visibleErrorMessage
    }

    private static func remappedTransportError(_ error: Error) -> Error {
        guard let remoteError = error as? ExtensionRemoteErrorPayload,
              remoteError.code == .cancelled else {
            return error
        }
        return CancellationError()
    }
}

private extension ExtensionEngineCommand {
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
        case .trimMemory:
            "trimMemory"
        }
    }

    var transportTimeout: Duration? {
        switch self {
        case .generate:
            nil
        case .initialize, .loadModel, .unloadModel, .prepareAudio,
             .ensureModelLoadedIfNeeded, .prewarmModelIfNeeded,
             .prefetchInteractiveReadinessIfNeeded, .ensureCloneReferencePrimed,
             .trimMemory:
            .seconds(180)
        case .ping, .cancelClonePreparationIfNeeded, .listPreparedVoices,
             .enrollPreparedVoice, .deletePreparedVoice,
             .clearGenerationActivity, .clearVisibleError:
            .seconds(10)
        }
    }
}
