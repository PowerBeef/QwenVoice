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

    // MARK: - Setup Logic

    private func runSetup() async {
        let fm = FileManager.default

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

        // 3. Need to set up — find system Python
        await MainActor.run { state = .settingUp(.findingPython) }

        guard let systemPython = findSystemPython() else {
            await MainActor.run {
                state = .failed(message: "Python 3.11+ not found. Install it via:\n  brew install python@3.12")
            }
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
        guard let requirementsPath = Bundle.main.path(forResource: "requirements", ofType: "txt") else {
            // Fallback: try development path
            let devPath = URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/requirements.txt").path
            if fm.fileExists(atPath: devPath) {
                await installDependencies(venvPython: venvPython, requirementsPath: devPath)
                return
            }
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
            try await runPipInstall(
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

        // Check generic python3 with version validation
        let genericPaths = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
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

    private func bundledRequirementsPath() -> String? {
        if let path = Bundle.main.path(forResource: "requirements", ofType: "txt") {
            return path
        }
        // Development fallback
        let devPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/requirements.txt").path
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }
        return nil
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
