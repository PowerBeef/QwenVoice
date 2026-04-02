import Foundation

@MainActor
struct PythonRuntimeValidator {
    private static let minimumSupportedMacOSMajor = 15
    private static let minimumSupportedMacOSMinor = 0
    private static let minimumSupportedMacOSVersionString = "15.0"

    private let discovery: PythonRuntimeDiscovery

    init(discovery: PythonRuntimeDiscovery) {
        self.discovery = discovery
    }

    func validateImports(pythonPath: String) async throws {
        let importScript = "import mlx; import mlx.core as mx; import mlx_audio; import transformers; import numpy; import soundfile; import huggingface_hub; x = mx.array([1.0], dtype=mx.float32); mx.eval(x)"
        try await runProcess(pythonPath, arguments: ["-c", importScript])
    }

    func validateBundledRuntime(pythonPath: String) async throws {
        try validateBundledRuntimeCompatibility(pythonPath: pythonPath)
        try await validateImports(pythonPath: pythonPath)
    }

    private struct BundledRuntimeCompatibility {
        let mlxWheelTag: String
        let mlxMetalWheelTag: String
        let mlxCoreMinOS: String?
    }

    private func validateBundledRuntimeCompatibility(pythonPath: String) throws {
        let runtimeRoot = URL(fileURLWithPath: pythonPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let compatibility = try loadBundledRuntimeCompatibility(runtimeRoot: runtimeRoot)

        try validateWheelTag(compatibility.mlxWheelTag, label: "mlx")
        try validateWheelTag(compatibility.mlxMetalWheelTag, label: "mlx-metal")
        if let minOS = compatibility.mlxCoreMinOS {
            try validateTargetVersionString(minOS, label: "mlx core extension minos")
        }
    }

    private func loadBundledRuntimeCompatibility(runtimeRoot: URL) throws -> BundledRuntimeCompatibility {
        var manifestMlxWheelTag: String?
        var manifestMlxMetalWheelTag: String?
        var manifestMlxCoreMinOS: String?

        let manifestURL = runtimeRoot.appendingPathComponent(".qwenvoice-runtime-manifest.json")
        if let manifestData = try? Data(contentsOf: manifestURL),
           let json = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] {
            manifestMlxWheelTag = json["mlx_wheel_tag"] as? String
            manifestMlxMetalWheelTag = json["mlx_metal_wheel_tag"] as? String
            manifestMlxCoreMinOS = json["mlx_core_minos"] as? String
            if let supportedMinimum = json["supported_minimum_macos"] as? String,
               supportedMinimum != Self.minimumSupportedMacOSVersionString {
                throw PythonEnvironmentManager.SetupError.commandFailed(
                    "Bundled runtime metadata mismatch: minimum macOS is \(supportedMinimum), expected \(Self.minimumSupportedMacOSVersionString)."
                )
            }
        }

        guard let sitePackages = bundledSitePackagesURL(runtimeRoot: runtimeRoot) else {
            throw PythonEnvironmentManager.SetupError.commandFailed("Bundled runtime is missing site-packages metadata.")
        }

        let mlxWheelTag = manifestMlxWheelTag ?? readWheelTag(in: sitePackages, prefix: "mlx-")
        let mlxMetalWheelTag = manifestMlxMetalWheelTag ?? readWheelTag(in: sitePackages, prefix: "mlx_metal-")

        guard let mlxWheelTag else {
            throw PythonEnvironmentManager.SetupError.commandFailed("Bundled runtime is missing mlx wheel compatibility metadata.")
        }
        guard let mlxMetalWheelTag else {
            throw PythonEnvironmentManager.SetupError.commandFailed("Bundled runtime is missing mlx-metal wheel compatibility metadata.")
        }

        return BundledRuntimeCompatibility(
            mlxWheelTag: mlxWheelTag,
            mlxMetalWheelTag: mlxMetalWheelTag,
            mlxCoreMinOS: manifestMlxCoreMinOS
        )
    }

    private func bundledSitePackagesURL(runtimeRoot: URL) -> URL? {
        let libURL = runtimeRoot.appendingPathComponent("lib", isDirectory: true)
        guard let entries = try? discovery.fileManager.contentsOfDirectory(
            at: libURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let pythonLib = entries
            .filter(\.hasDirectoryPath)
            .first(where: { $0.lastPathComponent.hasPrefix("python") })
        guard let pythonLib else { return nil }

        let sitePackages = pythonLib.appendingPathComponent("site-packages", isDirectory: true)
        return discovery.fileManager.fileExists(atPath: sitePackages.path) ? sitePackages : nil
    }

    private func readWheelTag(in sitePackages: URL, prefix: String) -> String? {
        guard let entries = try? discovery.fileManager.contentsOfDirectory(
            at: sitePackages,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        guard let distInfo = entries.first(where: {
            $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix(".dist-info")
        }) else {
            return nil
        }

        let wheelPath = distInfo.appendingPathComponent("WHEEL")
        guard let content = try? String(contentsOf: wheelPath, encoding: .utf8) else {
            return nil
        }

        for line in content.split(separator: "\n") where line.hasPrefix("Tag: ") {
            return String(line.dropFirst("Tag: ".count))
        }
        return nil
    }

    private func validateWheelTag(_ tag: String, label: String) throws {
        guard let targetVersion = parseMacOSTargetFromWheelTag(tag) else {
            throw PythonEnvironmentManager.SetupError.commandFailed("Could not parse \(label) wheel tag: \(tag)")
        }
        try validateTargetVersion(targetVersion, label: "\(label) wheel tag", rawValue: tag)
    }

    private func validateTargetVersionString(_ value: String, label: String) throws {
        guard let targetVersion = parseVersionString(value) else {
            throw PythonEnvironmentManager.SetupError.commandFailed("Could not parse \(label): \(value)")
        }
        try validateTargetVersion(targetVersion, label: label, rawValue: value)
    }

    private func parseMacOSTargetFromWheelTag(_ tag: String) -> (major: Int, minor: Int)? {
        guard let markerRange = tag.range(of: "macosx_"),
              let armRange = tag.range(of: "_arm64", options: .backwards),
              markerRange.upperBound <= armRange.lowerBound else {
            return nil
        }

        let versionPortion = tag[markerRange.upperBound..<armRange.lowerBound]
        let parts = versionPortion.split(separator: "_")
        guard parts.count >= 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1]) else {
            return nil
        }
        return (major, minor)
    }

    private func parseVersionString(_ value: String) -> (major: Int, minor: Int)? {
        let parts = value.split(separator: ".")
        guard let majorPart = parts.first,
              let major = Int(majorPart) else {
            return nil
        }
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return (major, minor)
    }

    private func validateTargetVersion(
        _ targetVersion: (major: Int, minor: Int),
        label: String,
        rawValue: String
    ) throws {
        let supportedFloor = (
            major: Self.minimumSupportedMacOSMajor,
            minor: Self.minimumSupportedMacOSMinor
        )
        if targetVersion.major > supportedFloor.major ||
            (targetVersion.major == supportedFloor.major && targetVersion.minor > supportedFloor.minor) {
            throw PythonEnvironmentManager.SetupError.commandFailed(
                "Bundled runtime is incompatible: \(label) requires macOS \(rawValue), which exceeds the app minimum \(Self.minimumSupportedMacOSVersionString)."
            )
        }
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
}
