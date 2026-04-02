import CryptoKit
import Foundation

struct PythonRuntimeDiscovery {
    let fileManager: FileManager = .default

    var appSupportDir: URL {
        AppPaths.appSupportDir
    }

    var venvDir: URL {
        AppPaths.pythonVenvDir
    }

    var venvPythonPath: String {
        venvDir.appendingPathComponent("bin/python3").path
    }

    var markerFile: URL {
        venvDir.appendingPathComponent(".setup-complete")
    }

    func machineIdentifier() -> String {
        var sysInfo = utsname()
        uname(&sysInfo)
        return withUnsafePointer(to: &sysInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    func bundledPythonPath() -> String? {
        if let bundlePath = Bundle.main.path(forResource: "python3", ofType: nil, inDirectory: "python/bin") {
            return bundlePath
        }
        if let bundlePath = Bundle.main.path(forResource: "python3.13", ofType: nil, inDirectory: "python/bin") {
            return bundlePath
        }
        if let resourceURL = Bundle.main.resourceURL {
            let candidates = [
                resourceURL.appendingPathComponent("python/bin/python3").path,
                resourceURL.appendingPathComponent("python/bin/python3.13").path
            ]
            for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    func bundledRuntimeExists() -> Bool {
        guard let resourceURL = Bundle.main.resourceURL else { return false }
        let runtimeRoot = resourceURL.appendingPathComponent("python").path
        return fileManager.fileExists(atPath: runtimeRoot)
    }

    func uiTestLiveOverridePythonPath() -> String? {
        guard UITestAutomationSupport.isEnabled,
              UITestAutomationSupport.backendMode == .live,
              let overridePath = ProcessInfo.processInfo.environment[AppPaths.appSupportOverrideEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !overridePath.isEmpty else {
            return nil
        }

        let candidate = venvPythonPath
        guard fileManager.isExecutableFile(atPath: candidate) else {
            return nil
        }
        return candidate
    }

    func findSystemPython() -> String? {
        let versionedPaths = [
            "/opt/homebrew/bin/python3.13",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/opt/homebrew/bin/python3.14",
            "/usr/local/bin/python3.13",
            "/usr/local/bin/python3.12",
            "/usr/local/bin/python3.11",
            "/usr/local/bin/python3.14",
        ]
        for path in versionedPaths where fileManager.fileExists(atPath: path) {
            return path
        }

        let genericPaths = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]
        for path in genericPaths where fileManager.fileExists(atPath: path) {
            if validatePythonVersion(path) {
                return path
            }
        }

        return nil
    }

    func resolveRequirementsPath() -> String? {
        if let path = Bundle.main.path(forResource: "requirements", ofType: "txt") {
            return path
        }

        let devPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/requirements.txt").path
        return fileManager.fileExists(atPath: devPath) ? devPath : nil
    }

    func bundledRequirementsPath() -> String? {
        resolveRequirementsPath()
    }

    func resolveVendorDir() -> String? {
        if let resourceURL = Bundle.main.resourceURL {
            let bundledVendor = resourceURL.appendingPathComponent("vendor").path
            if fileManager.fileExists(atPath: bundledVendor) {
                return bundledVendor
            }
        }

        let devPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/vendor").path
        return fileManager.fileExists(atPath: devPath) ? devPath : nil
    }

    func isMarkerValid() -> Bool {
        guard let markerData = fileManager.contents(atPath: markerFile.path),
              let markerHash = String(data: markerData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let requirementsPath = bundledRequirementsPath(),
              let requirementsData = fileManager.contents(atPath: requirementsPath) else {
            return false
        }

        let currentHash = SHA256.hash(data: requirementsData)
            .map { String(format: "%02x", $0) }
            .joined()
        return markerHash == currentHash
    }

    func writeMarker(requirementsPath: String) {
        guard let requirementsData = fileManager.contents(atPath: requirementsPath) else { return }
        let hash = SHA256.hash(data: requirementsData)
            .map { String(format: "%02x", $0) }
            .joined()
        try? hash.write(to: markerFile, atomically: true, encoding: .utf8)
    }

    func countPackages(in path: String) -> Int {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return 61 }
        return content.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
            .count
    }

    private func validatePythonVersion(_ pythonPath: String) -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        guard process.terminationStatus == 0 else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return false }

        let components = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Python ", with: "")
            .split(separator: ".")
        guard components.count >= 2,
              components[0] == "3",
              let minor = Int(components[1]) else {
            return false
        }

        return minor >= 11 && minor <= 14
    }
}
