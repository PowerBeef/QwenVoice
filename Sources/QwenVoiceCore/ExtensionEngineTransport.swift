import ExtensionFoundation
import Foundation

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

final class PendingExtensionRequestBox: @unchecked Sendable {
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

final class AppExtensionProcessTransport: NSObject, ExtensionEngineTransporting, @unchecked Sendable {
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
