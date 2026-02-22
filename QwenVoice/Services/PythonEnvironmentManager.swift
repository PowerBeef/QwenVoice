import Foundation
import CryptoKit

/// Manages the Python virtual environment lifecycle: check, create, install dependencies, validate.
@MainActor
final class PythonEnvironmentManager: ObservableObject {

    // MARK: - State

    enum State: Equatable {
        case checking
        case settingUp(SetupPhase)
        case ready(pythonPath: String)
        case failed(message: String)
    }

    enum SetupPhase: Equatable {
        case findingPython
        case creatingVenv
        case installingDependencies(installed: Int, total: Int)
        case updatingDependencies
    }

    @Published private(set) var state: State = .checking

    // MARK: - Paths

    private static var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("QwenVoice")
    }

    private static var venvDir: URL {
        appSupportDir.appendingPathComponent("python")
    }

    private static var venvPython: String {
        venvDir.appendingPathComponent("bin/python3").path
    }

    private static var markerFile: URL {
        venvDir.appendingPathComponent(".setup-complete")
    }

    // MARK: - Public

    func ensureEnvironment() {
        state = .checking

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runSetup()
        }
    }

    func retry() {
        ensureEnvironment()
    }

    func resetEnvironment() {
        let fm = FileManager.default
        let venvDir = Self.venvDir
        if fm.fileExists(atPath: venvDir.path) {
            try? fm.removeItem(at: venvDir)
        }
        ensureEnvironment()
    }

    // MARK: - Setup Logic

    private func runSetup() async {
        let fm = FileManager.default

        // 0. Architecture check — MLX requires Apple Silicon
        var sysInfo = utsname()
        uname(&sysInfo)
        let machine = withUnsafePointer(to: &sysInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        if !machine.starts(with: "arm64") {
            await MainActor.run {
                state = .failed(message: "Qwen Voice requires an Apple Silicon Mac (M1 or later).\nThis Mac has a \(machine) processor, which is not supported by the MLX framework.")
            }
            return
        }

        // 1. Check for bundled Python (production build)
        if let bundledPython = Bundle.main.path(forResource: "python3", ofType: nil, inDirectory: "python/bin") {
            await MainActor.run { state = .ready(pythonPath: bundledPython) }
            return
        }

        // 2. Check existing venv with valid marker
        let venvPython = Self.venvPython
        if fm.fileExists(atPath: venvPython),
           isMarkerValid() {
            await MainActor.run { state = .ready(pythonPath: venvPython) }
            return
        }

        // 2b. Venv exists but marker is stale — try incremental update first
        if fm.fileExists(atPath: venvPython),
           let reqPath = resolveRequirementsPath() {
            await MainActor.run { state = .settingUp(.updatingDependencies) }

            let pipPath = Self.venvDir.appendingPathComponent("bin/pip").path
            let totalPackages = countPackages(in: reqPath)
            do {
                try await runPipInstallWithRetry(
                    pipPath: pipPath,
                    requirementsPath: reqPath,
                    totalPackages: totalPackages
                )
                try await validateImports(pythonPath: venvPython)
                writeMarker(requirementsPath: reqPath)
                await MainActor.run { state = .ready(pythonPath: venvPython) }
                return
            } catch {
                // Incremental update failed — fall through to full recreate
            }
        }

        // 3. Need to set up — find system Python
        await MainActor.run { state = .settingUp(.findingPython) }

        guard let systemPython = findSystemPython() else {
            let brewExists = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") ||
                             FileManager.default.fileExists(atPath: "/usr/local/bin/brew")
            let message = brewExists
                ? "Python 3.11+ not found. Install it via:\n  brew install python@3.13"
                : "Python 3.11+ not found.\n\nFirst install Homebrew:\n  /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/homebrew/install/HEAD/install.sh)\"\n\nThen install Python:\n  brew install python@3.13"
            await MainActor.run { state = .failed(message: message) }
            return
        }

        // 4. Create venv
        await MainActor.run { state = .settingUp(.creatingVenv) }

        // Remove any partial venv
        let venvDir = Self.venvDir
        if fm.fileExists(atPath: venvDir.path) {
            try? fm.removeItem(at: venvDir)
        }

        // Ensure parent directory exists
        try? fm.createDirectory(at: Self.appSupportDir, withIntermediateDirectories: true)

        do {
            try await runProcess(systemPython, arguments: ["-m", "venv", venvDir.path])
        } catch {
            await MainActor.run {
                state = .failed(message: "Failed to create virtual environment:\n\(error.localizedDescription)")
            }
            return
        }

        // 5. Install dependencies
        guard let requirementsPath = resolveRequirementsPath() else {
            await MainActor.run {
                state = .failed(message: "Cannot find requirements.txt in app bundle.")
            }
            return
        }

        await installDependencies(venvPython: venvPython, requirementsPath: requirementsPath)
    }

    private func installDependencies(venvPython: String, requirementsPath: String) async {
        let totalPackages = countPackages(in: requirementsPath)
        await MainActor.run {
            state = .settingUp(.installingDependencies(installed: 0, total: totalPackages))
        }

        let pipPath = Self.venvDir.appendingPathComponent("bin/pip").path

        do {
            try await runPipInstallWithRetry(
                pipPath: pipPath,
                requirementsPath: requirementsPath,
                totalPackages: totalPackages
            )
        } catch {
            await MainActor.run {
                state = .failed(message: "Failed to install dependencies:\n\(error.localizedDescription)")
            }
            return
        }

        // Validate core imports before marking setup complete
        let pythonForValidation = venvPython.isEmpty ? Self.venvPython : venvPython
        do {
            try await validateImports(pythonPath: pythonForValidation)
        } catch {
            await MainActor.run {
                state = .failed(message: "Dependencies installed but import validation failed:\n\(error.localizedDescription)\n\nSetup will retry on next launch.")
            }
            return
        }

        // Write marker file with hash
        writeMarker(requirementsPath: requirementsPath)

        await MainActor.run {
            state = .ready(pythonPath: Self.venvPython)
        }
    }

    // MARK: - System Python Discovery

    private func findSystemPython() -> String? {
        let fm = FileManager.default

        // Check versioned Homebrew paths first (most likely on macOS)
        let versionedPaths = [
            "/opt/homebrew/bin/python3.13",
            "/opt/homebrew/bin/python3.14",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/usr/local/bin/python3.13",
            "/usr/local/bin/python3.14",
            "/usr/local/bin/python3.12",
            "/usr/local/bin/python3.11",
        ]
        for path in versionedPaths {
            if fm.fileExists(atPath: path) {
                return path
            }
        }

        // Check generic python3 with version validation.
        // /usr/bin/python3 is intentionally excluded — on macOS 14+ it's a stub
        // that may pop a GUI dialog when invoked outside a terminal.
        let genericPaths = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]
        for path in genericPaths {
            if fm.fileExists(atPath: path), validatePythonVersion(path) {
                return path
            }
        }

        return nil
    }

    private func validatePythonVersion(_ pythonPath: String) -> Bool {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = ["--version"]
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return false
        }

        guard proc.terminationStatus == 0 else { return false }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return false }

        // Parse "Python 3.X.Y"
        let components = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Python ", with: "")
            .split(separator: ".")
        guard components.count >= 2,
              components[0] == "3",
              let minor = Int(components[1]) else { return false }

        return minor >= 11 && minor <= 14
    }

    // MARK: - Process Helpers

    private func runProcess(_ executable: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let proc = Process()
            let stderr = Pipe()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = stderr

            proc.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(throwing: SetupError.commandFailed(errMsg.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }

            do {
                try proc.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func runPipInstall(pipPath: String, requirementsPath: String, totalPackages: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let proc = Process()
            let stdout = Pipe()
            let stderr = Pipe()

            proc.executableURL = URL(fileURLWithPath: pipPath)
            proc.arguments = ["install", "--progress-bar", "off", "-r", requirementsPath]
            proc.standardOutput = stdout
            proc.standardError = stderr

            nonisolated(unsafe) var installed = 0
            nonisolated(unsafe) var resumed = false

            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let text = String(data: data, encoding: .utf8) else { return }

                for line in text.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("Collecting") || trimmed.hasPrefix("Downloading") || trimmed.hasPrefix("Installing") || trimmed.hasPrefix("Successfully installed") {
                        if trimmed.hasPrefix("Collecting") {
                            installed += 1
                        }
                        let current = min(installed, totalPackages)
                        Task { @MainActor [weak self] in
                            self?.state = .settingUp(.installingDependencies(installed: current, total: totalPackages))
                        }
                    }
                }
            }

            proc.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                guard !resumed else { return }
                resumed = true
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8) ?? "pip install failed"
                    continuation.resume(throwing: SetupError.commandFailed(errMsg.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }

            do {
                try proc.run()
            } catch {
                guard !resumed else { return }
                resumed = true
                continuation.resume(throwing: error)
            }
        }
    }

    private func runPipInstallWithRetry(pipPath: String, requirementsPath: String, totalPackages: Int) async throws {
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                try await runPipInstall(
                    pipPath: pipPath,
                    requirementsPath: requirementsPath,
                    totalPackages: totalPackages
                )
                return
            } catch {
                if attempt == maxAttempts {
                    throw SetupError.commandFailed("Failed to install dependencies after \(maxAttempts) attempts:\n\(error.localizedDescription)")
                }
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Import Validation

    private func validateImports(pythonPath: String) async throws {
        let importScript = "import mlx; import mlx_audio; import transformers; import numpy; import soundfile"
        try await runProcess(pythonPath, arguments: ["-c", importScript])
    }

    // MARK: - Marker / Hashing

    private func isMarkerValid() -> Bool {
        let fm = FileManager.default
        guard let markerData = fm.contents(atPath: Self.markerFile.path),
              let markerHash = String(data: markerData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }

        // Hash the bundled requirements.txt
        guard let reqPath = bundledRequirementsPath(),
              let reqData = fm.contents(atPath: reqPath) else {
            return false
        }

        let currentHash = SHA256.hash(data: reqData).map { String(format: "%02x", $0) }.joined()
        return markerHash == currentHash
    }

    private func writeMarker(requirementsPath: String) {
        let fm = FileManager.default
        guard let reqData = fm.contents(atPath: requirementsPath) else { return }
        let hash = SHA256.hash(data: reqData).map { String(format: "%02x", $0) }.joined()
        try? hash.write(to: Self.markerFile, atomically: true, encoding: .utf8)
    }

    private func resolveRequirementsPath() -> String? {
        if let path = Bundle.main.path(forResource: "requirements", ofType: "txt") {
            return path
        }
        let devPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/requirements.txt").path
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }
        return nil
    }

    private func bundledRequirementsPath() -> String? {
        resolveRequirementsPath()
    }

    private func countPackages(in path: String) -> Int {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return 61 }
        return content.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
            .count
    }

    // MARK: - Error

    enum SetupError: LocalizedError {
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let msg): return msg
            }
        }
    }
}
