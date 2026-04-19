import Foundation
import OSLog

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
    private let onLifecycleState: @Sendable (ExtensionEngineLifecycleState) -> Void
    private let transportFactory: ExtensionEngineTransportFactory
    private let timeoutResolver: ExtensionEngineTimeoutResolver

    private var activeConnection: ActiveConnection?
    private var didInitializeCurrentConnection = false
    private var initializedAppSupportDirectory: URL?
    private var pendingRequests: [UUID: PendingExtensionRequestBox] = [:]
    private var lastDisconnectState: ExtensionEngineLifecycleState?

    init(
        onSnapshot: @escaping @Sendable (TTSEngineSnapshot) -> Void,
        onChunk: @escaping @Sendable (GenerationEvent) -> Void,
        onLifecycleState: @escaping @Sendable (ExtensionEngineLifecycleState) -> Void,
        transportFactory: @escaping ExtensionEngineTransportFactory,
        timeoutResolver: @escaping ExtensionEngineTimeoutResolver = { command in
            command.transportTimeout
        }
    ) {
        self.onSnapshot = onSnapshot
        self.onChunk = onChunk
        self.onLifecycleState = onLifecycleState
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

        let reconnecting = lastDisconnectState != nil
        onLifecycleState(reconnecting ? .recovering : .connecting)
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

        do {
            let transport = try await transportFactory(handlers)
            transport.resume()
            let connection = ActiveConnection(id: connectionID, transport: transport)
            activeConnection = connection
            didInitializeCurrentConnection = false
            lastDisconnectState = nil
            onLifecycleState(.connected)
            return connection
        } catch {
            onLifecycleState(.failed)
            throw error
        }
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
        let lifecycleState = lifecycleState(for: transportError)
        lastDisconnectState = lifecycleState
        onLifecycleState(lifecycleState)

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

    private func lifecycleState(for transportError: ExtensionEngineTransportError) -> ExtensionEngineLifecycleState {
        switch transportError {
        case .interrupted:
            return .interrupted
        case .invalidated:
            return .invalidated
        case .timedOut, .staleOrMismatchedReply, .invalidReply:
            return .failed
        }
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
