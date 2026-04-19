import Combine
import Foundation
@preconcurrency import MLXAudioTTS

public enum MLXTTSEngineError: LocalizedError, Equatable {
    case notInitialized
    case unknownModel(String)
    case modelUnavailable(String)
    case unsupportedRequest(String)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "The native MLX engine has not been initialized yet."
        case .unknownModel(let modelID):
            return "The native MLX engine could not find model '\(modelID)'."
        case .modelUnavailable(let message),
             .unsupportedRequest(let message),
             .generationFailed(let message):
            return message
        }
    }
}

@MainActor
public final class MLXTTSEngine: TTSEngineRuntimeControlling {
    private static let lightweightWarmupText = "Hi."
    public static var lightweightWarmupTextForUI: String { lightweightWarmupText }

    typealias StreamingSessionFactory = (
        Int,
        GenerationRequest,
        UnsafeSpeechGenerationModel,
        URL,
        EngineWarmState,
        [String: Int],
        [String: Bool],
        [String: String],
        ResolvedCloneConditioning?,
        Bool,
        NativeTelemetryRecorder?
    ) -> any NativeStreamingSessionRunning

    public let modelRegistry: any ModelRegistry
    public let modelAssetStore: any ModelAssetStore

    @Published public private(set) var loadState: EngineLoadState = .idle
    @Published public private(set) var clonePreparationState: ClonePreparationState = .idle
    @Published public private(set) var latestEvent: GenerationEvent?

    public var isReady: Bool {
        isInitialized
    }

    public var sidebarStatus: EngineLoadState {
        loadState
    }

    public private(set) var visibleErrorMessage: String?

    private let audioPreparationService: any AudioPreparationService
    private let documentIO: any DocumentIO
    private let streamSessionsDirectory: URL
    private let telemetryRecorder: NativeTelemetryRecorder?
    private let diagnosticAppSupportBox: DiagnosticAppSupportBox
    private let runtime: NativeEngineRuntime
    private let streamingSessionFactory: StreamingSessionFactory
    private var isInitialized = false
    private var appSupportDirectoryURL: URL?
    private var voicesDirectory: URL?
    private var allowsProactiveWarmOperations = true

    public convenience init(
        modelRegistry: any ModelRegistry,
        modelAssetStore: any ModelAssetStore,
        audioPreparationService: any AudioPreparationService,
        documentIO: any DocumentIO,
        hubCacheDirectory: URL,
        streamSessionsDirectory: URL,
        telemetryRecorder: NativeTelemetryRecorder? = nil,
        customPrewarmPolicy: NativeCustomPrewarmPolicy = .eager,
        qwenPreparedLoadProfile: NativeQwenPreparedLoadProfile = .fullCapabilities
    ) {
        let diagnosticAppSupportBox = DiagnosticAppSupportBox()
        let loadCoordinator = MLXModelLoadCoordinator(
            modelAssetStore: modelAssetStore,
            hubCacheDirectory: hubCacheDirectory,
            modelLoader: { descriptor, preparedMetadata in
                await Self.recordDiagnosticEvent(
                    "engine-loader-before-tts-load-model",
                    details: [
                        "descriptorID": descriptor.id,
                        "modelType": preparedMetadata.modelType ?? "",
                        "preparedDirectory": preparedMetadata.preparedDirectory.path,
                        "sourceDirectory": preparedMetadata.sourceDirectory?.path ?? "",
                        "modelRepo": descriptor.model.huggingFaceRepo,
                        "qwenPreparedLoadProfile": Self.diagnosticLabel(for: qwenPreparedLoadProfile),
                        "trustedPreparedCheckpoint": preparedMetadata.trustedPreparedCheckpoint ? "true" : "false",
                    ],
                    appSupportDirectoryURL: diagnosticAppSupportBox.url
                )
                let base = try await TTS.loadModel(
                        fromPreparedDirectory: preparedMetadata.preparedDirectory,
                        modelRepo: descriptor.model.huggingFaceRepo,
                        modelType: preparedMetadata.modelType,
                        trustPreparedCheckpoint: preparedMetadata.trustedPreparedCheckpoint,
                        qwenPreparedLoadBehavior: Self.qwenPreparedLoadBehavior(
                            for: qwenPreparedLoadProfile,
                            trustPreparedCheckpoint: preparedMetadata.trustedPreparedCheckpoint
                        ),
                        diagnosticEventSink: { action, details in
                            await Self.recordDiagnosticEvent(
                                action,
                                details: details,
                                appSupportDirectoryURL: diagnosticAppSupportBox.url
                            )
                        }
                    )
                await Self.recordDiagnosticEvent(
                    "engine-loader-after-tts-load-model",
                    details: [
                        "descriptorID": descriptor.id,
                        "modelType": preparedMetadata.modelType ?? "",
                        "preparedDirectory": preparedMetadata.preparedDirectory.path,
                        "modelRepo": descriptor.model.huggingFaceRepo,
                        "qwenPreparedLoadProfile": Self.diagnosticLabel(for: qwenPreparedLoadProfile),
                        "trustedPreparedCheckpoint": preparedMetadata.trustedPreparedCheckpoint ? "true" : "false",
                    ],
                    appSupportDirectoryURL: diagnosticAppSupportBox.url
                )
                return UnsafeSpeechGenerationModel(base: base)
            },
            telemetryRecorder: telemetryRecorder,
            diagnosticEventSink: { action, details in
                await Self.recordDiagnosticEvent(
                    action,
                    details: details,
                    appSupportDirectoryURL: diagnosticAppSupportBox.url
                )
            }
        )
        self.init(
            modelRegistry: modelRegistry,
            modelAssetStore: modelAssetStore,
            audioPreparationService: audioPreparationService,
            documentIO: documentIO,
            streamSessionsDirectory: streamSessionsDirectory,
            loadCoordinator: loadCoordinator,
            telemetryRecorder: telemetryRecorder,
            customPrewarmPolicy: customPrewarmPolicy,
            diagnosticAppSupportBox: diagnosticAppSupportBox,
            streamingSessionFactory: Self.defaultStreamingSessionFactory
        )
    }

    init(
        modelRegistry: any ModelRegistry,
        modelAssetStore: any ModelAssetStore,
        audioPreparationService: any AudioPreparationService,
        documentIO: any DocumentIO,
        streamSessionsDirectory: URL,
        loadCoordinator: any MLXModelCoordinating,
        telemetryRecorder: NativeTelemetryRecorder? = nil,
        customPrewarmPolicy: NativeCustomPrewarmPolicy = .eager,
        diagnosticAppSupportBox: DiagnosticAppSupportBox = DiagnosticAppSupportBox(),
        streamingSessionFactory: @escaping StreamingSessionFactory
    ) {
        self.modelRegistry = modelRegistry
        self.modelAssetStore = modelAssetStore
        self.audioPreparationService = audioPreparationService
        self.documentIO = documentIO
        self.streamSessionsDirectory = streamSessionsDirectory
        self.telemetryRecorder = telemetryRecorder
        self.diagnosticAppSupportBox = diagnosticAppSupportBox
        self.runtime = NativeEngineRuntime(
            loadCoordinator: loadCoordinator,
            audioPreparationService: audioPreparationService,
            lightweightWarmupText: Self.lightweightWarmupText,
            telemetryRecorder: telemetryRecorder,
            customPrewarmPolicy: customPrewarmPolicy,
            diagnosticEventSink: { action, details in
                await Self.recordDiagnosticEvent(
                    action,
                    details: details,
                    appSupportDirectoryURL: diagnosticAppSupportBox.url
                )
            }
        )
        self.streamingSessionFactory = streamingSessionFactory
    }

    public func supportDecision(for request: GenerationRequest) -> GenerationSupportDecision {
        guard request.batchIndex == nil, request.batchTotal == nil else {
            return .unsupported(reason: "Batch generation is not available in the native-only app.")
        }
        guard request.shouldStream else {
            return .unsupported(reason: "The native MLX engine currently supports streaming single-generation only.")
        }

        switch request.payload {
        case .custom, .design, .clone:
            return .supported(.nativeMLX)
        }
    }

    public func start() {}

    public func stop() {
        let runtime = runtime
        Task.detached(priority: .utility) {
            await runtime.configure(normalizedCloneReferenceDirectory: nil, voicesDirectory: nil)
            await runtime.stop()
        }
        isInitialized = false
        appSupportDirectoryURL = nil
        diagnosticAppSupportBox.url = nil
        voicesDirectory = nil
        latestEvent = nil
        loadState = .idle
        visibleErrorMessage = nil
        clonePreparationState = .idle
    }

    public func initialize(appSupportDirectory: URL) async throws {
        let voicesDirectory = appSupportDirectory.appendingPathComponent("voices", isDirectory: true)
        let normalizedCloneReferenceDirectory = appSupportDirectory.appendingPathComponent(
            "cache/normalized_clone_refs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: streamSessionsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: voicesDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: normalizedCloneReferenceDirectory,
            withIntermediateDirectories: true
        )

        appSupportDirectoryURL = appSupportDirectory
        diagnosticAppSupportBox.url = appSupportDirectory
        self.voicesDirectory = voicesDirectory
        await runtime.configure(
            normalizedCloneReferenceDirectory: normalizedCloneReferenceDirectory,
            voicesDirectory: voicesDirectory
        )
        isInitialized = true
        loadState = .idle
        clonePreparationState = .idle
    }

    public func ping() async throws -> Bool {
        isReady
    }

    public func loadModel(id: String) async throws {
        try ensureInitialized()
        do {
            loadState = .starting
            _ = try await runtime.loadModel(id: id)
            loadState = .loaded(modelID: id)
            clonePreparationState = .idle
            visibleErrorMessage = nil
        } catch {
            handle(error)
            throw error
        }
    }

    public func unloadModel() async throws {
        await runtime.unloadModel()
        loadState = .idle
        clonePreparationState = .idle
        visibleErrorMessage = nil
    }

    public func prepareAudio(_ request: AudioPreparationRequest) async throws -> AudioNormalizationResult {
        try await audioPreparationService.normalizeAudio(request)
    }

    public func ensureModelLoadedIfNeeded(id: String) async {
        do {
            _ = try await runtime.loadModel(id: id)
            loadState = .loaded(modelID: id)
        } catch {
            handle(error)
        }
    }

    public func prewarmModelIfNeeded(for request: GenerationRequest) async {
        guard allowsProactiveWarmOperations else { return }
        guard case .supported = supportDecision(for: request) else { return }
        do {
            try ensureInitialized()
            loadState = .starting
            _ = try await runtime.prepareInteractiveReadiness(for: request)
            loadState = .loaded(modelID: request.modelID)
            visibleErrorMessage = nil
        } catch {
            handle(error)
        }
    }

    @discardableResult
    public func prefetchInteractiveReadinessIfNeeded(
        for request: GenerationRequest
    ) async -> InteractivePrefetchDiagnostics? {
        guard allowsProactiveWarmOperations else { return nil }
        guard case .supported = supportDecision(for: request) else { return nil }
        do {
            try ensureInitialized()
            return try await runtime.prepareInteractiveReadiness(for: request)
        } catch {
            // Background prefetch should not interrupt the active UI with an
            // eager surfaced error. The regular generate path will still
            // report actionable failures if the model cannot be used.
            return nil
        }
    }

    public func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {
        guard allowsProactiveWarmOperations else { return }
        try ensureInitialized()

        let requestedTranscript = NativePreparedCloneConditioningCache.normalizedTranscript(
            reference.transcript
        )
        let uiIdentityKey = GenerationSemantics.cloneReferenceIdentityKey(
            modelID: modelID,
            refAudio: reference.audioPath,
            refText: requestedTranscript
        )
        clonePreparationState = ClonePreparationState(
            phase: .preparing,
            identityKey: uiIdentityKey
        )
        loadState = .running(modelID: modelID, label: "Preparing clone…", fraction: nil)

        do {
            let result = try await runtime.primeCloneReference(
                modelID: modelID,
                reference: reference
            )
            clonePreparationState = ClonePreparationState(
                phase: .primed,
                identityKey: result.uiIdentityKey
            )
            loadState = .loaded(modelID: modelID)
            visibleErrorMessage = nil
        } catch is CancellationError {
            clonePreparationState = .idle
            loadState = .loaded(modelID: modelID)
            throw CancellationError()
        } catch {
            clonePreparationState = ClonePreparationState(
                phase: .failed,
                identityKey: uiIdentityKey,
                message: error.localizedDescription
            )
            handle(error)
            throw error
        }
    }

    public func cancelClonePreparationIfNeeded() async {
        await runtime.cancelClonePreparation()
        clonePreparationState = .idle
        if case .running(let modelID, _, _) = loadState {
            loadState = modelID.map { .loaded(modelID: $0) } ?? .idle
        }
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        try ensureInitialized()
        let supportDecision = supportDecision(for: request)
        guard case .supported = supportDecision else {
            throw MLXTTSEngineError.unsupportedRequest(
                supportDecision.unsupportedReason
                    ?? "The requested generation path is not supported by the native MLX engine."
            )
        }

        do {
            await telemetryRecorder?.reset()
            loadState = .running(
                modelID: request.modelID,
                label: request.streamingTitle ?? String(request.text.prefix(40)),
                fraction: nil
            )

            let prepared = try await runtime.prepareGeneration(for: request)
            let session = streamingSessionFactory(
                prepared.requestID,
                request,
                prepared.model,
                streamSessionsDirectory,
                prepared.warmState,
                prepared.timingOverridesMS,
                prepared.booleanFlags,
                prepared.stringFlags,
                prepared.cloneConditioning,
                prepared.wasPrimed,
                telemetryRecorder
            )
            let result = try await session.run { [weak self] event in
                self?.latestEvent = event
            }
            loadState = .loaded(modelID: request.modelID)
            visibleErrorMessage = nil
            return result
        } catch {
            let surfacedError = NativeRuntimeError.wrapping(
                error,
                stage: .streamStartup,
                message: "The native runtime could not start audio generation."
            )
            handle(surfacedError)
            latestEvent = .failed(surfacedError.localizedDescription)
            throw surfacedError
        }
    }

    public func listPreparedVoices() async throws -> [PreparedVoice] {
        try ensureInitialized()
        let voicesDirectory = try requireVoicesDirectory()
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: voicesDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        var voices: [PreparedVoice] = []
        for fileURL in (enumerator.allObjects as? [URL]) ?? [] {
            guard fileURL.pathExtension.lowercased() == "wav" else { continue }
            let transcriptURL = fileURL.deletingPathExtension().appendingPathExtension("txt")
            voices.append(
                PreparedVoice(
                    id: fileURL.deletingPathExtension().lastPathComponent,
                    name: fileURL.deletingPathExtension().lastPathComponent,
                    audioPath: fileURL.path,
                    hasTranscript: fileManager.fileExists(atPath: transcriptURL.path)
                )
            )
        }

        return voices.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public func enrollPreparedVoice(
        name: String,
        audioPath: String,
        transcript: String?
    ) async throws -> PreparedVoice {
        try ensureInitialized()
        let voicesDirectory = try requireVoicesDirectory()
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: audioPath)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw MLXTTSEngineError.generationFailed("Reference audio file not found.")
        }

        let safeName = NativeSavedVoiceNaming.normalizedName(name)
        guard !safeName.isEmpty else {
            throw MLXTTSEngineError.generationFailed("Invalid saved voice name.")
        }

        try fileManager.createDirectory(at: voicesDirectory, withIntermediateDirectories: true)
        let audioDestinationURL = voicesDirectory.appendingPathComponent("\(safeName).wav")
        let transcriptDestinationURL = voicesDirectory.appendingPathComponent("\(safeName).txt")

        if fileManager.fileExists(atPath: audioDestinationURL.path)
            || fileManager.fileExists(atPath: transcriptDestinationURL.path) {
            throw MLXTTSEngineError.generationFailed(
                "A saved voice named \"\(safeName)\" already exists. Choose a different name."
            )
        }

        try fileManager.copyItem(at: sourceURL, to: audioDestinationURL)
        let normalizedTranscript = NativePreparedCloneConditioningCache.normalizedTranscript(transcript)
        if let normalizedTranscript {
            try normalizedTranscript.write(
                to: transcriptDestinationURL,
                atomically: true,
                encoding: .utf8
            )
        }

        if let normalizedTranscript,
           let cloneModelID = modelRegistry.model(for: .clone)?.id {
            let runtime = runtime
            let cloneReference = CloneReference(
                audioPath: audioDestinationURL.path,
                transcript: normalizedTranscript,
                preparedVoiceID: safeName
            )
            if allowsProactiveWarmOperations {
                Task.detached(priority: .utility) {
                    await runtime.prebuildSavedVoiceClonePrompt(
                        modelID: cloneModelID,
                        reference: cloneReference
                    )
                }
            }
        }

        return PreparedVoice(
            id: safeName,
            name: safeName,
            audioPath: audioDestinationURL.path,
            hasTranscript: normalizedTranscript != nil
        )
    }

    public func deletePreparedVoice(id: String) async throws {
        try ensureInitialized()
        let voicesDirectory = try requireVoicesDirectory()
        let fileManager = FileManager.default
        let audioURL = voicesDirectory.appendingPathComponent("\(id).wav")
        let transcriptURL = voicesDirectory.appendingPathComponent("\(id).txt")

        guard fileManager.fileExists(atPath: audioURL.path) else {
            throw MLXTTSEngineError.generationFailed("Voice '\(id)' does not exist.")
        }

        try fileManager.removeItem(at: audioURL)
        if fileManager.fileExists(atPath: transcriptURL.path) {
            try? fileManager.removeItem(at: transcriptURL)
        }
        let clonePromptRootDirectory = NativePreparedCloneConditioningCache.preparedVoiceClonePromptRootDirectory(
            in: voicesDirectory,
            voiceID: id
        )
        if fileManager.fileExists(atPath: clonePromptRootDirectory.path) {
            try? fileManager.removeItem(at: clonePromptRootDirectory)
        }
    }

    public func importReferenceAudio(from sourceURL: URL) throws -> ImportedReferenceAudio {
        try documentIO.importReferenceAudio(from: sourceURL)
    }

    public func exportGeneratedAudio(from sourceURL: URL, to destinationURL: URL) throws -> ExportedDocument {
        try documentIO.exportGeneratedAudio(from: sourceURL, to: destinationURL)
    }

    public func clearGenerationActivity() {
        latestEvent = nil
        if case .running(let modelID, _, _) = loadState {
            loadState = modelID.map { .loaded(modelID: $0) } ?? .idle
        }
    }

    public func clearVisibleError() {
        visibleErrorMessage = nil
        if case .failed = loadState {
            loadState = .idle
        }
    }

    public func setVisibleError(_ message: String?) {
        visibleErrorMessage = message
        if let message {
            loadState = .failed(message: message)
        } else if case .failed = loadState {
            loadState = .idle
        }
    }

    public func setAllowsProactiveWarmOperations(_ allow: Bool) {
        allowsProactiveWarmOperations = allow
    }

    public func trimMemory(level: NativeMemoryTrimLevel, reason: String) async {
        await runtime.trimMemory(level: level, reason: reason)

        switch level {
        case .softTrim:
            break
        case .hardTrim:
            clonePreparationState = .idle
        case .fullUnload:
            loadState = .idle
            clonePreparationState = .idle
            visibleErrorMessage = nil
        }
    }

    private func requireVoicesDirectory() throws -> URL {
        guard let voicesDirectory else {
            throw MLXTTSEngineError.notInitialized
        }
        return voicesDirectory
    }

    private func ensureInitialized() throws {
        guard isInitialized else {
            throw MLXTTSEngineError.notInitialized
        }
    }

    private func handle(_ error: Error) {
        visibleErrorMessage = error.localizedDescription
        loadState = .failed(message: error.localizedDescription)
    }

    private static func defaultStreamingSessionFactory(
        requestID: Int,
        request: GenerationRequest,
        model: UnsafeSpeechGenerationModel,
        streamSessionsDirectory: URL,
        warmState: EngineWarmState,
        timingOverridesMS: [String: Int],
        booleanFlags: [String: Bool],
        stringFlags: [String: String],
        cloneConditioning: ResolvedCloneConditioning?,
        wasPrimed: Bool,
        telemetryRecorder: NativeTelemetryRecorder?
    ) -> any NativeStreamingSessionRunning {
        NativeStreamingSynthesisSession(
            requestID: requestID,
            request: request,
            model: model,
            streamSessionsDirectory: streamSessionsDirectory,
            warmState: warmState,
            timingOverridesMS: timingOverridesMS,
            booleanFlags: booleanFlags,
            stringFlags: stringFlags,
            cloneConditioning: cloneConditioning,
            wasPrimed: wasPrimed,
            telemetryRecorder: telemetryRecorder
        )
    }

    nonisolated private static func diagnosticDetailsString(from details: [String: String]) -> String {
        details
            .keys
            .sorted()
            .map { key in
                "\(key)=\(details[key] ?? "")"
            }
            .joined(separator: "\n")
    }

    nonisolated private static func diagnosticLabel(
        for profile: NativeQwenPreparedLoadProfile
    ) -> String {
        switch profile {
        case .fullCapabilities:
            return "full_capabilities"
        case .streamingOnly:
            return "streaming_only"
        }
    }

    nonisolated static func qwenPreparedLoadBehavior(
        for profile: NativeQwenPreparedLoadProfile,
        trustPreparedCheckpoint: Bool
    ) -> QwenPreparedLoadBehavior {
        switch profile {
        case .fullCapabilities:
            return QwenPreparedLoadBehavior(
                trustPreparedCheckpoint: trustPreparedCheckpoint
            )
        case .streamingOnly:
            return QwenPreparedLoadBehavior(
                trustPreparedCheckpoint: trustPreparedCheckpoint,
                loadSpeakerEncoder: false,
                loadSpeechTokenizerEncoder: false,
                skipSpeechTokenizerEval: true
            )
        }
    }

    nonisolated private static func recordDiagnosticEvent(
        _ name: String,
        details: [String: String],
        appSupportDirectoryURL: URL?
    ) async {
        // Diagnostic event recording removed — previously used for UI test automation.
    }
}

final class DiagnosticAppSupportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: URL?

    var url: URL? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
