import AVFoundation
import MLX
import SwiftUI
import UIKit
import QwenVoiceCore

@MainActor
final class IOSAppDependenciesContainer: ObservableObject {
    let registry: ContractBackedModelRegistry?
    let documentIO: LocalDocumentIO?
    let engine: TTSEngineStore?
    let modelManager: ModelManagerViewModel?
    let modelInstaller: IOSModelInstallerViewModel?
    let startupError: Error?

    init() {
        do {
            let registry = TTSContract.registry
            let documentIO = LocalDocumentIO(importedReferenceDirectory: AppPaths.importedReferenceAudioDir)
            let selectedBackend = try QVoiceiOSApp.makeBackend(
                registry: registry,
                documentIO: documentIO
            )
            let installer = selectedBackend.modelInstaller
            self.registry = registry
            self.documentIO = documentIO
            self.engine = selectedBackend.engineStore
            self.modelManager = selectedBackend.modelManager
            self.modelInstaller = installer
            IOSModelDeliveryBackgroundEventRelay.handler = { completionHandler in
                installer.handleBackgroundEventsCompletion(completionHandler)
            }
            self.startupError = nil
        } catch {
            self.registry = nil
            self.documentIO = nil
            self.engine = nil
            self.modelManager = nil
            self.modelInstaller = nil
            self.startupError = error
        }
    }
}

extension QVoiceiOSApp {
    private static func modelAssetStoreSeed(bundle: Bundle = .main) -> String {
        let bundleIdentifier = bundle.bundleIdentifier ?? "com.qvoice.ios"
        let marketingVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let buildVersion = bundle.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "0"
        return "\(bundleIdentifier)|\(marketingVersion)|\(buildVersion)"
    }

    struct SelectedBackend {
        let engineStore: TTSEngineStore
        let modelManager: ModelManagerViewModel
        let modelInstaller: IOSModelInstallerViewModel
    }

    private enum IOSBackendBootstrapError: LocalizedError {
        case missingSharedContainer(String)

        var errorDescription: String? {
            switch self {
            case .missingSharedContainer(let appGroupIdentifier):
                return """
                Vocello needs an App Group shared container to keep the UI app and engine extension in sync.
                Add \(appGroupIdentifier) to both iPhone targets, then rebuild.
                """
            }
        }
    }

    static func makeBackend(
        registry: ContractBackedModelRegistry,
        documentIO: LocalDocumentIO
    ) throws -> SelectedBackend {
        if IOSSimulatorRuntimeSupport.isSimulator {
            let modelAssetStore = LocalModelAssetStore(
                modelRegistry: registry,
                rootDirectory: AppPaths.modelsDir,
                storeVersionSeed: modelAssetStoreSeed()
            )
            let modelManager = ModelManagerViewModel(
                modelRegistry: registry,
                modelAssetStore: modelAssetStore
            )
            let engineStore = TTSEngineStore(
                backend: AnyTTSEngineBackend(
                    engine: IOSSimulatorTTSEngine(
                        modelRegistry: registry,
                        documentIO: documentIO
                    ),
                    supportsSavedVoiceMutation: true,
                    supportsModelManagementMutation: true,
                    supportedModes: [.custom, .design, .clone]
                )
            )
            let modelInstaller = IOSModelInstallerViewModel(
                modelAssetStore: modelAssetStore,
                modelManager: modelManager
            )
            return SelectedBackend(
                engineStore: engineStore,
                modelManager: modelManager,
                modelInstaller: modelInstaller
            )
        }

        guard AppPaths.isUsingSharedContainer else {
            throw IOSBackendBootstrapError.missingSharedContainer(
                AppPaths.sharedAppGroupIdentifier
            )
        }

        let modelAssetStore = LocalModelAssetStore(
            modelRegistry: registry,
            rootDirectory: AppPaths.modelsDir,
            storeVersionSeed: modelAssetStoreSeed()
        )
        let modelManager = ModelManagerViewModel(
            modelRegistry: registry,
            modelAssetStore: modelAssetStore
        )
        let engine = ExtensionBackedTTSEngine(
            modelRegistry: registry,
            documentIO: documentIO,
            hostManager: VocelloEngineHostManager.shared
        )
        let engineStore = TTSEngineStore(
            backend: AnyTTSEngineBackend(
                engine: engine,
                supportsSavedVoiceMutation: true,
                supportsModelManagementMutation: true,
                supportedModes: [.custom, .design, .clone]
            )
        )
        let modelInstaller = IOSModelInstallerViewModel(
            modelAssetStore: modelAssetStore,
            modelManager: modelManager
        )
        modelInstaller.onModelInstalled = { [weak engineStore] modelID in
            guard let engineStore else { return }
            Task {
                try? await engineStore.loadModel(id: modelID)
            }
        }
        return SelectedBackend(
            engineStore: engineStore,
            modelManager: modelManager,
            modelInstaller: modelInstaller
        )
    }
}

enum IOSDeviceSupport {
    static var isSupportedHardware: Bool {
#if targetEnvironment(simulator)
        true
#else
        isSupportedIdentifier(machineIdentifier())
#endif
    }

    static var unsupportedReason: String {
#if targetEnvironment(simulator)
        return "Vocello is running in the iOS Simulator. UI review works here, but generation still requires a real iPhone 15 Pro or newer."
#else
        let identifier = machineIdentifier()
        return "Vocello for iPhone currently requires iPhone 15 Pro or newer.\nCurrent device: \(identifier)"
#endif
    }

    private static func isSupportedIdentifier(_ identifier: String) -> Bool {
        if identifier.hasPrefix("iPhone16,1") || identifier.hasPrefix("iPhone16,2") {
            return true
        }
        guard identifier.hasPrefix("iPhone") else { return false }
        let majorVersion = identifier
            .dropFirst("iPhone".count)
            .split(separator: ",")
            .first
            .map(String.init)
            .flatMap(Int.init)
        return (majorVersion ?? 0) >= 17
    }

    private static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}

struct IOSUnsupportedDeviceView: View {
    let reason: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.orange)
            Text("Unsupported Device")
                .font(.title2.weight(.semibold))
            Text(reason)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
        .padding(32)
    }
}
