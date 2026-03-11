import Foundation

struct ActivityStatus: Equatable {
    let label: String
    let fraction: Double?
}

enum SidebarStatus: Equatable {
    case idle
    case starting
    case running(ActivityStatus)
    case error(String)
    case crashed(String)
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
    @Published private(set) var progressPercent: Int = 0
    @Published private(set) var progressMessage: String = ""
    @Published private(set) var sidebarStatus: SidebarStatus = .starting
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
    }

    private enum GenerationPhase {
        case loadingModel
        case preparing
        case generating
        case saving
    }

    private struct StreamingRequestContext {
        let mode: GenerationMode
        let title: String
    }

    private struct ActiveStreamingRequest {
        let context: StreamingRequestContext
        var streamSessionDirectory: String?
        var cumulativeDurationSeconds: Double
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<RPCValue, Error>
        let reportsErrors: Bool
    }

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var requestID = 0
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var readBuffer = ""
    private var activeProgressRequestID: Int?
    private var activeProgressMethod: String?
    private var activeGenerationSession: GenerationSession?
    private var activeStreamingRequests: [Int: ActiveStreamingRequest] = [:]
    private var sidebarStatusResetTask: Task<Void, Never>?
    private var recentStderrLines: [String] = []
    private var loadedModelID: String?
    private var prewarmedModelIDs: Set<String> = []
    private var prewarmingModelIDs: Set<String> = []
    private var stubRequestSeed = 10_000

    private static let maxStoredStderrLines = 20
    private var isStubBackendMode: Bool { UITestAutomationSupport.isStubBackendMode }

    // MARK: - Lifecycle

    /// Start the Python backend process.
    /// - Parameter pythonPath: Explicit path to the Python interpreter. If nil, uses `findPython()`.
    func start(pythonPath: String? = nil) {
        guard process == nil else { return }
        recentStderrLines = []
        loadedModelID = nil
        prewarmedModelIDs = []
        prewarmingModelIDs = []

        if isStubBackendMode {
            lastError = nil
            isReady = false
            isProcessing = false
            sidebarStatus = .starting
            return
        }

        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        guard let serverPath = Self.findServerScript() else {
            lastError = "Cannot find server.py"
            return
        }

        guard let resolvedPython = pythonPath ?? Self.findPython() else {
            lastError = "Cannot find Python interpreter"
            return
        }

        proc.executableURL = URL(fileURLWithPath: resolvedPython)
        proc.arguments = ["-u", serverPath]
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr
        proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        if let ffmpegPath = Self.findFFmpeg() {
            env["QWENVOICE_FFMPEG_PATH"] = ffmpegPath
            let ffmpegDir = URL(fileURLWithPath: ffmpegPath).deletingLastPathComponent().path
            if let currentPath = env["PATH"], !currentPath.isEmpty {
                env["PATH"] = "\(ffmpegDir):\(currentPath)"
            } else {
                env["PATH"] = ffmpegDir
            }
        }
        proc.environment = env

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let shouldReportCrash = self.process != nil
                self.isReady = false
                self.isProcessing = false
                self.activeGenerationSession = nil
                self.activeStreamingRequests.removeAll()
                self.loadedModelID = nil
                self.clearActiveProgressTracking()
                if shouldReportCrash {
                    self.lastError = self.recentStderrLines.last ?? PythonBridgeError.processTerminated.localizedDescription
                }
                self.cancelAllPending(error: PythonBridgeError.processTerminated)
            }
        }

        do {
            try proc.run()
        } catch {
            process = nil
            stdinPipe = nil
            stdoutPipe = nil
            stderrPipe = nil
            loadedModelID = nil
            isReady = false
            isProcessing = false
            lastError = "Failed to start Python: \(error.localizedDescription)"
            return
        }

        lastError = nil
        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        startReadingOutput(stdout)
        startReadingStderr(stderr)
    }

    /// Stop the Python backend process.
    func stop() {
        let proc = process
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        isReady = false
        isProcessing = false
        lastError = nil
        readBuffer = ""
        activeGenerationSession = nil
        activeStreamingRequests.removeAll()
        loadedModelID = nil
        prewarmedModelIDs = []
        prewarmingModelIDs = []
        recentStderrLines = []
        clearActiveProgressTracking()
        cancelAllPending(error: PythonBridgeError.processTerminated)

        if isStubBackendMode {
            return
        }

        if let proc, proc.isRunning {
            proc.terminate()
            Task.detached {
                proc.waitUntilExit()
            }
        }
    }

    // MARK: - RPC Calls

    /// Default timeout for RPC calls (seconds).
    private static let defaultTimeout: UInt64 = 300  // 5 minutes for generation
    private static let pingTimeout: UInt64 = 10
    private static let longRunningMethods: Set<String> = ["generate", "load_model", "unload_model", "convert_audio"]
    private static let appStreamingInterval = 0.32

    static func hasMeaningfulDeliveryInstruction(_ emotion: String) -> Bool {
        let trimmed = emotion.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.caseInsensitiveCompare("Normal tone") != .orderedSame
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

    /// Send a JSON-RPC request and await the result (returns the raw RPCValue).
    private func call(
        _ method: String,
        params: [String: RPCValue] = [:],
        streamingContext: StreamingRequestContext? = nil,
        reportsErrors: Bool = true,
        resetLastError: Bool = true
    ) async throws -> RPCValue {
        guard process?.isRunning == true else {
            throw PythonBridgeError.processNotRunning
        }

        requestID += 1
        let id = requestID

        if let streamingContext {
            activeStreamingRequests[id] = ActiveStreamingRequest(
                context: streamingContext,
                streamSessionDirectory: nil,
                cumulativeDurationSeconds: 0
            )
        }

        let request = RPCRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)

        guard var line = String(data: data, encoding: .utf8) else {
            throw PythonBridgeError.encodingError
        }
        line += "\n"

        guard let lineData = line.data(using: .utf8) else {
            throw PythonBridgeError.encodingError
        }

        let isLongRunning = Self.longRunningMethods.contains(method)
        let tracksSidebarProgress = method == "load_model" || method == "generate"
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

        return try await withThrowingTaskGroup(of: RPCValue.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.pendingRequests[id] = PendingRequest(
                        continuation: continuation,
                        reportsErrors: reportsErrors
                    )
                    guard let pipe = self.stdinPipe else {
                        self.pendingRequests.removeValue(forKey: id)
                        continuation.resume(throwing: PythonBridgeError.processNotRunning)
                        return
                    }
                    pipe.fileHandleForWriting.write(lineData)
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                throw PythonBridgeError.timeout(seconds: Int(timeout))
            }

            defer {
                group.cancelAll()
                pendingRequests.removeValue(forKey: id)
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
                    activeStreamingRequests.removeValue(forKey: id)
                }
            }

            guard let result = try await group.next() else {
                throw PythonBridgeError.timeout(seconds: Int(timeout))
            }
            return result
        }
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
            try? await Task.sleep(nanoseconds: 60_000_000)
            isReady = true
            activeStreamingRequests.removeAll()
            loadedModelID = nil
            lastError = nil
            syncSidebarStatusFromSystemState()
            return
        }

        _ = try await callDict("init", params: [
            "app_support_dir": .string(appSupportDir)
        ])
        activeStreamingRequests.removeAll()
        loadedModelID = nil
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
        if Self.canSkipLoadModel(requestedID: id, loadedModelID: loadedModelID) {
            return [
                "success": .bool(true),
                "cached": .bool(true),
                "model_id": .string(id),
            ]
        }

        if isStubBackendMode {
            guard let model = TTSModel.model(id: id) else {
                throw PythonBridgeError.rpcError(code: -32001, message: "Unknown model '\(id)'")
            }
            guard model.isAvailable(in: QwenVoiceApp.modelsDir) else {
                throw PythonBridgeError.rpcError(code: -32010, message: "Model '\(model.name)' is unavailable or incomplete.")
            }

            try? await Task.sleep(nanoseconds: 120_000_000)
            loadedModelID = id
            return stubModelLoadResult(for: model, cached: false)
        }

        let result = try await callDict("load_model", params: [
            "model_id": .string(id)
        ])
        loadedModelID = id
        return result
    }

    /// Unload the current model.
    func unloadModel() async throws {
        if isStubBackendMode {
            loadedModelID = nil
            return
        }
        _ = try await callDict("unload_model")
        loadedModelID = nil
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
        guard process?.isRunning == true || isStubBackendMode else { return }
        guard !isProcessing, activeGenerationSession == nil else { return }
        guard loadedModelID != modelID else { return }
        guard !prewarmedModelIDs.contains(modelID) else { return }
        guard !prewarmingModelIDs.contains(modelID) else { return }
        if mode == .clone && (refAudio?.isEmpty ?? true) {
            return
        }

        prewarmingModelIDs.insert(modelID)
        defer { prewarmingModelIDs.remove(modelID) }

        if isStubBackendMode {
            loadedModelID = modelID
            prewarmedModelIDs.insert(modelID)
            return
        }

        var params: [String: RPCValue] = [
            "model_id": .string(modelID),
            "mode": .string(mode.rawValue),
        ]
        if let voice, !voice.isEmpty {
            params["voice"] = .string(voice)
        }
        if let instruct, !instruct.isEmpty, Self.hasMeaningfulDeliveryInstruction(instruct) {
            params["instruct"] = .string(instruct)
        }
        if let refAudio, !refAudio.isEmpty {
            params["ref_audio"] = .string(refAudio)
        }
        if let refText, !refText.isEmpty {
            params["ref_text"] = .string(refText)
        }

        do {
            _ = try await callDict(
                "prewarm_model",
                params: params,
                reportsErrors: false,
                resetLastError: false
            )
            loadedModelID = modelID
            prewarmedModelIDs.insert(modelID)
        } catch {
            #if DEBUG
            print("[Performance][PythonBridge] prewarm_model_failed id=\(modelID) error=\(error.localizedDescription)")
            #endif
        }
    }

    func cancelActiveGenerationAndRestart(pythonPath: String, appSupportDir: String) async throws {
        if isStubBackendMode {
            cancelAllPending(error: PythonBridgeError.cancelled)
            isReady = false
            isProcessing = false
            readBuffer = ""
            activeGenerationSession = nil
            activeStreamingRequests.removeAll()
            loadedModelID = nil
            prewarmedModelIDs = []
            prewarmingModelIDs = []
            recentStderrLines = []
            lastError = nil
            clearActiveProgressTracking()
            try await initialize(appSupportDir: appSupportDir)
            clearGenerationActivity()
            return
        }

        cancelAllPending(error: PythonBridgeError.cancelled)

        let proc = process
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        isReady = false
        isProcessing = false
        readBuffer = ""
        activeGenerationSession = nil
        activeStreamingRequests.removeAll()
        loadedModelID = nil
        prewarmedModelIDs = []
        prewarmingModelIDs = []
        recentStderrLines = []
        lastError = nil
        clearActiveProgressTracking()

        if let proc, proc.isRunning {
            proc.terminate()
            await Task.detached {
                proc.waitUntilExit()
            }.value
        }

        start(pythonPath: pythonPath)
        guard process?.isRunning == true else {
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
        text: String,
        voice: String,
        emotion: String,
        speed: Double,
        outputPath: String,
        stream: Bool = false,
        streamingContext: StreamingRequestContext? = nil
    ) async throws -> GenerationResult {
        if isStubBackendMode {
            return try await generateStub(
                mode: .custom,
                text: text,
                outputPath: outputPath,
                stream: stream,
                streamingContext: streamingContext
            )
        }

        var params: [String: RPCValue] = [
            "mode": .string(GenerationMode.custom.rawValue),
            "text": .string(text),
            "voice": .string(voice),
            "instruct": .string(emotion),
            "speed": .double(speed),
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
        text: String,
        voiceDescription: String,
        emotion: String,
        speed: Double,
        outputPath: String,
        stream: Bool = false,
        streamingContext: StreamingRequestContext? = nil
    ) async throws -> GenerationResult {
        if isStubBackendMode {
            return try await generateStub(
                mode: .design,
                text: text,
                outputPath: outputPath,
                stream: stream,
                streamingContext: streamingContext
            )
        }

        var params: [String: RPCValue] = [
            "mode": .string(GenerationMode.design.rawValue),
            "text": .string(text),
            "instruct": .string(Self.designInstruction(voiceDescription: voiceDescription, emotion: emotion)),
            "speed": .double(speed),
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
        text: String,
        refAudio: String,
        refText: String?,
        emotion: String,
        speed: Double,
        outputPath: String,
        stream: Bool = false,
        streamingContext: StreamingRequestContext? = nil
    ) async throws -> GenerationResult {
        if isStubBackendMode {
            return try await generateStub(
                mode: .clone,
                text: text,
                outputPath: outputPath,
                stream: stream,
                streamingContext: streamingContext
            )
        }

        var params: [String: RPCValue] = [
            "mode": .string(GenerationMode.clone.rawValue),
            "text": .string(text),
            "ref_audio": .string(refAudio),
            "output_path": .string(outputPath),
        ]
        if let refText, !refText.isEmpty {
            params["ref_text"] = .string(refText)
        }
        if Self.hasMeaningfulDeliveryInstruction(emotion) {
            params["instruct"] = .string(emotion)
        }
        if speed != 1.0 {
            params["speed"] = .double(speed)
        }
        if stream {
            params["stream"] = .bool(true)
            params["streaming_interval"] = .double(Self.appStreamingInterval)
        }
        let result = try await callDict("generate", params: params, streamingContext: streamingContext)
        return GenerationResult(from: result)
    }

    func generateCustomFlow(
        modelID: String,
        text: String,
        voice: String,
        emotion: String,
        speed: Double,
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
                text: text,
                voice: voice,
                emotion: emotion,
                speed: speed,
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
        speed: Double,
        outputPath: String
    ) async throws -> GenerationResult {
        try await performGenerationFlow(
            mode: .custom,
            modelID: modelID,
            batchIndex: nil,
            batchTotal: nil
        ) {
            try await self.generateCustom(
                text: text,
                voice: voice,
                emotion: emotion,
                speed: speed,
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
        speed: Double,
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
                text: text,
                voiceDescription: voiceDescription,
                emotion: emotion,
                speed: speed,
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
        speed: Double,
        outputPath: String
    ) async throws -> GenerationResult {
        try await performGenerationFlow(
            mode: .design,
            modelID: modelID,
            batchIndex: nil,
            batchTotal: nil
        ) {
            try await self.generateDesign(
                text: text,
                voiceDescription: voiceDescription,
                emotion: emotion,
                speed: speed,
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
        emotion: String,
        speed: Double,
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
                text: text,
                refAudio: refAudio,
                refText: refText,
                emotion: emotion,
                speed: speed,
                outputPath: outputPath,
                stream: false
            )
        }
    }

    func generateCloneStreamingFlow(
        modelID: String,
        text: String,
        refAudio: String,
        refText: String?,
        emotion: String,
        speed: Double,
        outputPath: String
    ) async throws -> GenerationResult {
        try await performGenerationFlow(
            mode: .clone,
            modelID: modelID,
            batchIndex: nil,
            batchTotal: nil
        ) {
            try await self.generateClone(
                text: text,
                refAudio: refAudio,
                refText: refText,
                emotion: emotion,
                speed: speed,
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
        syncSidebarStatusFromSystemState()
    }

    /// List enrolled voices.
    func listVoices() async throws -> [Voice] {
        try UITestFaultInjection.throwIfEnabled(.listVoices)
        if isStubBackendMode {
            return try stubListVoices()
        }
        let items = try await callArray("list_voices")
        return items.compactMap { item -> Voice? in
            guard let obj = item.objectValue else { return nil }
            return Voice(from: obj)
        }
    }

    /// Enroll a new voice.
    func enrollVoice(name: String, audioPath: String, transcript: String?) async throws {
        if isStubBackendMode {
            try stubEnrollVoice(name: name, audioPath: audioPath, transcript: transcript)
            return
        }
        var params: [String: RPCValue] = [
            "name": .string(name),
            "audio_path": .string(audioPath),
        ]
        if let transcript, !transcript.isEmpty {
            params["transcript"] = .string(transcript)
        }
        _ = try await callDict("enroll_voice", params: params)
    }

    /// Delete an enrolled voice.
    func deleteVoice(name: String) async throws {
        if isStubBackendMode {
            try stubDeleteVoice(name: name)
            return
        }
        _ = try await callDict("delete_voice", params: ["name": .string(name)])
    }

    /// Get model info (download status, sizes).
    func getModelInfo() async throws -> [[String: RPCValue]] {
        if isStubBackendMode {
            return stubModelInfo()
        }
        let items = try await callArray("get_model_info")
        return items.compactMap { $0.objectValue }
    }

    func getSpeakers() async throws -> [String: [String]] {
        if isStubBackendMode {
            return TTSModel.speakerGroups
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

    private func performGenerationFlow(
        mode: GenerationMode,
        modelID: String,
        batchIndex: Int?,
        batchTotal: Int?,
        generate: () async throws -> GenerationResult
    ) async throws -> GenerationResult {
        beginGenerationSession(mode: mode, batchIndex: batchIndex, batchTotal: batchTotal)

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

    private func beginGenerationSession(mode: GenerationMode, batchIndex: Int?, batchTotal: Int?) {
        sidebarStatusResetTask?.cancel()
        sidebarStatusResetTask = nil
        activeGenerationSession = GenerationSession(
            mode: mode,
            batchIndex: batchIndex,
            batchTotal: batchTotal,
            currentPhase: .loadingModel,
            currentRequestID: nil
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
        sidebarStatus = .running(ActivityStatus(label: label, fraction: overallFraction))
    }

    private func phaseForProgress(method: String, message: String, mode: GenerationMode) -> GenerationPhase {
        switch method {
        case "load_model":
            return .loadingModel
        case "generate":
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
        case "generate":
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
            await MainActor.run {
                guard let self = self else { return }
                self.sidebarStatusResetTask = nil
                self.syncSidebarStatusFromSystemState()
            }
        }
    }

    // MARK: - Output Reading

    private func startReadingOutput(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }

            Task { @MainActor [weak self] in
                self?.processOutputChunk(text)
            }
        }
    }

    private func startReadingStderr(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                Task { @MainActor [weak self] in
                    self?.storeStderr(text)
                }
                #if DEBUG
                print("[Python stderr] \(text)", terminator: "")
                #endif
            }
        }
    }

    private func storeStderr(_ text: String) {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            recentStderrLines.append(trimmed)
        }
        if recentStderrLines.count > Self.maxStoredStderrLines {
            recentStderrLines.removeFirst(recentStderrLines.count - Self.maxStoredStderrLines)
        }
    }

    private func processOutputChunk(_ text: String) {
        readBuffer += text

        while let newlineIndex = readBuffer.firstIndex(of: "\n") {
            let line = String(readBuffer[readBuffer.startIndex..<newlineIndex])
            readBuffer = String(readBuffer[readBuffer.index(after: newlineIndex)...])

            if !line.isEmpty {
                processLine(line)
            }
        }
    }

    private func processLine(_ line: String) {
        guard let response = PythonBridgeLineParser.parse(line) else {
            #if DEBUG
            print("[PythonBridge] Unparseable line: \(line)")
            #endif
            return
        }

        if response.isNotification {
            guard PythonBridgeLineParser.isHandledNotification(response) else { return }
            handleNotification(response)
            return
        }

        guard let id = response.id,
              let pendingRequest = pendingRequests.removeValue(forKey: id) else { return }

        if let error = response.error {
            if pendingRequest.reportsErrors {
                lastError = error.message
            }
            pendingRequest.continuation.resume(
                throwing: PythonBridgeError.rpcError(code: error.code, message: error.message)
            )
        } else if let result = response.result {
            pendingRequest.continuation.resume(returning: result)
        } else {
            pendingRequest.continuation.resume(returning: .null)
        }
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
        case "generation_chunk":
            guard let params = response.params else { return }
            handleGenerationChunkNotification(params)
        default:
            break
        }
    }

    private func handleGenerationChunkNotification(_ params: [String: RPCValue]) {
        guard let requestID = params["request_id"]?.intValue,
              var activeStream = activeStreamingRequests[requestID],
              let chunkPath = params["chunk_path"]?.stringValue else {
            return
        }

        let streamSessionDirectory = params["stream_session_dir"]?.stringValue
        if activeStream.streamSessionDirectory == nil {
            activeStream.streamSessionDirectory = streamSessionDirectory
        }
        let chunkDuration = params["chunk_duration_seconds"]?.doubleValue ?? 0
        let cumulativeDuration = params["cumulative_duration_seconds"]?.doubleValue ?? activeStream.cumulativeDurationSeconds + chunkDuration
        activeStream.cumulativeDurationSeconds = cumulativeDuration
        activeStreamingRequests[requestID] = activeStream

        NotificationCenter.default.post(
            name: .generationChunkReceived,
            object: nil,
            userInfo: [
                "requestID": requestID,
                "mode": activeStream.context.mode.rawValue,
                "title": activeStream.context.title,
                "chunkPath": chunkPath,
                "isFinal": params["is_final"]?.boolValue ?? false,
                "chunkDurationSeconds": chunkDuration,
                "cumulativeDurationSeconds": cumulativeDuration,
                "streamSessionDirectory": activeStream.streamSessionDirectory ?? "",
            ]
        )
    }

    private func cancelAllPending(error: Error) {
        for (_, pendingRequest) in pendingRequests {
            pendingRequest.continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()
    }

    // MARK: - Path Resolution

    private static func findServerScript() -> String? {
        // 1. App bundle
        if let bundlePath = Bundle.main.path(forResource: "server", ofType: "py") {
            return bundlePath
        }
        if let bundlePath = Bundle.main.path(forResource: "server", ofType: "py", inDirectory: "backend") {
            return bundlePath
        }
        if let resourceURL = Bundle.main.resourceURL {
            let path = resourceURL.appendingPathComponent("server.py").path
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
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

    private static func findFFmpeg() -> String? {
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

    static func canSkipLoadModel(requestedID: String, loadedModelID: String?) -> Bool {
        loadedModelID == requestedID
    }

    private static func streamingTitle(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(40)).isEmpty ? "Live generation" : String(trimmed.prefix(40))
    }

    private func stubModelLoadResult(for model: TTSModel, cached: Bool) -> [String: RPCValue] {
        [
            "success": .bool(true),
            "cached": .bool(cached),
            "model_id": .string(model.id),
            "mlx_audio_version": .string("0.4.0.post1"),
            "supports_streaming": .bool(true),
            "supports_prepared_clone": .bool(model.mode == .clone),
            "supports_clone_streaming": .bool(model.mode == .clone),
            "supports_batch": .bool(true),
        ]
    }

    private func stubListVoices() throws -> [Voice] {
        let voicesDir = AppPaths.voicesDir
        guard let enumerator = FileManager.default.enumerator(at: voicesDir, includingPropertiesForKeys: nil) else {
            return []
        }

        var voices: [Voice] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "wav" else { continue }
            let transcriptURL = fileURL.deletingPathExtension().appendingPathExtension("txt")
            voices.append(
                Voice(
                    name: fileURL.deletingPathExtension().lastPathComponent,
                    wavPath: fileURL.path,
                    hasTranscript: FileManager.default.fileExists(atPath: transcriptURL.path)
                )
            )
        }

        return voices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func stubEnrollVoice(name: String, audioPath: String, transcript: String?) throws {
        let sourcePath = audioPath.isEmpty ? (UITestAutomationSupport.enrollAudioURL?.path ?? "") : audioPath
        guard !sourcePath.isEmpty, FileManager.default.fileExists(atPath: sourcePath) else {
            throw PythonBridgeError.rpcError(code: -32020, message: "Reference audio file not found.")
        }

        try FileManager.default.createDirectory(at: AppPaths.voicesDir, withIntermediateDirectories: true)
        let destination = AppPaths.voicesDir.appendingPathComponent("\(name).wav")
        let transcriptDestination = AppPaths.voicesDir.appendingPathComponent("\(name).txt")

        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.removeItem(at: transcriptDestination)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: destination)

        if let transcript, !transcript.isEmpty {
            try transcript.write(to: transcriptDestination, atomically: true, encoding: .utf8)
        }
    }

    private func stubDeleteVoice(name: String) throws {
        let wavURL = AppPaths.voicesDir.appendingPathComponent("\(name).wav")
        let transcriptURL = AppPaths.voicesDir.appendingPathComponent("\(name).txt")

        guard FileManager.default.fileExists(atPath: wavURL.path) else {
            throw PythonBridgeError.rpcError(code: -32021, message: "Voice '\(name)' does not exist.")
        }

        try FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: transcriptURL)
    }

    private func stubModelInfo() -> [[String: RPCValue]] {
        TTSModel.all.map { model in
            let installed = model.isAvailable(in: QwenVoiceApp.modelsDir)
            let size = installed ? Self.directorySize(url: model.installDirectory(in: QwenVoiceApp.modelsDir)) : 0
            return [
                "id": .string(model.id),
                "name": .string(model.name),
                "tier": .string(model.tier),
                "mode": .string(model.mode.rawValue),
                "folder": .string(model.folder),
                "output_subfolder": .string(model.outputSubfolder),
                "downloaded": .bool(installed),
                "size_bytes": .int(size),
                "mlx_audio_version": .string("0.4.0.post1"),
                "supports_streaming": .bool(true),
                "supports_prepared_clone": .bool(model.mode == .clone),
                "supports_clone_streaming": .bool(model.mode == .clone),
                "supports_batch": .bool(true),
            ]
        }
    }

    private func generateStub(
        mode: GenerationMode,
        text: String,
        outputPath: String,
        stream: Bool,
        streamingContext: StreamingRequestContext?
    ) async throws -> GenerationResult {
        let requestID = nextStubRequestID()
        let finalURL = URL(fileURLWithPath: outputPath)
        let finalDirectory = finalURL.deletingLastPathComponent()
        let streamSessionDirectory = AppPaths.appSupportDir
            .appendingPathComponent("cache/stream_sessions", isDirectory: true)
            .appendingPathComponent("stub-\(requestID)", isDirectory: true)

        try FileManager.default.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: streamSessionDirectory, withIntermediateDirectories: true)

        let sampleRate = 24_000
        let chunkDurations = [0.28, 0.32, 0.36]
        var combinedSamples: [Int16] = []
        let startedAt = Date()
        var firstChunkMs: Int?

        updateSidebarFromProgress(method: "generate", percent: 10, message: "Preparing request...")

        for (index, durationSeconds) in chunkDurations.enumerated() {
            try? await Task.sleep(nanoseconds: 250_000_000)

            let samples = Self.stubSineWave(
                sampleRate: sampleRate,
                durationSeconds: durationSeconds,
                frequency: 220 + (index * 45)
            )
            combinedSamples.append(contentsOf: samples)

            let chunkURL = streamSessionDirectory.appendingPathComponent("chunk_\(index).wav")
            try Self.writeStubWAV(
                to: chunkURL,
                samples: samples,
                sampleRate: sampleRate
            )

            if firstChunkMs == nil {
                firstChunkMs = max(1, Int(Date().timeIntervalSince(startedAt) * 1000))
            }

            let progress = min(90, 25 + (index * 25))
            updateSidebarFromProgress(method: "generate", percent: progress, message: "Streaming audio...")

            if stream, let streamingContext {
                NotificationCenter.default.post(
                    name: .generationChunkReceived,
                    object: nil,
                    userInfo: [
                        "requestID": requestID,
                        "mode": streamingContext.mode.rawValue,
                        "title": streamingContext.title,
                        "chunkPath": chunkURL.path,
                        "isFinal": index == chunkDurations.count - 1,
                        "chunkDurationSeconds": durationSeconds,
                        "cumulativeDurationSeconds": chunkDurations.prefix(index + 1).reduce(0.0, +),
                        "streamSessionDirectory": streamSessionDirectory.path,
                    ]
                )
            }
        }

        updateSidebarFromProgress(method: "generate", percent: 100, message: "Saving audio...")
        try Self.writeStubWAV(to: finalURL, samples: combinedSamples, sampleRate: sampleRate)

        return GenerationResult(
            audioPath: finalURL.path,
            durationSeconds: chunkDurations.reduce(0, +),
            streamSessionDirectory: stream ? streamSessionDirectory.path : nil,
            metrics: .init(
                tokenCount: 96,
                processingTimeSeconds: Date().timeIntervalSince(startedAt),
                peakMemoryUsage: 0.12,
                streamingUsed: stream,
                preparedCloneUsed: mode == .clone,
                cloneCacheHit: mode == .clone,
                firstChunkMs: stream ? firstChunkMs : nil
            )
        )
    }

    private func nextStubRequestID() -> Int {
        stubRequestSeed += 1
        return stubRequestSeed
    }

    private static func directorySize(url: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += size
            }
        }
        return total
    }

    private static func stubSineWave(sampleRate: Int, durationSeconds: Double, frequency: Int) -> [Int16] {
        let frameCount = max(1, Int(Double(sampleRate) * durationSeconds))
        let amplitude = 0.28
        let angularFrequency = 2.0 * Double.pi * Double(frequency)

        return (0..<frameCount).map { frame in
            let time = Double(frame) / Double(sampleRate)
            let value = sin(angularFrequency * time) * amplitude
            return Int16(max(-32767, min(32767, Int(value * Double(Int16.max)))))
        }
    }

    private static func writeStubWAV(to url: URL, samples: [Int16], sampleRate: Int) throws {
        var data = Data()
        let bytesPerSample = 2
        let dataSize = UInt32(samples.count * bytesPerSample)
        let chunkSize = UInt32(36) + dataSize

        data.append("RIFF".data(using: .ascii)!)
        data.append(littleEndianBytes(chunkSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(littleEndianBytes(UInt32(16)))
        data.append(littleEndianBytes(UInt16(1)))
        data.append(littleEndianBytes(UInt16(1)))
        data.append(littleEndianBytes(UInt32(sampleRate)))
        data.append(littleEndianBytes(UInt32(sampleRate * bytesPerSample)))
        data.append(littleEndianBytes(UInt16(bytesPerSample)))
        data.append(littleEndianBytes(UInt16(16)))
        data.append("data".data(using: .ascii)!)
        data.append(littleEndianBytes(dataSize))

        for sample in samples {
            data.append(littleEndianBytes(UInt16(bitPattern: sample)))
        }

        try data.write(to: url, options: .atomic)
    }

    private static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
        var littleEndian = value.littleEndian
        return Data(bytes: &littleEndian, count: MemoryLayout<T>.size)
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
