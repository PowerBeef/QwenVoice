import Combine
import ExtensionFoundation
import Foundation

public enum ExtensionEngineLifecycleState: String, Codable, Equatable, Sendable {
    case idle
    case connecting
    case connected
    case interrupted
    case invalidated
    case recovering
    case failed
}

@MainActor
public final class ExtensionBackedTTSEngine: TTSEngineRuntimeControlling {
    public let modelRegistry: any ModelRegistry

    @Published public private(set) var loadState: EngineLoadState = .idle
    @Published public private(set) var clonePreparationState: ClonePreparationState = .idle
    @Published public private(set) var latestEvent: GenerationEvent?
    @Published public private(set) var lifecycleState: ExtensionEngineLifecycleState = .idle
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
            onLifecycleState: { [weak self] lifecycleState in
                Task { @MainActor [weak self] in
                    self?.applyLifecycleState(lifecycleState)
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
        lifecycleState = .idle
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

    private func applyLifecycleState(_ nextState: ExtensionEngineLifecycleState) {
        let previousState = lifecycleState
        lifecycleState = nextState

        guard nextState == .connected else { return }
        guard previousState == .interrupted || previousState == .invalidated || previousState == .recovering || previousState == .failed else {
            return
        }

        if case .crashed = loadState {
            loadState = .idle
        }
        visibleErrorMessage = nil
    }

    private static func remappedTransportError(_ error: Error) -> Error {
        guard let remoteError = error as? ExtensionRemoteErrorPayload,
              remoteError.code == .cancelled else {
            return error
        }
        return CancellationError()
    }
}
