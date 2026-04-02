import Foundation

@MainActor
struct PythonRuntimeProvisioner {
    enum Outcome: Equatable {
        case ready(pythonPath: String)
        case failed(message: String)
    }

    private let discovery: PythonRuntimeDiscovery
    private let validator: PythonRuntimeValidator
    private let installer: RequirementsInstaller

    init(
        discovery: PythonRuntimeDiscovery,
        validator: PythonRuntimeValidator,
        installer: RequirementsInstaller
    ) {
        self.discovery = discovery
        self.validator = validator
        self.installer = installer
    }

    func runSlowPath(
        publishState: @escaping @MainActor (PythonEnvironmentManager.State) -> Void
    ) async -> Outcome {
        let venvPython = discovery.venvPythonPath
        let vendorDir = discovery.resolveVendorDir()

        if discovery.fileManager.fileExists(atPath: venvPython),
           let requirementsPath = discovery.resolveRequirementsPath() {
            await publishState(.settingUp(.updatingDependencies))

            do {
                try await installer.installDependencies(
                    venvPython: venvPython,
                    requirementsPath: requirementsPath,
                    vendorDir: vendorDir,
                    publishProgress: { installed, total in
                        publishState(.settingUp(.installingDependencies(installed: installed, total: total)))
                    }
                )
                try await validator.validateImports(pythonPath: venvPython)
                discovery.writeMarker(requirementsPath: requirementsPath)
                return .ready(pythonPath: venvPython)
            } catch {
                // Fall through to a full recreate after a failed incremental update.
            }
        }

        await publishState(.settingUp(.findingPython))
        guard let systemPython = discovery.findSystemPython() else {
            let brewExists =
                discovery.fileManager.fileExists(atPath: "/opt/homebrew/bin/brew") ||
                discovery.fileManager.fileExists(atPath: "/usr/local/bin/brew")
            let message = brewExists
                ? "Python 3.11+ not found. Install it via:\n  brew install python@3.13"
                : "Python 3.11+ not found.\n\nFirst install Homebrew:\n  /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/homebrew/install/HEAD/install.sh)\"\n\nThen install Python:\n  brew install python@3.13"
            return .failed(message: message)
        }

        await publishState(.settingUp(.creatingVenv))
        do {
            try await installer.createVirtualEnvironment(systemPython: systemPython)
        } catch {
            return .failed(
                message: "Failed to create virtual environment:\n\(error.localizedDescription)"
            )
        }

        guard let requirementsPath = discovery.resolveRequirementsPath() else {
            return .failed(message: "Cannot find requirements.txt in app bundle.")
        }

        await publishState(
            .settingUp(
                .installingDependencies(
                    installed: 0,
                    total: discovery.countPackages(in: requirementsPath)
                )
            )
        )

        do {
            try await installer.installDependencies(
                venvPython: venvPython,
                requirementsPath: requirementsPath,
                vendorDir: vendorDir,
                publishProgress: { installed, total in
                    publishState(.settingUp(.installingDependencies(installed: installed, total: total)))
                }
            )
            try await validator.validateImports(pythonPath: venvPython)
            discovery.writeMarker(requirementsPath: requirementsPath)
            return .ready(pythonPath: venvPython)
        } catch {
            return .failed(
                message: "Dependencies installed but import validation failed:\n\(error.localizedDescription)\n\nSetup will retry on next launch."
            )
        }
    }
}
