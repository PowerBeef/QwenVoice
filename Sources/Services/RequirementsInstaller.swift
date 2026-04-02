import Foundation

@MainActor
final class RequirementsInstaller {
    private let discovery: PythonRuntimeDiscovery

    init(discovery: PythonRuntimeDiscovery) {
        self.discovery = discovery
    }

    func createVirtualEnvironment(systemPython: String) async throws {
        if discovery.fileManager.fileExists(atPath: discovery.venvDir.path) {
            try? discovery.fileManager.removeItem(at: discovery.venvDir)
        }
        try? discovery.fileManager.createDirectory(
            at: discovery.appSupportDir,
            withIntermediateDirectories: true
        )
        try await runProcess(systemPython, arguments: ["-m", "venv", discovery.venvDir.path])
    }

    func installDependencies(
        venvPython: String,
        requirementsPath: String,
        vendorDir: String?,
        publishProgress: @escaping @MainActor (Int, Int) -> Void
    ) async throws {
        let totalPackages = discovery.countPackages(in: requirementsPath)
        let pipPath = discovery.venvDir.appendingPathComponent("bin/pip").path

        try await runPipInstallWithRetry(
            pipPath: pipPath,
            requirementsPath: requirementsPath,
            totalPackages: totalPackages,
            vendorDir: vendorDir,
            publishProgress: publishProgress
        )
    }

    private func runProcess(_ executable: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderr
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            process.environment = environment

            nonisolated(unsafe) var resumed = false

            process.terminationHandler = { process in
                guard !resumed else { return }
                resumed = true
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(
                        throwing: PythonEnvironmentManager.SetupError.commandFailed(
                            errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                }
            }

            do {
                try process.run()
            } catch {
                guard !resumed else { return }
                resumed = true
                continuation.resume(throwing: error)
            }
        }
    }

    private func runPipInstallWithRetry(
        pipPath: String,
        requirementsPath: String,
        totalPackages: Int,
        vendorDir: String?,
        publishProgress: @escaping @MainActor (Int, Int) -> Void
    ) async throws {
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                try await runPipInstall(
                    pipPath: pipPath,
                    requirementsPath: requirementsPath,
                    totalPackages: totalPackages,
                    vendorDir: vendorDir,
                    publishProgress: publishProgress
                )
                return
            } catch {
                if attempt == maxAttempts {
                    throw PythonEnvironmentManager.SetupError.commandFailed(
                        "Failed to install dependencies after \(maxAttempts) attempts:\n\(error.localizedDescription)"
                    )
                }
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func runPipInstall(
        pipPath: String,
        requirementsPath: String,
        totalPackages: Int,
        vendorDir: String?,
        publishProgress: @escaping @MainActor (Int, Int) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()

            process.executableURL = URL(fileURLWithPath: pipPath)
            var pipArgs = ["install", "--progress-bar", "off"]
            if let vendorDir {
                pipArgs += ["--find-links", vendorDir]
            }
            pipArgs += ["-r", requirementsPath]
            process.arguments = pipArgs
            process.standardOutput = stdout
            process.standardError = stderr
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            process.environment = environment

            nonisolated(unsafe) var installed = 0
            nonisolated(unsafe) var resumed = false

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let text = String(data: data, encoding: .utf8) else { return }

                for line in text.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("Collecting") ||
                        trimmed.hasPrefix("Downloading") ||
                        trimmed.hasPrefix("Installing") ||
                        trimmed.hasPrefix("Successfully installed") {
                        if trimmed.hasPrefix("Collecting") {
                            installed += 1
                        }
                        let current = min(installed, totalPackages)
                        Task {
                            await publishProgress(current, totalPackages)
                        }
                    }
                }
            }

            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                guard !resumed else { return }
                resumed = true
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "pip install failed"
                    continuation.resume(
                        throwing: PythonEnvironmentManager.SetupError.commandFailed(
                            errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                }
            }

            do {
                try process.run()
            } catch {
                guard !resumed else { return }
                resumed = true
                continuation.resume(throwing: error)
            }
        }
    }
}
