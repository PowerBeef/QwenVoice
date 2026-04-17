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

    @Published var isReady = false {
        didSet { syncSidebarStatusFromSystemState() }
    }
    @Published var isProcessing = false
    var progressPercent: Int = 0
    var progressMessage: String = ""
    @Published var sidebarStatus: SidebarStatus = .starting
    @Published private(set) var cloneReferencePrimingPhase: CloneReferencePrimingPhase = .idle
    @Published private(set) var cloneReferencePrimingKey: String?
    @Published private(set) var cloneReferencePrimingError: String?
    @Published var lastError: String? {
        didSet { syncSidebarStatusFromSystemState() }
    }

    // MARK: - Private

    var activeAppSupportDir: String?

    private static let maxStoredStderrLines = 20
    var isStubBackendMode: Bool { UITestAutomationSupport.isStubBackendMode }
    let processManager = PythonProcessManager(maxStoredStderrLines: 20)
    let streamCoordinator = GenerationStreamCoordinator()
    let modelLoadCoordinator = ModelLoadCoordinator()
    let clonePreparationCoordinator = ClonePreparationCoordinator()
    let activityCoordinator = PythonBridgeActivityCoordinator()
    let stubTransport = StubBackendTransport()
    lazy var transport = PythonJSONRPCTransport(
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
            activityCoordinator.clearGenerationActivity()
            lastError = nil
            isReady = false
            isProcessing = false
            syncSidebarStatusFromSystemState()
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
                    self.streamCoordinator.removeAll()
                    self.modelLoadCoordinator.reset()
                    self.resetCloneReferencePrimingState()
                    self.activityCoordinator.clearGenerationActivity()
                    self.syncActivityPublishedState()
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
        streamCoordinator.removeAll()
        modelLoadCoordinator.reset()
        resetCloneReferencePrimingState()
        activityCoordinator.clearGenerationActivity()
        syncActivityPublishedState()
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
    static let appStreamingInterval = 0.32

    static func hasMeaningfulDeliveryInstruction(_ emotion: String) -> Bool {
        let trimmed = emotion.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.caseInsensitiveCompare("Normal tone") != .orderedSame
    }

    static func supportsIdlePrewarm(mode: GenerationMode) -> Bool {
        true
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

    static func designInstruction(voiceDescription: String, emotion: String) -> String {
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

    func setCloneReferencePrimingState(
        _ phase: CloneReferencePrimingPhase,
        key: String? = nil,
        error: String? = nil
    ) {
        clonePreparationCoordinator.setState(phase, key: key, error: error)
        syncCloneReferencePrimingPublishedState()
    }

    func resetCloneReferencePrimingState() {
        clonePreparationCoordinator.reset()
        syncCloneReferencePrimingPublishedState()
    }

    func syncCloneReferencePrimingPublishedState() {
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
        if isLongRunning {
            isProcessing = true
            activityCoordinator.beginRequestTracking(id: id, method: method)
            syncActivityPublishedState()
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
            activityCoordinator.finishRequestTracking(id: id)
            syncActivityPublishedState()
            if streamingContext != nil {
                streamCoordinator.remove(requestID: id)
            }
            throw error
        }

        isProcessing = false
        activityCoordinator.finishRequestTracking(id: id)
        syncActivityPublishedState()
        if streamingContext != nil {
            streamCoordinator.remove(requestID: id)
        }
        return result
    }

    /// Send a JSON-RPC request expecting a dict result.
    func callDict(
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

    // MARK: - Path Resolution

    nonisolated static func findServerScript() -> String? {
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

    nonisolated static func findFFmpeg() -> String? {
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

    nonisolated static func findPython() -> String? {
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

    static func streamingTitle(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(40)).isEmpty ? "Live generation" : String(trimmed.prefix(40))
    }

    func generationResults(from items: [RPCValue]) throws -> [GenerationResult] {
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
