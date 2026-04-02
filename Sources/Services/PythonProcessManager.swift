import Foundation

@MainActor
final class PythonProcessManager {
    private(set) var activePythonPath: String?
    private(set) var recentStderrLines: [String] = []

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private let maxStoredStderrLines: Int

    init(maxStoredStderrLines: Int = 20) {
        self.maxStoredStderrLines = maxStoredStderrLines
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start(
        pythonPath: String,
        serverPath: String,
        ffmpegPath: String?,
        onStdoutChunk: @escaping @MainActor (String) -> Void,
        onStderrText: @escaping @MainActor (String) -> Void,
        onTerminate: @escaping @MainActor (_ shouldReportCrash: Bool, _ lastStderrLine: String?) -> Void
    ) throws {
        guard process == nil else { return }

        recentStderrLines = []

        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = ["-u", serverPath]
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr
        proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        if let ffmpegPath {
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
                let lastStderrLine = self.recentStderrLines.last
                self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.stdinPipe = nil
                self.stdoutPipe = nil
                self.stderrPipe = nil
                self.activePythonPath = nil
                onTerminate(shouldReportCrash, lastStderrLine)
            }
        }

        try proc.run()

        process = proc
        stdinPipe = stdin
        stdoutPipe = stdout
        stderrPipe = stderr
        activePythonPath = pythonPath

        startReadingOutput(stdout, onStdoutChunk: onStdoutChunk)
        startReadingStderr(stderr, onStderrText: onStderrText)
    }

    func stop() {
        let proc = process
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        activePythonPath = nil
        recentStderrLines = []

        if let proc, proc.isRunning {
            proc.terminate()
            Task.detached {
                proc.waitUntilExit()
            }
        }
    }

    func restart(
        pythonPath: String,
        serverPath: String,
        ffmpegPath: String?,
        onStdoutChunk: @escaping @MainActor (String) -> Void,
        onStderrText: @escaping @MainActor (String) -> Void,
        onTerminate: @escaping @MainActor (_ shouldReportCrash: Bool, _ lastStderrLine: String?) -> Void
    ) async throws {
        let proc = process
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        activePythonPath = nil
        recentStderrLines = []

        if let proc, proc.isRunning {
            proc.terminate()
            await Task.detached {
                proc.waitUntilExit()
            }.value
        }

        try start(
            pythonPath: pythonPath,
            serverPath: serverPath,
            ffmpegPath: ffmpegPath,
            onStdoutChunk: onStdoutChunk,
            onStderrText: onStderrText,
            onTerminate: onTerminate
        )
    }

    func write(_ data: Data) throws {
        guard let stdinPipe else {
            throw PythonBridgeError.processNotRunning
        }
        stdinPipe.fileHandleForWriting.write(data)
    }

    func clearRecentStderr() {
        recentStderrLines = []
    }

    private func startReadingOutput(
        _ pipe: Pipe,
        onStdoutChunk: @escaping @MainActor (String) -> Void
    ) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }

            Task { @MainActor in
                onStdoutChunk(text)
            }
        }
    }

    private func startReadingStderr(
        _ pipe: Pipe,
        onStderrText: @escaping @MainActor (String) -> Void
    ) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }
            guard let self,
                  let text = String(data: data, encoding: .utf8) else {
                return
            }

            Task { @MainActor in
                self.storeStderr(text)
                onStderrText(text)
            }
        }
    }

    private func storeStderr(_ text: String) {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            recentStderrLines.append(trimmed)
        }
        if recentStderrLines.count > maxStoredStderrLines {
            recentStderrLines.removeFirst(recentStderrLines.count - maxStoredStderrLines)
        }
    }
}
