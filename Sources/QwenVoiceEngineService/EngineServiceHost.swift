import Combine
import Foundation
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

    private let engine = NativeMLXMacEngine()
    private var eventSink: QwenVoiceEngineClientEventXPCProtocol?
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
        newConnection.exportedInterface = NSXPCInterface(with: QwenVoiceEngineServiceXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.remoteObjectInterface = NSXPCInterface(with: QwenVoiceEngineClientEventXPCProtocol.self)
        eventSink = newConnection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            self?.eventSink = nil
        } as? QwenVoiceEngineClientEventXPCProtocol
        newConnection.invalidationHandler = { [weak self] in
            self?.eventSink = nil
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.eventSink = nil
        }
        newConnection.resume()
        publish(.snapshot(engine.snapshot))
        return true
    }

    func perform(_ payload: Data, withReply reply: @escaping (Data) -> Void) {
        let replyHandler = EngineReplyHandlerBox(reply: reply)
        Task { [payload, replyHandler] in
            let response = await handleCommandPayload(payload)
            let encodedResponse = (try? EngineServiceCodec.encode(response))
                ?? (try! EngineServiceCodec.encode(
                    EngineReply.failure(
                        RemoteErrorPayload(message: "The engine service failed to encode its reply.")
                    )
                ))
            replyHandler.reply(encodedResponse)
        }
    }

    private func handleCommandPayload(_ payload: Data) async -> EngineReply {
        do {
            let command = try EngineServiceCodec.decode(EngineCommand.self, from: payload)
            return try await perform(command)
        } catch {
            return .failure(Self.remoteErrorPayload(for: error))
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

    private func publish(_ event: EngineEventEnvelope) {
        guard let eventSink else { return }
        guard let payload = try? EngineServiceCodec.encode(event) else { return }
        eventSink.handleEvent(payload)
    }

    private static func remoteErrorPayload(for error: Error) -> RemoteErrorPayload {
        if let remoteError = error as? RemoteErrorPayload {
            return remoteError
        }
        let nsError = error as NSError
        return RemoteErrorPayload(
            message: error.localizedDescription,
            domain: nsError.domain
        )
    }
}
