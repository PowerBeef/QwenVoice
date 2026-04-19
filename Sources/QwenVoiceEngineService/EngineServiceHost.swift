import Combine
import Foundation
import OSLog
import QwenVoiceEngineSupport
import QwenVoiceNativeRuntime

private final class EngineReplyHandlerBox: @unchecked Sendable {
    let reply: (Data) -> Void

    init(reply: @escaping (Data) -> Void) {
        self.reply = reply
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

    private let engine = NativeMLXMacEngine()
    private let sessionLock = NSLock()
    private var activeSession: ActiveSession?
    private var cancellables: Set<AnyCancellable> = []

    private override init() {
        super.init()

        engine.snapshotPublisher
            .sink { [weak self] snapshot in
                self?.publish(.snapshot(snapshot))
            }
            .store(in: &cancellables)

        engine.generationEventPublisher
            .sink { [weak self] event in
                self?.publish(.generationChunk(event))
            }
            .store(in: &cancellables)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let sessionID = UUID()
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
        publish(.snapshot(engine.snapshot), toSessionID: sessionID)
        return true
    }

    func perform(_ payload: Data, withReply reply: @escaping (Data) -> Void) {
        let replyHandler = EngineReplyHandlerBox(reply: reply)
        Task { [payload, replyHandler] in
            let response = await handleCommandPayload(payload)
            let encodedResponse = (try? EngineServiceCodec.encode(response))
                ?? (try! EngineServiceCodec.encode(
                    EngineReplyEnvelope(
                        id: UUID(),
                        reply: .failure(
                            RemoteErrorPayload(message: "The engine service failed to encode its reply.")
                        )
                    )
                ))
            replyHandler.reply(encodedResponse)
        }
    }

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

    private func perform(_ command: EngineCommand) async throws -> EngineReply {
        switch command {
        case .initialize(let appSupportDirectoryPath):
            try await engine.initialize(appSupportDirectory: URL(fileURLWithPath: appSupportDirectoryPath))
            return .snapshot(engine.snapshot)
        case .ping:
            return .bool(try await engine.ping())
        case .loadModel(let id):
            try await engine.loadModel(id: id)
            return .void
        case .unloadModel:
            try await engine.unloadModel()
            return .void
        case .ensureModelLoadedIfNeeded(let id):
            await engine.ensureModelLoadedIfNeeded(id: id)
            return .void
        case .prewarmModelIfNeeded(let request):
            await engine.prewarmModelIfNeeded(for: request)
            return .void
        case .ensureCloneReferencePrimed(let modelID, let reference):
            try await engine.ensureCloneReferencePrimed(modelID: modelID, reference: reference)
            return .void
        case .cancelClonePreparationIfNeeded:
            await engine.cancelClonePreparationIfNeeded()
            return .void
        case .generate(let request):
            return .generationResult(try await engine.generate(request))
        case .generateBatch(let commandID, let requests):
            let results = try await engine.generateBatch(
                requests,
                progressHandler: { [weak self] fraction, message in
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
            )
            return .generationResults(results)
        case .cancelActiveGeneration:
            try await engine.cancelActiveGeneration()
            return .void
        case .listPreparedVoices:
            return .preparedVoices(try await engine.listPreparedVoices())
        case .enrollPreparedVoice(let name, let audioPath, let transcript):
            return .preparedVoice(
                try await engine.enrollPreparedVoice(
                    name: name,
                    audioPath: audioPath,
                    transcript: transcript
                )
            )
        case .deletePreparedVoice(let id):
            try await engine.deletePreparedVoice(id: id)
            return .void
        case .clearGenerationActivity:
            engine.clearGenerationActivity()
            return .void
        case .clearVisibleError:
            engine.clearVisibleError()
            return .void
        }
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
        Task {
            try? await engine.cancelActiveGeneration()
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
        guard let payload = try? EngineServiceCodec.encode(event) else { return }
        eventSink.handleEvent(payload)
    }
}
