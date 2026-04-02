import Foundation

struct ActivityStatus: Equatable {
    enum Presentation: Equatable {
        case standaloneCard
        case inlinePlayer
    }

    let label: String
    let fraction: Double?
    let presentation: Presentation
}

enum SidebarStatus: Equatable {
    case idle
    case starting
    case running(ActivityStatus)
    case error(String)
    case crashed(String)
}

enum CloneReferencePrimingPhase: String, Equatable {
    case idle
    case preparing
    case primed
    case failed
}

/// Manages a long-lived Python subprocess running server.py,
/// communicating via JSON-RPC 2.0 over stdin/stdout pipes.
@MainActor
final class PythonBridge: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isReady = false {
        didSet { syncSidebarStatusFromSystemState() }
    }
    @Published private(set) var isProcessing = false
    private(set) var progressPercent: Int = 0
    private(set) var progressMessage: String = ""
    @Published private(set) var sidebarStatus: SidebarStatus = .starting
    @Published private(set) var cloneReferencePrimingPhase: CloneReferencePrimingPhase = .idle
    @Published private(set) var cloneReferencePrimingKey: String?
    @Published private(set) var cloneReferencePrimingError: String?
    @Published var lastError: String? {
        didSet { syncSidebarStatusFromSystemState() }
    }

    // MARK: - Private

    private struct GenerationSession {
        var mode: GenerationMode
        var batchIndex: Int?
        var batchTotal: Int?
        var currentPhase: GenerationPhase
        var currentRequestID: Int?
        var activityPresentation: ActivityStatus.Presentation
    }

    private enum GenerationPhase {
        case loadingModel
        case preparing
        case generating
        case saving
    }
    private var activeProgressRequestID: Int?
    private var activeProgressMethod: String?
    private var activeCloneBatchProgressHandler: ((Double?, String) -> Void)?
    private var activeGenerationSession: GenerationSession?
    private var sidebarStatusResetTask: Task<Void, Never>?
    private var activeAppSupportDir: String?

    private static let maxStoredStderrLines = 20
    private var isStubBackendMode: Bool { UITestAutomationSupport.isStubBackendMode }
    private let processManager = PythonProcessManager(maxStoredStderrLines: 20)
    private let streamCoordinator = GenerationStreamCoordinator()
    private let modelLoadCoordinator = ModelLoadCoordinator()
    private let clonePreparationCoordinator = ClonePreparationCoordinator()
    private let stubTransport = StubBackendTransport()
    private lazy var transport = PythonJSONRPCTransport(
        runningCheck: { [weak self] in
            self?.processManager.isRunning == true
        },
        writeData: { [weak self] data in
            guard let self else {
                throw PythonBridgeError.processNotRunning
            }
            try self.processManager.write(data)
        },
        notificationHandler: { [weak self] response in
            self?.handleNotification(response)
        },
        errorReporter: { [weak self] message in
            self?.lastError = message
        }
    )

    // MARK: - Lifecycle

    /// Start the Python backend process.
    /// - Parameter pythonPath: Explicit path to the Python interpreter. If nil, uses `findPython()`.
    func start(pythonPath: String? = nil) {
        guard !processManager.isRunning else { return }
        processManager.clearRecentStderr()
        modelLoadCoordinator.reset()
        resetCloneReferencePrimingState()

        if isStubBackendMode {
            lastError = nil
            isReady = false
            isProcessing = false
            sidebarStatus = .starting
            return
        }

        guard let serverPath = Self.findServerScript() else {
            lastError = "Cannot find server.py"
            return
        }

        guard let resolvedPython = pythonPath ?? Self.findPython() else {
            lastError = "Cannot find Python interpreter"
            return
        }

        do {
            try processManager.start(
                pythonPath: resolvedPython,
                serverPath: serverPath,
                ffmpegPath: Self.findFFmpeg(),
                onStdoutChunk: { [weak self] text in
                    self?.transport.processOutputChunk(text)
                },
                onStderrText: { text in
                    #if DEBUG
                    print("[Python stderr] \(text)", terminator: "")
                    #endif
                },
                onTerminate: { [weak self] shouldReportCrash, lastStderrLine in
                    guard let self else { return }
                    self.isReady = false
                    self.isProcessing = false
                    self.activeGenerationSession = nil
                    self.streamCoordinator.removeAll()
                    self.modelLoadCoordinator.reset()
                    self.resetCloneReferencePrimingState()
                    self.clearActiveProgressTracking()
                    if shouldReportCrash {
                        self.lastError = lastStderrLine ?? PythonBridgeError.processTerminated.localizedDescription
                    }
                    self.transport.cancelAllPending(error: PythonBridgeError.processTerminated)
                    self.transport.reset()
                }
            )
        } catch {
            isReady = false
            isProcessing = false
            lastError = "Failed to start Python: \(error.localizedDescription)"
            return
        }

        lastError = nil
    }

    /// Stop the Python backend process.
    func stop() {
        processManager.stop()
        isReady = false
        isProcessing = false
        lastError = nil
        activeGenerationSession = nil
        activeCloneBatchProgressHandler = nil
        streamCoordinator.removeAll()
        modelLoadCoordinator.reset()
        resetCloneReferencePrimingState()
        clearActiveProgressTracking()
        transport.cancelAllPending(error: PythonBridgeError.processTerminated)
        transport.reset()

        if isStubBackendMode {
            return
        }
    }

    // MARK: - RPC Calls

    /// Default timeout for RPC calls (seconds).
    private static let defaultTimeout: UInt64 = 300  // 5 minutes for generation
    private static let pingTimeout: UInt64 = 10
    private static let longRunningMethods: Set<String> = [
        "generate",
        "generate_clone_batch",
        "load_model",
        "unload_model",
        "convert_audio",
        "prepare_clone_reference",
        "prime_clone_reference",
    ]
    private static let appStreamingInterval = 0.32

    static func hasMeaningfulDeliveryInstruction(_ emotion: String) -> Bool {
        let trimmed = emotion.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.caseInsensitiveCompare("Normal tone") != .orderedSame
    }

    static func supportsIdlePrewarm(mode: GenerationMode) -> Bool {
        // Custom prewarm has not produced stable wins in shipped-path testing.
        // Keep idle prewarm focused on the modes that materially benefit from it.
        mode != .custom
    }

    static func prewarmIdentityKey(
        modelID: String,
        mode: GenerationMode,
        voice: String? = nil,
        instruct: String? = nil,
        refAudio: String? = nil,
        refText: String? = nil
    ) -> String {
        let trimmedVoice = voice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedRefAudio = refAudio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedRefText = refText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedInstruction = instruct?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedInstruction = Self.hasMeaningfulDeliveryInstruction(trimmedInstruction) ? trimmedInstruction : ""
        let identityParts: [String]

        switch mode {
        case .custom:
            identityParts = [
                modelID,
                mode.rawValue,
                trimmedVoice,
                normalizedInstruction,
            ]
        case .design:
            // Voice design prewarm only ensures the model is loaded, so emotion
            // changes should not create a new idle prewarm identity.
            identityParts = [
                modelID,
                mode.rawValue,
            ]
        case .clone:
            identityParts = [
                modelID,
                mode.rawValue,
                trimmedRefAudio,
                trimmedRefText,
            ]
        }

        return identityParts.joined(separator: "|")
    }

    static func cloneReferenceIdentityKey(
        modelID: String,
        refAudio: String,
        refText: String?
    ) -> String {
        prewarmIdentityKey(
            modelID: modelID,
            mode: .clone,
            refAudio: refAudio,
            refText: refText
        )
    }

    private static func designInstruction(voiceDescription: String, emotion: String) -> String {
        let trimmedDescription = voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmotion = emotion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.hasMeaningfulDeliveryInstruction(trimmedEmotion) else {
            return trimmedDescription
        }
        return """
        Voice description: \(trimmedDescription)
        Delivery style: \(trimmedEmotion)
        """
    }

    private func setCloneReferencePrimingState(
        _ phase: CloneReferencePrimingPhase,
        key: String? = nil,
        error: String? = nil
    ) {
        clonePreparationCoordinator.setState(phase, key: key, error: error)
        syncCloneReferencePrimingPublishedState()
    }

    private func resetCloneReferencePrimingState() {
        clonePreparationCoordinator.reset()
        syncCloneReferencePrimingPublishedState()
    }

    private func syncCloneReferencePrimingPublishedState() {
        cloneReferencePrimingPhase = clonePreparationCoordinator.phase
        cloneReferencePrimingKey = clonePreparationCoordinator.currentKey
        cloneReferencePrimingError = clonePreparationCoordinator.errorMessage
    }

    /// Send a JSON-RPC request and await the result (returns the raw RPCValue).
    private func call(
        _ method: String,
        params: [String: RPCValue] = [:],
        streamingContext: StreamingRequestContext? = nil,
        reportsErrors: Bool = true,
        resetLastError: Bool = true
    ) async throws -> RPCValue {
        guard processManager.isRunning else {
            throw PythonBridgeError.processNotRunning
        }
        let preparedRequest = try transport.makeRequest(method: method, params: params)
        let id = preparedRequest.id

        if let streamingContext {
            streamCoordinator.register(requestID: id, context: streamingContext)
        }

        let isLongRunning = Self.longRunningMethods.contains(method)
        let tracksSidebarProgress = method == "load_model"
            || method == "generate"
            || method == "generate_clone_batch"
        if isLongRunning {
            isProcessing = true
            progressPercent = 0
            progressMessage = ""
        }
        if tracksSidebarProgress {
            activeProgressRequestID = id
            activeProgressMethod = method
            if var session = activeGenerationSession {
                session.currentRequestID = id
                activeGenerationSession = session
            }
        }
        if resetLastError {
            lastError = nil
        }

        let timeout = method == "ping" ? Self.pingTimeout : Self.defaultTimeout

        let result: RPCValue
        do {
            result = try await transport.execute(
                preparedRequest,
                reportsErrors: reportsErrors,
                timeout: timeout
            )
        } catch {
            isProcessing = false
            progressPercent = 0
            progressMessage = ""
            if activeProgressRequestID == id {
                clearActiveProgressTracking()
            }
            if var session = activeGenerationSession, session.currentRequestID == id {
                session.currentRequestID = nil
                activeGenerationSession = session
            }
            if streamingContext != nil {
                streamCoordinator.remove(requestID: id)
            }
            throw error
        }

        isProcessing = false
        progressPercent = 0
        progressMessage = ""
        if activeProgressRequestID == id {
            clearActiveProgressTracking()
        }
        if var session = activeGenerationSession, session.currentRequestID == id {
            session.currentRequestID = nil
            activeGenerationSession = session
        }
        if streamingContext != nil {
            streamCoordinator.remove(requestID: id)
        }
        return result
    }

    /// Send a JSON-RPC request expecting a dict result.
    private func callDict(
        _ method: String,
        params: [String: RPCValue] = [:],
        streamingContext: StreamingRequestContext? = nil,
        reportsErrors: Bool = true,
        resetLastError: Bool = true
    ) async throws -> [String: RPCValue] {
        let result = try await call(
            method,
            params: params,
            streamingContext: streamingContext,
            reportsErrors: reportsErrors,
            resetLastError: resetLastError
        )
        return result.objectValue ?? [:]
    }

    /// Send a JSON-RPC request expecting an array result.
    func callArray(_ method: String, params: [String: RPCValue] = [:]) async throws -> [RPCValue] {
        let result = try await call(method, params: params)
        return result.arrayValue ?? []
    }

    // MARK: - Convenience Methods

    /// Initialize the backend with app paths.
    func initialize(appSupportDir: String) async throws {
        if isStubBackendMode {
            try await stubTransport.initialize()
            isReady = true
            streamCoordinator.removeAll()
            modelLoadCoordinator.reset()
            activeAppSupportDir = appSupportDir
            lastError = nil
            syncSidebarStatusFromSystemState()
            return
        }

        _ = try await callDict("init", params: [
            "app_support_dir": .string(appSupportDir)
        ])
        streamCoordinator.removeAll()
        modelLoadCoordinator.reset()
        activeAppSupportDir = appSupportDir
    }

    /// Ping the backend to check it's alive.
    func ping() async throws -> Bool {
        if isStubBackendMode {
            return true
        }
        let result = try await callDict("ping")
        return result["status"]?.stringValue == "ok"
    }

    /// Load a model by its ID (e.g. "pro_custom").
    func loadModel(id: String) async throws -> [String: RPCValue] {
        try await loadModel(id: id, reportsErrors: true, resetLastError: true)
    }

    private func loadModel(
        id: String,
        reportsErrors: Bool,
        resetLastError: Bool
    ) async throws -> [String: RPCValue] {
        try await modelLoadCoordinator.loadModel(id: id) {
            if self.isStubBackendMode {
                return try await self.stubTransport.loadModel(id: id)
            }

            return try await self.callDict(
                "load_model",
                params: [
                    "model_id": .string(id)
                ],
                reportsErrors: reportsErrors,
                resetLastError: resetLastError
            )
        }
    }

    func ensureModelLoadedIfNeeded(id: String) async {
        guard isReady else { return }
        guard processManager.isRunning || isStubBackendMode else { return }
        guard activeGenerationSession == nil else { return }
        guard !modelLoadCoordinator.canSkipLoadModel(requestedID: id) else { return }

        if isProcessing, modelLoadCoordinator.currentLoadedModelID != id {
            return
        }

        do {
            _ = try await loadModel(id: id, reportsErrors: false, resetLastError: false)
        } catch {
            #if DEBUG
            print("[Performance][PythonBridge] ensure_model_loaded_failed id=\(id) error=\(error.localizedDescription)")
            #endif
        }
    }

    /// Unload the current model.
    func unloadModel() async throws {
        if isStubBackendMode {
            modelLoadCoordinator.markUnloaded()
            return
        }
        _ = try await callDict("unload_model")
        modelLoadCoordinator.markUnloaded()
    }

    func prewarmModelIfNeeded(
        modelID: String,
        mode: GenerationMode,
        voice: String? = nil,
        instruct: String? = nil,
        refAudio: String? = nil,
        refText: String? = nil
    ) async {
        guard isReady else { return }
        guard processManager.isRunning || isStubBackendMode else { return }
        guard !isProcessing, activeGenerationSession == nil else { return }
        guard Self.supportsIdlePrewarm(mode: mode) else { return }
        if mode == .clone && (refAudio?.isEmpty ?? true) {
            return
        }

        let prewarmKey = Self.prewarmIdentityKey(
            modelID: modelID,
            mode: mode,
            voice: voice,
            instruct: instruct,
            refAudio: refAudio,
            refText: refText
        )

        let didPrewarm = await modelLoadCoordinator.prewarmIfNeeded(key: prewarmKey) {
            if self.isStubBackendMode {
                self.modelLoadCoordinator.markLoadedModel(id: modelID)
                return
            }

            var params: [String: RPCValue] = [
                "model_id": .string(modelID),
                "mode": .string(mode.rawValue),
            ]
            switch mode {
            case .custom:
                if let voice, !voice.isEmpty {
                    params["voice"] = .string(voice)
                }
                if let instruct, !instruct.isEmpty, Self.hasMeaningfulDeliveryInstruction(instruct) {
                    params["instruct"] = .string(instruct)
                }
            case .design:
                break
            case .clone:
                if let refAudio, !refAudio.isEmpty {
                    params["ref_audio"] = .string(refAudio)
                }
                if let refText, !refText.isEmpty {
                    params["ref_text"] = .string(refText)
                }
            }

            _ = try await self.callDict(
                "prewarm_model",
                params: params,
                reportsErrors: false,
                resetLastError: false
            )
            self.modelLoadCoordinator.markLoadedModel(id: modelID)
        }

        if didPrewarm {
            modelLoadCoordinator.markLoadedModel(id: modelID)
        }
    }

    func cancelCloneReferencePrimingIfNeeded() async {
        guard cloneReferencePrimingPhase == .preparing else { return }
        guard let pythonPath = processManager.activePythonPath,
              let appSupportDir = activeAppSupportDir else {
            resetCloneReferencePrimingState()
            return
        }

        do {
            try await cancelActiveGenerationAndRestart(
                pythonPath: pythonPath,
                appSupportDir: appSupportDir
            )
        } catch {
            setCloneReferencePrimingState(
                .failed,
                key: cloneReferencePrimingKey,
                error: error.localizedDescription
            )
        }
    }

    func beginCloneModelLoadIfPossible(modelID: String) {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelID.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            await self.ensureModelLoadedIfNeeded(id: trimmedModelID)
        }
    }

    func ensureCloneReferencePrimed(
        modelID: String,
        refAudio: String,
        refText: String?
    ) async throws {
        let trimmedRefAudio = refAudio.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRefAudio.isEmpty else { return }
        guard isReady else { return }
        guard processManager.isRunning || isStubBackendMode else { return }
        guard activeGenerationSession == nil else { return }

        let key = Self.cloneReferenceIdentityKey(
            modelID: modelID,
            refAudio: trimmedRefAudio,
            refText: refText
        )

        if clonePreparationCoordinator.hasInFlightTask(for: key) {
            try await clonePreparationCoordinator.ensurePrimed(key: key) { [:] }
            syncCloneReferencePrimingPublishedState()
            return
        }

        if clonePreparationCoordinator.hasDifferentInFlightKey(key) {
            await cancelCloneReferencePrimingIfNeeded()
        }

        if isStubBackendMode {
            modelLoadCoordinator.markLoadedModel(id: modelID)
            setCloneReferencePrimingState(.primed, key: key)
            return
        }

        let trimmedRefText = refText?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await clonePreparationCoordinator.ensurePrimed(key: key) {
                var params: [String: RPCValue] = [
                    "model_id": .string(modelID),
                    "ref_audio": .string(trimmedRefAudio),
                    "streaming_interval": .double(Self.appStreamingInterval),
                ]
                if let trimmedRefText, !trimmedRefText.isEmpty {
                    params["ref_text"] = .string(trimmedRefText)
                }
                return try await self.callDict(
                    "prepare_clone_reference",
                    params: params,
                    reportsErrors: false,
                    resetLastError: false
                )
            }
            modelLoadCoordinator.markLoadedModel(id: modelID)
        } catch {
            syncCloneReferencePrimingPublishedState()
            throw error
        }
        syncCloneReferencePrimingPublishedState()
    }

    func cancelActiveGenerationAndRestart(pythonPath: String, appSupportDir: String) async throws {
        if isStubBackendMode {
            transport.cancelAllPending(error: PythonBridgeError.cancelled)
            isReady = false
            isProcessing = false
            activeGenerationSession = nil
            streamCoordinator.removeAll()
            modelLoadCoordinator.reset()
            lastError = nil
            resetCloneReferencePrimingState()
            clearActiveProgressTracking()
            try await initialize(appSupportDir: appSupportDir)
            clearGenerationActivity()
            return
        }

        transport.cancelAllPending(error: PythonBridgeError.cancelled)
        isReady = false
        isProcessing = false
        activeGenerationSession = nil
        activeCloneBatchProgressHandler = nil
        streamCoordinator.removeAll()
        modelLoadCoordinator.reset()
        lastError = nil
        resetCloneReferencePrimingState()
        clearActiveProgressTracking()
        transport.reset()

        guard let serverPath = Self.findServerScript() else {
            throw PythonBridgeError.restartFailed("Cannot find server.py")
        }

        do {
            try await processManager.restart(
                pythonPath: pythonPath,
                serverPath: serverPath,
                ffmpegPath: Self.findFFmpeg(),
                onStdoutChunk: { [weak self] text in
                    self?.transport.processOutputChunk(text)
                },
                onStderrText: { text in
                    #if DEBUG
                    print("[Python stderr] \(text)", terminator: "")
                    #endif
                },
                onTerminate: { [weak self] shouldReportCrash, lastStderrLine in
                    guard let self else { return }
                    self.isReady = false
                    self.isProcessing = false
                    self.activeGenerationSession = nil
                    self.streamCoordinator.removeAll()
                    self.modelLoadCoordinator.reset()
                    self.resetCloneReferencePrimingState()
                    self.clearActiveProgressTracking()
                    if shouldReportCrash {
                        self.lastError = lastStderrLine ?? PythonBridgeError.processTerminated.localizedDescription
                    }
                    self.transport.cancelAllPending(error: PythonBridgeError.processTerminated)
                    self.transport.reset()
                }
            )
        } catch {
            throw PythonBridgeError.restartFailed(lastError ?? "Failed to restart Python backend")
        }

        do {
            try await initialize(appSupportDir: appSupportDir)
            clearGenerationActivity()
        } catch {
            stop()
            throw PythonBridgeError.restartFailed(error.localizedDescription)
        }
    }

    /// Generate audio with custom voice mode.
    private func generateCustom(
        modelID: String,
        text: String,
        voice: String,
        emotion: String,
        outputPath: String,
        stream: Bool = false,
        streamingContext: StreamingRequestContext? = nil
    ) async throws -> GenerationResult {
        if isStubBackendMode {
            return try await stubTransport.generate(
                mode: .custom,
                text: text,
                outputPath: outputPath,
                stream: stream,
                streamingContext: streamingContext
            )
        }

        var params: [String: RPCValue] = [
            "model_id": .string(modelID),
            "mode": .string(GenerationMode.custom.rawValue),
            "text": .string(text),
            "voice": .string(voice),
            "instruct": .string(emotion),
            "output_path": .string(outputPath),
        ]
        if stream {
            params["stream"] = .bool(true)
            params["streaming_interval"] = .double(Self.appStreamingInterval)
        }
        let result = try await callDict("generate", params: params, streamingContext: streamingContext)
        return GenerationResult(from: result)
    }

    /// Generate audio with voice design mode.
    private func generateDesign(
        modelID: String,
        text: String,
        voiceDescription: String,
        emotion: String,
        outputPath: String,
        stream: Bool = false,
        streamingContext: StreamingRequestContext? = nil
    ) async throws -> GenerationResult {
        if isStubBackendMode {
            return try await stubTransport.generate(
                mode: .design,
                text: text,
                outputPath: outputPath,
                stream: stream,
                streamingContext: streamingContext
            )
        }

        var params: [String: RPCValue] = [
            "model_id": .string(modelID),
            "mode": .string(GenerationMode.design.rawValue),
            "text": .string(text),
            "instruct": .string(Self.designInstruction(voiceDescription: voiceDescription, emotion: emotion)),
            "output_path": .string(outputPath),
        ]
        if stream {
            params["stream"] = .bool(true)
            params["streaming_interval"] = .double(Self.appStreamingInterval)
        }
        let result = try await callDict("generate", params: params, streamingContext: streamingContext)
        return GenerationResult(from: result)
    }

    /// Generate audio with voice cloning mode.
    private func generateClone(
        modelID: String,
        text: String,
        refAudio: String,
        refText: String?,
        outputPath: String,
        stream: Bool = false,
        streamingContext: StreamingRequestContext? = nil
    ) async throws -> GenerationResult {
        if isStubBackendMode {
            return try await stubTransport.generate(
                mode: .clone,
                text: text,
                outputPath: outputPath,
                stream: stream,
                streamingContext: streamingContext
            )
        }

        var params: [String: RPCValue] = [
            "model_id": .string(modelID),
            "mode": .string(GenerationMode.clone.rawValue),
            "text": .string(text),
            "ref_audio": .string(refAudio),
            "output_path": .string(outputPath),
        ]
        if let refText, !refText.isEmpty {
            params["ref_text"] = .string(refText)
        }
        if stream {
            params["stream"] = .bool(true)
            params["streaming_interval"] = .double(Self.appStreamingInterval)
        }
        let result = try await callDict("generate", params: params, streamingContext: streamingContext)
        return GenerationResult(from: result)
    }

    private func generateCloneBatch(
        modelID: String,
        texts: [String],
        refAudio: String,
        refText: String?,
        outputPaths: [String]
    ) async throws -> [GenerationResult] {
        if isStubBackendMode {
            return try await stubTransport.generateCloneBatch(
                texts: texts,
                outputPaths: outputPaths
            )
        }

        var params: [String: RPCValue] = [
            "model_id": .string(modelID),
            "texts": .array(texts.map { .string($0) }),
            "ref_audio": .string(refAudio),
            "output_paths": .array(outputPaths.map { .string($0) }),
        ]
        if let refText, !refText.isEmpty {
            params["ref_text"] = .string(refText)
        }

        let items = try await callArray("generate_clone_batch", params: params)
        return try generationResults(from: items)
    }

    func generateCustomFlow(
        modelID: String,
        text: String,
        voice: String,
        emotion: String,
        outputPath: String,
        batchIndex: Int? = nil,
        batchTotal: Int? = nil
    ) async throws -> GenerationResult {
        try await performGenerationFlow(
            mode: .custom,
            modelID: modelID,
            batchIndex: batchIndex,
            batchTotal: batchTotal
        ) {
            try await self.generateCustom(
                modelID: modelID,
                text: text,
                voice: voice,
                emotion: emotion,
                outputPath: outputPath,
                stream: false
            )
        }
    }

    func generateCustomStreamingFlow(
        modelID: String,
        text: String,
        voice: String,
        emotion: String,
        outputPath: String
    ) async throws -> GenerationResult {
        try await performGenerationFlow(
            mode: .custom,
            modelID: modelID,
            batchIndex: nil,
            batchTotal: nil,
            activityPresentation: .inlinePlayer
        ) {
            try await self.generateCustom(
                modelID: modelID,
                text: text,
                voice: voice,
                emotion: emotion,
                outputPath: outputPath,
                stream: true,
                streamingContext: StreamingRequestContext(
                    mode: .custom,
                    title: Self.streamingTitle(for: text)
                )
            )
        }
    }

    func generateDesignFlow(
        modelID: String,
        text: String,
        voiceDescription: String,
        emotion: String,
        outputPath: String,
        batchIndex: Int? = nil,
        batchTotal: Int? = nil
    ) async throws -> GenerationResult {
        try await performGenerationFlow(
            mode: .design,
            modelID: modelID,
            batchIndex: batchIndex,
            batchTotal: batchTotal
        ) {
            try await self.generateDesign(
                modelID: modelID,
                text: text,
                voiceDescription: voiceDescription,
                emotion: emotion,
                outputPath: outputPath,
                stream: false
            )
        }
    }

    func generateDesignStreamingFlow(
        modelID: String,
        text: String,
        voiceDescription: String,
        emotion: String,
        outputPath: String
    ) async throws -> GenerationResult {
        try await performGenerationFlow(
            mode: .design,
            modelID: modelID,
            batchIndex: nil,
            batchTotal: nil,
            activityPresentation: .inlinePlayer
        ) {
            try await self.generateDesign(
                modelID: modelID,
                text: text,
                voiceDescription: voiceDescription,
                emotion: emotion,
                outputPath: outputPath,
                stream: true,
                streamingContext: StreamingRequestContext(
                    mode: .design,
                    title: Self.streamingTitle(for: text)
                )
            )
        }
    }

    func generateCloneFlow(
        modelID: String,
        text: String,
        refAudio: String,
        refText: String?,
        outputPath: String,
        batchIndex: Int? = nil,
        batchTotal: Int? = nil
    ) async throws -> GenerationResult {
        try await performGenerationFlow(
            mode: .clone,
            modelID: modelID,
            batchIndex: batchIndex,
            batchTotal: batchTotal
        ) {
            try await self.generateClone(
                modelID: modelID,
                text: text,
                refAudio: refAudio,
                refText: refText,
                outputPath: outputPath,
                stream: false
            )
        }
    }

    func generateCloneBatchFlow(
        modelID: String,
        texts: [String],
        refAudio: String,
        refText: String?,
        outputPaths: [String],
        progressHandler: ((Double?, String) -> Void)?
    ) async throws -> [GenerationResult] {
        activeCloneBatchProgressHandler = progressHandler
        defer { activeCloneBatchProgressHandler = nil }

        return try await performGenerationFlow(
            mode: .clone,
            modelID: modelID,
            batchIndex: nil,
            batchTotal: nil
        ) {
            try await self.generateCloneBatch(
                modelID: modelID,
                texts: texts,
                refAudio: refAudio,
                refText: refText,
                outputPaths: outputPaths
            )
        }
    }

    func generateCloneStreamingFlow(
        modelID: String,
        text: String,
        refAudio: String,
        refText: String?,
        outputPath: String
    ) async throws -> GenerationResult {
        try await performGenerationFlow(
            mode: .clone,
            modelID: modelID,
            batchIndex: nil,
            batchTotal: nil,
            activityPresentation: .inlinePlayer
        ) {
            try await self.generateClone(
                modelID: modelID,
                text: text,
                refAudio: refAudio,
                refText: refText,
                outputPath: outputPath,
                stream: true,
                streamingContext: StreamingRequestContext(
                    mode: .clone,
                    title: Self.streamingTitle(for: text)
                )
            )
        }
    }

    func clearGenerationActivity() {
        sidebarStatusResetTask?.cancel()
        sidebarStatusResetTask = nil
        activeGenerationSession = nil
        clearActiveProgressTracking()
        activeCloneBatchProgressHandler = nil
        syncSidebarStatusFromSystemState()
    }

    /// List enrolled voices.
    func listVoices() async throws -> [Voice] {
        try UITestFaultInjection.throwIfEnabled(.listVoices)
        if isStubBackendMode {
            return try stubTransport.listVoices()
        }
        let items = try await callArray("list_voices")
        return items.compactMap { item -> Voice? in
            guard let obj = item.objectValue else { return nil }
            return Voice(from: obj)
        }
    }

    /// Enroll a new voice.
    func enrollVoice(name: String, audioPath: String, transcript: String?) async throws -> Voice {
        if isStubBackendMode {
            return try stubTransport.enrollVoice(name: name, audioPath: audioPath, transcript: transcript)
        }
        var params: [String: RPCValue] = [
            "name": .string(name),
            "audio_path": .string(audioPath),
        ]
        if let transcript, !transcript.isEmpty {
            params["transcript"] = .string(transcript)
        }
        let response = try await callDict("enroll_voice", params: params)
        let normalizedName = response["name"]?.stringValue ?? SavedVoiceNameSanitizer.normalizedName(name)
        let wavPath = response["wav_path"]?.stringValue ?? ""
        return Voice(
            name: normalizedName,
            wavPath: wavPath,
            hasTranscript: !(transcript?.isEmpty ?? true)
        )
    }

    /// Delete an enrolled voice.
    func deleteVoice(name: String) async throws {
        if isStubBackendMode {
            try stubTransport.deleteVoice(name: name)
            return
        }
        _ = try await callDict("delete_voice", params: ["name": .string(name)])
    }

    /// Get model info (download status, sizes).
    func getModelInfo() async throws -> [[String: RPCValue]] {
        if isStubBackendMode {
            return stubTransport.modelInfo()
        }
        let items = try await callArray("get_model_info")
        return items.compactMap { $0.objectValue }
    }

    func getSpeakers() async throws -> [String: [String]] {
        if isStubBackendMode {
            return stubTransport.speakers()
        }
        let response = try await callDict("get_speakers")
        var speakers: [String: [String]] = [:]

        for (group, value) in response {
            guard let array = value.arrayValue else { continue }
            speakers[group] = array.compactMap(\.stringValue)
        }

        return speakers
    }

    // MARK: - Sidebar Status

    private func performGenerationFlow<Output>(
        mode: GenerationMode,
        modelID: String,
        batchIndex: Int?,
        batchTotal: Int?,
        activityPresentation: ActivityStatus.Presentation = .standaloneCard,
        generate: @MainActor () async throws -> Output
    ) async throws -> Output {
        beginGenerationSession(
            mode: mode,
            batchIndex: batchIndex,
            batchTotal: batchTotal,
            activityPresentation: activityPresentation
        )

        do {
            let loadStart = DispatchTime.now().uptimeNanoseconds
            let loadResult: [String: RPCValue]
            do {
                let loadSignpost = AppPerformanceSignposts.begin("Model Load")
                defer { AppPerformanceSignposts.end(loadSignpost) }
                loadResult = try await loadModel(id: modelID)
            }
            let loadElapsedMs = Int((DispatchTime.now().uptimeNanoseconds - loadStart) / 1_000_000)
            #if DEBUG
            print("[Performance][PythonBridge] mode=\(mode.rawValue) load_model_client_wall_ms=\(loadElapsedMs) cached=\(loadResult["cached"]?.boolValue == true)")
            #endif
            if loadResult["cached"]?.boolValue == true {
                updateCurrentSession(
                    phase: .preparing,
                    message: "Preparing request...",
                    requestFraction: 0.15
                )
            }

            let generateStart = DispatchTime.now().uptimeNanoseconds
            let result = try await generate()
            let generateElapsedMs = Int((DispatchTime.now().uptimeNanoseconds - generateStart) / 1_000_000)
            #if DEBUG
            print("[Performance][PythonBridge] mode=\(mode.rawValue) generate_client_wall_ms=\(generateElapsedMs)")
            #endif
            completeGenerationSession()
            return result
        } catch {
            failGenerationSession(with: error)
            throw error
        }
    }

    private func beginGenerationSession(
        mode: GenerationMode,
        batchIndex: Int?,
        batchTotal: Int?,
        activityPresentation: ActivityStatus.Presentation
    ) {
        sidebarStatusResetTask?.cancel()
        sidebarStatusResetTask = nil
        activeGenerationSession = GenerationSession(
            mode: mode,
            batchIndex: batchIndex,
            batchTotal: batchTotal,
            currentPhase: .loadingModel,
            currentRequestID: nil,
            activityPresentation: activityPresentation
        )
        lastError = nil
        updateCurrentSession(
            phase: .loadingModel,
            message: "Preparing model...",
            requestFraction: 0.0
        )
    }

    private func completeGenerationSession() {
        guard var session = activeGenerationSession else {
            syncSidebarStatusFromSystemState()
            return
        }

        clearActiveProgressTracking()

        if let batchIndex = session.batchIndex,
           let batchTotal = session.batchTotal,
           batchIndex < batchTotal {
            session.batchIndex = batchIndex + 1
            session.currentPhase = .loadingModel
            session.currentRequestID = nil
            activeGenerationSession = session
            updateCurrentSession(
                phase: .loadingModel,
                message: "Preparing model...",
                requestFraction: 0.0
            )
            return
        }

        activeGenerationSession = nil
        scheduleSidebarStatusReset()
    }

    private func failGenerationSession(with error: Error) {
        sidebarStatusResetTask?.cancel()
        sidebarStatusResetTask = nil
        activeGenerationSession = nil
        clearActiveProgressTracking()
        activeCloneBatchProgressHandler = nil
        if lastError == nil {
            lastError = error.localizedDescription
        } else {
            syncSidebarStatusFromSystemState()
        }
    }

    private func syncSidebarStatusFromSystemState() {
        sidebarStatusResetTask?.cancel()
        sidebarStatusResetTask = nil
        if let error = lastError {
            sidebarStatus = isReady ? .error(error) : .crashed(error)
            return
        }
        guard activeGenerationSession == nil else { return }
        sidebarStatus = isReady ? .idle : .starting
    }

    private func updateSidebarFromProgress(method: String, percent: Int, message: String) {
        guard let session = activeGenerationSession else { return }
        let phase = phaseForProgress(method: method, message: message, mode: session.mode)
        let requestFraction = mappedRequestFraction(method: method, percent: percent)
        updateCurrentSession(phase: phase, message: message, requestFraction: requestFraction)
    }

    private func updateCurrentSession(phase: GenerationPhase, message: String, requestFraction: Double?) {
        guard var session = activeGenerationSession else { return }
        sidebarStatusResetTask?.cancel()
        sidebarStatusResetTask = nil
        session.currentPhase = phase
        activeGenerationSession = session
        let overallFraction = overallFraction(for: session, requestFraction: requestFraction)
        let label = sidebarLabel(for: session, message: message)
        sidebarStatus = .running(
            ActivityStatus(
                label: label,
                fraction: overallFraction,
                presentation: session.activityPresentation
            )
        )
    }

    private func phaseForProgress(method: String, message: String, mode: GenerationMode) -> GenerationPhase {
        switch method {
        case "load_model":
            return .loadingModel
        case "generate", "generate_clone_batch":
            let lowercasedMessage = message.lowercased()
            if lowercasedMessage.contains("saving") || lowercasedMessage.contains("done") {
                return .saving
            }
            if lowercasedMessage.contains("generating") || lowercasedMessage.contains("streaming") {
                return .generating
            }
            if mode == .clone && (lowercasedMessage.contains("normalizing") || lowercasedMessage.contains("voice context")) {
                return .preparing
            }
            return .preparing
        default:
            return .preparing
        }
    }

    private func mappedRequestFraction(method: String, percent: Int) -> Double? {
        let clampedPercent = min(max(percent, 0), 100)
        let normalized = Double(clampedPercent) / 100.0

        switch method {
        case "load_model":
            return normalized * 0.15
        case "generate", "generate_clone_batch":
            return 0.15 + (normalized * 0.85)
        default:
            return normalized
        }
    }

    private func overallFraction(for session: GenerationSession, requestFraction: Double?) -> Double? {
        guard let requestFraction else { return nil }
        guard let batchIndex = session.batchIndex,
              let batchTotal = session.batchTotal,
              batchTotal > 0 else {
            return min(max(requestFraction, 0.0), 1.0)
        }

        let completedItems = max(batchIndex - 1, 0)
        let overall = (Double(completedItems) + requestFraction) / Double(batchTotal)
        return min(max(overall, 0.0), 1.0)
    }

    private func sidebarLabel(for session: GenerationSession, message: String) -> String {
        guard let batchIndex = session.batchIndex,
              let batchTotal = session.batchTotal else {
            return message
        }
        return "Generating \(batchIndex)/\(batchTotal): \(message)"
    }

    private func clearActiveProgressTracking() {
        activeProgressRequestID = nil
        activeProgressMethod = nil
    }

    private func scheduleSidebarStatusReset() {
        sidebarStatusResetTask?.cancel()
        sidebarStatusResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            guard let self = self else { return }
            await self.finishSidebarStatusResetIfCurrent()
        }
    }

    private func finishSidebarStatusResetIfCurrent() {
        sidebarStatusResetTask = nil
        syncSidebarStatusFromSystemState()
    }

    private func handleNotification(_ response: RPCResponse) {
        switch response.method {
        case "ready":
            isReady = true
        case "progress":
            guard let params = response.params else { return }
            let notificationRequestID = params["request_id"]?.intValue
            if let expectedRequestID = activeProgressRequestID,
               let notificationRequestID,
               notificationRequestID != expectedRequestID {
                return
            }
            progressPercent = params["percent"]?.intValue ?? 0
            progressMessage = params["message"]?.stringValue ?? ""
            guard activeGenerationSession != nil,
                  let activeProgressMethod else { return }
            updateSidebarFromProgress(
                method: activeProgressMethod,
                percent: progressPercent,
                message: progressMessage
            )
            if activeProgressMethod == "generate_clone_batch" {
                activeCloneBatchProgressHandler?(
                    Double(progressPercent) / 100.0,
                    progressMessage
                )
            }
        case "generation_chunk":
            guard let params = response.params else { return }
            streamCoordinator.handleGenerationChunkNotification(params)
        default:
            break
        }
    }

    // MARK: - Path Resolution

    private static func findServerScript() -> String? {
        // 1. App bundle: the shipped production backend lives under Resources/backend/.
        if let bundlePath = Bundle.main.path(forResource: "server", ofType: "py", inDirectory: "backend") {
            return bundlePath
        }
        if let resourceURL = Bundle.main.resourceURL {
            let path = resourceURL.appendingPathComponent("backend/server.py").path
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // 2. Development: relative to source file
        let devPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/backend/server.py").path
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }

        return nil
    }

    static func findFFmpeg() -> String? {
        if let bundlePath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) {
            return bundlePath
        }

        if let resourceURL = Bundle.main.resourceURL {
            let path = resourceURL.appendingPathComponent("ffmpeg").path
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        let devPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ffmpeg").path
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }

        return nil
    }

    static func findPython() -> String? {
        let fm = FileManager.default

        // 1. Bundled Python in app Resources (production)
        if let bundlePath = Bundle.main.path(forResource: "python3", ofType: nil, inDirectory: "python/bin") {
            return bundlePath
        }

        // 2. App Support venv (auto-created by PythonEnvironmentManager)
        let appSupportVenv = AppPaths.pythonVenvDir.appendingPathComponent("bin/python3").path
        if fm.fileExists(atPath: appSupportVenv) {
            return appSupportVenv
        }

        // 3. Dev project venv (relative to source file)
        let devVenvPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // Services/
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // project root
            .appendingPathComponent("cli/.venv/bin/python3").path
        if fm.fileExists(atPath: devVenvPath) {
            return devVenvPath
        }

        // 4. System Python
        for path in [
            "/opt/homebrew/bin/python3.13",
            "/opt/homebrew/bin/python3.14",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/usr/local/bin/python3.13",
            "/usr/local/bin/python3.14",
            "/usr/local/bin/python3.12",
            "/usr/local/bin/python3.11",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ] {
            if fm.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }

    private static func streamingTitle(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(40)).isEmpty ? "Live generation" : String(trimmed.prefix(40))
    }

    private func generationResults(from items: [RPCValue]) throws -> [GenerationResult] {
        try items.enumerated().map { index, item in
            guard let object = item.objectValue else {
                throw PythonBridgeError.rpcError(
                    code: -32002,
                    message: "Invalid clone batch response item at index \(index)."
                )
            }
            return GenerationResult(from: object)
        }
    }
}

// MARK: - Supporting Types

struct GenerationResult {
    struct Metrics {
        let tokenCount: Int?
        let processingTimeSeconds: Double?
        let peakMemoryUsage: Double?
        let streamingUsed: Bool
        let preparedCloneUsed: Bool?
        let cloneCacheHit: Bool?
        let firstChunkMs: Int?

        init(
            tokenCount: Int?,
            processingTimeSeconds: Double?,
            peakMemoryUsage: Double?,
            streamingUsed: Bool,
            preparedCloneUsed: Bool?,
            cloneCacheHit: Bool?,
            firstChunkMs: Int?
        ) {
            self.tokenCount = tokenCount
            self.processingTimeSeconds = processingTimeSeconds
            self.peakMemoryUsage = peakMemoryUsage
            self.streamingUsed = streamingUsed
            self.preparedCloneUsed = preparedCloneUsed
            self.cloneCacheHit = cloneCacheHit
            self.firstChunkMs = firstChunkMs
        }

        init?(from value: RPCValue?) {
            guard let object = value?.objectValue else { return nil }
            tokenCount = object["token_count"]?.intValue
            processingTimeSeconds = object["processing_time_seconds"]?.doubleValue
            peakMemoryUsage = object["peak_memory_usage"]?.doubleValue
            streamingUsed = object["streaming_used"]?.boolValue ?? false
            preparedCloneUsed = object["prepared_clone_used"]?.boolValue
            cloneCacheHit = object["clone_cache_hit"]?.boolValue
            firstChunkMs = object["first_chunk_ms"]?.intValue
        }
    }

    let audioPath: String
    let durationSeconds: Double
    let streamSessionDirectory: String?
    let metrics: Metrics?

    init(audioPath: String, durationSeconds: Double, streamSessionDirectory: String?, metrics: Metrics?) {
        self.audioPath = audioPath
        self.durationSeconds = durationSeconds
        self.streamSessionDirectory = streamSessionDirectory
        self.metrics = metrics
    }

    var usedStreaming: Bool {
        metrics?.streamingUsed ?? false
    }

    init(from result: [String: RPCValue]) {
        self.audioPath = result["audio_path"]?.stringValue ?? ""
        self.durationSeconds = result["duration_seconds"]?.doubleValue ?? 0.0
        self.streamSessionDirectory = result["stream_session_dir"]?.stringValue
        self.metrics = Metrics(from: result["metrics"])
    }
}

enum PythonBridgeError: LocalizedError {
    case processNotRunning
    case processTerminated
    case cancelled
    case encodingError
    case rpcError(code: Int, message: String)
    case restartFailed(String)
    case timeout(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .processNotRunning:
            return "Python backend is not running"
        case .processTerminated:
            return "Python backend process terminated unexpectedly"
        case .cancelled:
            return "Generation cancelled"
        case .encodingError:
            return "Failed to encode RPC request"
        case .rpcError(_, let message):
            return message
        case .restartFailed(let message):
            return message
        case .timeout(let seconds):
            return "Request timed out after \(seconds) seconds"
        }
    }
}
