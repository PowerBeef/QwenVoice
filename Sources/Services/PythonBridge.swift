import Foundation

struct GenerationChunkNotification {
    let requestID: Int
    let chunkIndex: Int
    let chunkPath: String
    let isFinal: Bool
}

/// Manages a long-lived Python subprocess running server.py,
/// communicating via JSON-RPC 2.0 over stdin/stdout pipes.
@MainActor
final class PythonBridge: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isReady = false
    @Published private(set) var isProcessing = false
    @Published private(set) var progressPercent: Int = 0
    @Published private(set) var progressMessage: String = ""
    @Published private(set) var lastError: String?

    // MARK: - Private

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var requestID = 0
    private var pendingRequests: [Int: CheckedContinuation<RPCValue, Error>] = [:]
    private var generationChunkHandlers: [Int: (GenerationChunkNotification) -> Void] = [:]
    private var readBuffer = ""

    // MARK: - Lifecycle

    /// Start the Python backend process.
    /// - Parameter pythonPath: Explicit path to the Python interpreter. If nil, uses `findPython()`.
    func start(pythonPath: String? = nil) {
        guard process == nil else { return }

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
                self?.isReady = false
                self?.isProcessing = false
                self?.cancelAllPending(error: PythonBridgeError.processTerminated)
            }
        }

        do {
            try proc.run()
        } catch {
            process = nil
            stdinPipe = nil
            stdoutPipe = nil
            stderrPipe = nil
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
        cancelAllPending(error: PythonBridgeError.processTerminated)

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

    /// Send a JSON-RPC request and await the result (returns the raw RPCValue).
    func call(
        _ method: String,
        params: [String: RPCValue] = [:],
        onGenerationChunk: ((GenerationChunkNotification) -> Void)? = nil
    ) async throws -> RPCValue {
        guard process?.isRunning == true else {
            throw PythonBridgeError.processNotRunning
        }

        requestID += 1
        let id = requestID

        let request = RPCRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)

        guard var line = String(data: data, encoding: .utf8) else {
            throw PythonBridgeError.encodingError
        }
        line += "\n"

        guard let lineData = line.data(using: .utf8) else {
            throw PythonBridgeError.encodingError
        }

        isProcessing = true
        progressPercent = 0
        progressMessage = ""
        lastError = nil

        let timeout = method == "ping" ? Self.pingTimeout : Self.defaultTimeout

        return try await withThrowingTaskGroup(of: RPCValue.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.pendingRequests[id] = continuation
                    if let onGenerationChunk {
                        self.generationChunkHandlers[id] = onGenerationChunk
                    }
                    guard let pipe = self.stdinPipe else {
                        self.pendingRequests.removeValue(forKey: id)
                        self.generationChunkHandlers.removeValue(forKey: id)
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
                generationChunkHandlers.removeValue(forKey: id)
            }

            guard let result = try await group.next() else {
                throw PythonBridgeError.timeout(seconds: Int(timeout))
            }
            return result
        }
    }

    /// Send a JSON-RPC request expecting a dict result.
    func callDict(
        _ method: String,
        params: [String: RPCValue] = [:],
        onGenerationChunk: ((GenerationChunkNotification) -> Void)? = nil
    ) async throws -> [String: RPCValue] {
        let result = try await call(method, params: params, onGenerationChunk: onGenerationChunk)
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
        _ = try await callDict("init", params: [
            "app_support_dir": .string(appSupportDir)
        ])
    }

    /// Ping the backend to check it's alive.
    func ping() async throws -> Bool {
        let result = try await callDict("ping")
        return result["status"]?.stringValue == "ok"
    }

    /// Load a model by its ID (e.g. "pro_custom").
    func loadModel(id: String) async throws {
        _ = try await callDict("load_model", params: [
            "model_id": .string(id)
        ])
    }

    /// Unload the current model.
    func unloadModel() async throws {
        _ = try await callDict("unload_model")
    }

    /// Generate audio with custom voice mode.
    func generateCustom(text: String, voice: String, emotion: String, speed: Double,
                        outputPath: String, temperature: Double? = nil,
                        maxTokens: Int? = nil) async throws -> GenerationResult {
        var params: [String: RPCValue] = [
            "text": .string(text),
            "voice": .string(voice),
            "instruct": .string(emotion),
            "speed": .double(speed),
            "output_path": .string(outputPath),
        ]
        if let temperature { params["temperature"] = .double(temperature) }
        if let maxTokens { params["max_tokens"] = .int(maxTokens) }
        let result = try await callDict("generate", params: params)
        return GenerationResult(from: result)
    }

    /// Generate audio with voice design mode.
    func generateDesign(text: String, voiceDescription: String, outputPath: String,
                        temperature: Double? = nil, maxTokens: Int? = nil) async throws -> GenerationResult {
        var params: [String: RPCValue] = [
            "text": .string(text),
            "instruct": .string(voiceDescription),
            "output_path": .string(outputPath),
        ]
        if let temperature { params["temperature"] = .double(temperature) }
        if let maxTokens { params["max_tokens"] = .int(maxTokens) }
        let result = try await callDict("generate", params: params)
        return GenerationResult(from: result)
    }

    /// Generate audio with voice cloning mode.
    func generateClone(text: String, refAudio: String, refText: String?, outputPath: String,
                       temperature: Double? = nil, maxTokens: Int? = nil) async throws -> GenerationResult {
        var params: [String: RPCValue] = [
            "text": .string(text),
            "ref_audio": .string(refAudio),
            "output_path": .string(outputPath),
        ]
        if let refText, !refText.isEmpty {
            params["ref_text"] = .string(refText)
        }
        if let temperature { params["temperature"] = .double(temperature) }
        if let maxTokens { params["max_tokens"] = .int(maxTokens) }
        let result = try await callDict("generate", params: params)
        return GenerationResult(from: result)
    }

    /// Generate audio with custom voice mode while streaming chunk previews.
    func generateCustomStreaming(
        text: String,
        voice: String,
        emotion: String,
        speed: Double,
        outputPath: String,
        streamingInterval: Double = 2.0,
        onChunk: @escaping (GenerationChunkNotification) -> Void
    ) async throws -> GenerationResult {
        let result = try await callDict("generate", params: [
            "text": .string(text),
            "voice": .string(voice),
            "instruct": .string(emotion),
            "speed": .double(speed),
            "output_path": .string(outputPath),
            "stream": .bool(true),
            "streaming_interval": .double(streamingInterval),
        ], onGenerationChunk: onChunk)
        return GenerationResult(from: result)
    }

    /// Generate audio with voice design mode while streaming chunk previews.
    func generateDesignStreaming(
        text: String,
        voiceDescription: String,
        outputPath: String,
        streamingInterval: Double = 2.0,
        onChunk: @escaping (GenerationChunkNotification) -> Void
    ) async throws -> GenerationResult {
        let result = try await callDict("generate", params: [
            "text": .string(text),
            "instruct": .string(voiceDescription),
            "output_path": .string(outputPath),
            "stream": .bool(true),
            "streaming_interval": .double(streamingInterval),
        ], onGenerationChunk: onChunk)
        return GenerationResult(from: result)
    }

    /// List enrolled voices.
    func listVoices() async throws -> [Voice] {
        let items = try await callArray("list_voices")
        return items.compactMap { item -> Voice? in
            guard let obj = item.objectValue else { return nil }
            return Voice(from: obj)
        }
    }

    /// Enroll a new voice.
    func enrollVoice(name: String, audioPath: String, transcript: String?) async throws {
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
        _ = try await callDict("delete_voice", params: ["name": .string(name)])
    }

    /// Get model info (download status, sizes).
    func getModelInfo() async throws -> [[String: RPCValue]] {
        let items = try await callArray("get_model_info")
        return items.compactMap { $0.objectValue }
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
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                #if DEBUG
                print("[Python stderr] \(text)", terminator: "")
                #endif
            }
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
        guard let data = line.data(using: .utf8) else { return }

        guard let response = try? JSONDecoder().decode(RPCResponse.self, from: data) else {
            #if DEBUG
            print("[PythonBridge] Unparseable line: \(line)")
            #endif
            return
        }

        if response.isNotification {
            handleNotification(response)
            return
        }

        guard let id = response.id,
              let continuation = pendingRequests.removeValue(forKey: id) else { return }

        if let error = response.error {
            isProcessing = false
            progressMessage = ""
            progressPercent = 0
            lastError = error.message
            continuation.resume(throwing: PythonBridgeError.rpcError(code: error.code, message: error.message))
        } else if let result = response.result {
            isProcessing = false
            progressMessage = ""
            progressPercent = 0
            continuation.resume(returning: result)
        } else {
            isProcessing = false
            progressMessage = ""
            progressPercent = 0
            continuation.resume(returning: .null)
        }
    }

    private func handleNotification(_ response: RPCResponse) {
        switch response.method {
        case "ready":
            isReady = true
        case "progress":
            if let params = response.params {
                progressPercent = params["percent"]?.intValue ?? 0
                progressMessage = params["message"]?.stringValue ?? ""
            }
        case "generation_chunk":
            guard
                let params = response.params,
                let requestID = params["request_id"]?.intValue,
                let chunkIndex = params["chunk_index"]?.intValue,
                let chunkPath = params["chunk_path"]?.stringValue,
                let isFinal = params["is_final"]?.boolValue
            else { return }
            guard let handler = generationChunkHandlers[requestID] else { return }
            handler(
                GenerationChunkNotification(
                    requestID: requestID,
                    chunkIndex: chunkIndex,
                    chunkPath: chunkPath,
                    isFinal: isFinal
                )
            )
        default:
            break
        }
    }

    private func cancelAllPending(error: Error) {
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()
        generationChunkHandlers.removeAll()
    }

    // MARK: - Path Resolution

    private static func findServerScript() -> String? {
        // 1. App bundle
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
        let appSupportVenv = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("QwenVoice/python/bin/python3").path
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
}

// MARK: - Supporting Types

struct GenerationResult {
    let audioPath: String
    let durationSeconds: Double

    init(from result: [String: RPCValue]) {
        self.audioPath = result["audio_path"]?.stringValue ?? ""
        self.durationSeconds = result["duration_seconds"]?.doubleValue ?? 0.0
    }
}

enum PythonBridgeError: LocalizedError {
    case processNotRunning
    case processTerminated
    case encodingError
    case rpcError(code: Int, message: String)
    case timeout(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .processNotRunning:
            return "Python backend is not running"
        case .processTerminated:
            return "Python backend process terminated unexpectedly"
        case .encodingError:
            return "Failed to encode RPC request"
        case .rpcError(_, let message):
            return message
        case .timeout(let seconds):
            return "Request timed out after \(seconds) seconds"
        }
    }
}
