@preconcurrency import Combine
import Foundation

private enum XPCNativeEngineClientError: LocalizedError {
    case invalidReply

    var errorDescription: String? {
        switch self {
        case .invalidReply:
            return "The engine service returned an invalid reply."
        }
    }
}

private final class BatchProgressHandlerBox: @unchecked Sendable {
    let handler: @Sendable (Double?, String) -> Void

    init(handler: @escaping @Sendable (Double?, String) -> Void) {
        self.handler = handler
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

private actor XPCNativeEngineCoordinator {
    private let onSnapshot: @Sendable (TTSEngineSnapshot) -> Void
    private let onChunk: @Sendable (GenerationEvent) -> Void

    private var connection: NSXPCConnection?
    private var didInitializeCurrentConnection = false
    private var initializedAppSupportDirectory: URL?
    private var batchProgressHandlers: [UUID: BatchProgressHandlerBox] = [:]

    init(
        onSnapshot: @escaping @Sendable (TTSEngineSnapshot) -> Void,
        onChunk: @escaping @Sendable (GenerationEvent) -> Void
    ) {
        self.onSnapshot = onSnapshot
        self.onChunk = onChunk
    }

    func initialize(appSupportDirectory: URL) async throws {
        initializedAppSupportDirectory = appSupportDirectory
        _ = try await send(.initialize(appSupportDirectoryPath: appSupportDirectory.path))
    }

    func send(_ command: EngineCommand) async throws -> EngineReply {
        let proxy = ensureConnection()
        switch command {
        case .initialize(let path):
            initializedAppSupportDirectory = URL(fileURLWithPath: path)
            let reply = try await perform(proxy: proxy, command: command)
            didInitializeCurrentConnection = true
            return reply
        default:
            if !didInitializeCurrentConnection, let initializedAppSupportDirectory {
                _ = try await perform(
                    proxy: proxy,
                    command: .initialize(appSupportDirectoryPath: initializedAppSupportDirectory.path)
                )
                didInitializeCurrentConnection = true
            }
            return try await perform(proxy: proxy, command: command)
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
            _ = try? await send(command)
        }
    }

    func invalidateForTesting() {
        handleConnectionInvalidated()
    }

    func handleEventData(_ data: Data) {
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
            handleDisconnect(message: "The engine service sent an unreadable event: \(error.localizedDescription)")
        }
    }

    func handleRemoteError(_ error: Error) {
        handleDisconnect(message: error.localizedDescription)
    }

    func handleConnectionInterrupted() {
        handleDisconnect(message: "The engine service connection was interrupted.")
    }

    func handleConnectionInvalidated() {
        handleDisconnect(message: "The engine service connection was invalidated.")
    }

    private func ensureConnection() -> QwenVoiceEngineServiceXPCProtocol {
        if let connection {
            return connection.remoteObjectProxyWithErrorHandler { [weak self] error in
                Task {
                    await self?.handleRemoteError(error)
                }
            } as! QwenVoiceEngineServiceXPCProtocol
        }

        let sink = XPCNativeEngineClientEventSink { [weak self] payload in
            Task {
                await self?.handleEventData(payload)
            }
        }

        let connection = NSXPCConnection(serviceName: QwenVoiceEngineServiceBundleIdentifier)
        connection.remoteObjectInterface = NSXPCInterface(with: QwenVoiceEngineServiceXPCProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: QwenVoiceEngineClientEventXPCProtocol.self)
        connection.exportedObject = sink
        connection.interruptionHandler = { [weak self] in
            Task {
                await self?.handleConnectionInterrupted()
            }
        }
        connection.invalidationHandler = { [weak self] in
            Task {
                await self?.handleConnectionInvalidated()
            }
        }
        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task {
                await self?.handleRemoteError(error)
            }
        } as! QwenVoiceEngineServiceXPCProtocol

        self.connection = connection
        self.didInitializeCurrentConnection = false
        return proxy
    }

    private func perform(
        proxy: QwenVoiceEngineServiceXPCProtocol,
        command: EngineCommand
    ) async throws -> EngineReply {
        let payload = try EngineServiceCodec.encode(command)

        return try await withCheckedThrowingContinuation { continuation in
            proxy.perform(payload) { replyData in
                do {
                    let reply = try EngineServiceCodec.decode(EngineReply.self, from: replyData)
                    if case .failure(let error) = reply {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: reply)
                    }
                } catch {
                    continuation.resume(throwing: XPCNativeEngineClientError.invalidReply)
                }
            }
        }
    }

    private func handleDisconnect(message: String) {
        connection?.invalidate()
        connection = nil
        didInitializeCurrentConnection = false
        batchProgressHandlers.removeAll()
        onSnapshot(
            TTSEngineSnapshot(
                isReady: false,
                loadState: .failed(message: message),
                clonePreparationState: .idle,
                visibleErrorMessage: message
            )
        )
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
            throw XPCNativeEngineClientError.invalidReply
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
        _ = try? await coordinator.send(.ensureModelLoadedIfNeeded(id: id))
    }

    public func prewarmModelIfNeeded(for request: GenerationRequest) async {
        _ = try? await coordinator.send(.prewarmModelIfNeeded(request: request))
    }

    public func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {
        _ = try await coordinator.send(.ensureCloneReferencePrimed(modelID: modelID, reference: reference))
    }

    public func cancelClonePreparationIfNeeded() async {
        _ = try? await coordinator.send(.cancelClonePreparationIfNeeded)
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        let reply = try await coordinator.send(.generate(request: request))
        guard case .generationResult(let result) = reply else {
            throw XPCNativeEngineClientError.invalidReply
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
            throw XPCNativeEngineClientError.invalidReply
        }
        return results
    }

    public func cancelActiveGeneration() async throws {
        _ = try await coordinator.send(.cancelActiveGeneration)
    }

    public func listPreparedVoices() async throws -> [PreparedVoice] {
        let reply = try await coordinator.send(.listPreparedVoices)
        guard case .preparedVoices(let voices) = reply else {
            throw XPCNativeEngineClientError.invalidReply
        }
        return voices
    }

    public func enrollPreparedVoice(name: String, audioPath: String, transcript: String?) async throws -> PreparedVoice {
        let reply = try await coordinator.send(
            .enrollPreparedVoice(name: name, audioPath: audioPath, transcript: transcript)
        )
        guard case .preparedVoice(let voice) = reply else {
            throw XPCNativeEngineClientError.invalidReply
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
