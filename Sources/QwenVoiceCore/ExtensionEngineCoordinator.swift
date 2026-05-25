import Foundation
import OSLog

actor ExtensionEngineCoordinator {
    private struct ActiveConnection: Sendable {
        let id: UUID
        let transport: any ExtensionEngineTransporting
    }

    private static let logger = Logger(
        subsystem: "com.patricedery.vocello",
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
    private var isCreatingConnection = false
    private var connectionWaiters: [CheckedContinuation<ActiveConnection, Error>] = []
    private var isInitializingConnection = false
    private var initializationWaiters: [CheckedContinuation<Void, Error>] = []
    private var lastInitializationReply: ExtensionEngineReply?
    private var lastDisconnectState: ExtensionEngineLifecycleState?
    /// Handles for outstanding `fireAndForget` tasks so `invalidate()` and
    /// disconnect paths can cancel them instead of letting them race with a
    /// replaced transport (Tier 2.6).
    private var pendingFireAndForgetTasks: [UUID: Task<Void, Never>] = [:]

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
            return try await initializeCurrentConnectionIfNeeded(
                transport: transport,
                appSupportDirectory: URL(fileURLWithPath: path)
            )
        default:
            if !didInitializeCurrentConnection, let initializedAppSupportDirectory {
                _ = try await initializeCurrentConnectionIfNeeded(
                    transport: transport,
                    appSupportDirectory: initializedAppSupportDirectory
                )
            }
            return try await perform(transport: transport, command: command)
        }
    }

    func fireAndForget(_ command: ExtensionEngineCommand) {
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.send(command)
            } catch is CancellationError {
                // Parent transport was replaced or invalidated — drop silently.
            } catch {
                Self.logger.error(
                    "Best-effort engine-extension command '\(command.transportName, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            await self.removeFireAndForgetTask(id: taskID)
        }
        pendingFireAndForgetTasks[taskID] = task
    }

    private func removeFireAndForgetTask(id: UUID) {
        pendingFireAndForgetTasks.removeValue(forKey: id)
    }

    private func cancelAllFireAndForgetTasks() {
        let tasks = pendingFireAndForgetTasks.values
        pendingFireAndForgetTasks.removeAll()
        for task in tasks {
            task.cancel()
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
        if isCreatingConnection {
            return try await withCheckedThrowingContinuation { continuation in
                connectionWaiters.append(continuation)
            }
        }

        isCreatingConnection = true
        let reconnecting = lastDisconnectState != nil
        onLifecycleState(reconnecting ? .recovering : .launching)
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
            lastInitializationReply = nil
            lastDisconnectState = nil
            onLifecycleState(.connected)
            finishConnectionCreation(.success(connection))
            return connection
        } catch {
            onLifecycleState(.failed)
#if DEBUG
            print("[ExtensionEngineCoordinator] Failed to create engine-extension transport: \(error.localizedDescription)")
#endif
            finishConnectionCreation(.failure(error))
            throw error
        }
    }

    private func finishConnectionCreation(_ result: Result<ActiveConnection, Error>) {
        isCreatingConnection = false
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    private func initializeCurrentConnectionIfNeeded(
        transport: ActiveConnection,
        appSupportDirectory: URL
    ) async throws -> ExtensionEngineReply {
        if didInitializeCurrentConnection, let lastInitializationReply {
            return lastInitializationReply
        }
        if isInitializingConnection {
            try await withCheckedThrowingContinuation { continuation in
                initializationWaiters.append(continuation)
            }
            guard didInitializeCurrentConnection, let lastInitializationReply else {
                throw ExtensionEngineTransportError.invalidReply
            }
            return lastInitializationReply
        }

        isInitializingConnection = true
        do {
            let reply = try await perform(
                transport: transport,
                command: .initialize(appSupportDirectoryPath: appSupportDirectory.path)
            )
            didInitializeCurrentConnection = true
            lastInitializationReply = reply
            finishInitialization(.success(()))
            return reply
        } catch {
            finishInitialization(.failure(error))
            throw error
        }
    }

    private func finishInitialization(_ result: Result<Void, Error>) {
        isInitializingConnection = false
        let waiters = initializationWaiters
        initializationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(with: result)
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
#if DEBUG
        print("[ExtensionEngineCoordinator] Sending engine-extension command '\(command.transportName)'")
#endif

        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

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
        } onCancel: {
            Task { await self.cancelPendingRequest(id: requestEnvelope.id, command: command) }
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
#if DEBUG
            print("[ExtensionEngineCoordinator] Engine-extension command '\(pendingRequest.commandName)' failed: \(error.localizedDescription)")
#endif
            pendingRequest.resume(.failure(error))
        } else {
#if DEBUG
            print("[ExtensionEngineCoordinator] Engine-extension command '\(pendingRequest.commandName)' replied")
#endif
            pendingRequest.resume(.success(envelope.reply))
        }
    }

    private func handleTimeout(for requestID: UUID) {
        guard let pendingRequest = pendingRequests.removeValue(forKey: requestID) else { return }
        pendingRequest.timeoutTask?.cancel()
        let error = ExtensionEngineTransportError.timedOut(commandName: pendingRequest.commandName)
        Self.logger.error("\(error.localizedDescription, privacy: .public)")
        pendingRequest.resume(.failure(error))
        if pendingRequest.commandName == "generate" {
            fireAndForget(.cancelActiveGeneration)
        }
    }

    private func cancelPendingRequest(id requestID: UUID, command: ExtensionEngineCommand) {
        guard let pendingRequest = pendingRequests.removeValue(forKey: requestID) else { return }
        pendingRequest.timeoutTask?.cancel()
        Self.logger.debug(
            "Cancelled engine-extension command '\(pendingRequest.commandName, privacy: .public)' with id \(requestID.uuidString, privacy: .public)"
        )
        pendingRequest.resume(.failure(CancellationError()))
        if let cleanupCommand = cancellationCleanupCommand(for: command) {
            fireAndForget(cleanupCommand)
        }
    }

    private func cancellationCleanupCommand(for command: ExtensionEngineCommand) -> ExtensionEngineCommand? {
        switch command {
        case .generate:
            return .cancelActiveGeneration
        case .ensureCloneReferencePrimed:
            return .cancelClonePreparationIfNeeded
        default:
            return nil
        }
    }

    private func handleDisconnect(
        connectionID: UUID,
        transportError: ExtensionEngineTransportError,
        message: String?
    ) {
        if let message {
            Self.logger.error("Engine-extension disconnect cleanup: \(message, privacy: .public)")
#if DEBUG
            print("[ExtensionEngineCoordinator] Engine-extension disconnect cleanup: \(message)")
#endif
        }

        guard let connectionToInvalidate = disconnectCurrentConnectionIfNeeded(connectionID: connectionID) else {
            Self.logger.debug(
                "Ignoring engine-extension disconnect cleanup from stale connection \(connectionID.uuidString, privacy: .public)."
            )
            return
        }
        connectionToInvalidate.invalidate()
        didInitializeCurrentConnection = false
        lastInitializationReply = nil
        let lifecycleState = lifecycleState(for: transportError)
        lastDisconnectState = lifecycleState
        onLifecycleState(lifecycleState)

        let pendingRequestBoxes = pendingRequests.values
        pendingRequests.removeAll()
        for pendingRequest in pendingRequestBoxes {
            pendingRequest.timeoutTask?.cancel()
            pendingRequest.resume(.failure(transportError))
        }

        // Tier 2.6: any best-effort commands still racing against the old
        // transport get cancelled alongside the explicit pending requests.
        cancelAllFireAndForgetTasks()

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
