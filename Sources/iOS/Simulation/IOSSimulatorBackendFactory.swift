import Foundation
import QwenVoiceCore

#if targetEnvironment(simulator)

/// Builds the simulator-only backend (fake engine, fake install registry,
/// simulated downloader) so `IOSAppBootstrap` only decides *which* factory to use.
@MainActor
enum IOSSimulatorBackendFactory {
    static func makeSelectedBackend(
        registry: ContractBackedModelRegistry,
        documentIO: LocalDocumentIO
    ) throws -> QVoiceiOSApp.SelectedBackend {
        let configuration = IOSSimulatorConfiguration()

        let modelAssetStore = LocalModelAssetStore(
            modelRegistry: registry,
            rootDirectory: AppPaths.modelsDir,
            storeVersionSeed: QVoiceiOSApp.modelAssetStoreSeed()
        )

        // Reset simulator test state before any UI sees it.
        if configuration.resetStateOnLaunch {
            IOSSimulatorStateReset.perform(
                registry: IOSSimulatorFakeInstallRegistry.shared,
                modelAssetStore: modelAssetStore
            )
        }

        // Seed the fake-installed model registry from env.
        IOSSimulatorFakeInstallRegistry.shared.applyConfiguration(
            configuration,
            models: registry.models
        )

        let fakeStatusProvider = IOSSimulatorFakeStatusProvider(
            wrapping: LocalModelStatusProvider(modelAssetStore: modelAssetStore),
            registry: IOSSimulatorFakeInstallRegistry.shared
        )

        let modelManager = ModelManagerViewModel(
            modelRegistry: registry,
            statusProvider: fakeStatusProvider
        )

        var simSupportedModes: Set<GenerationMode> = [.custom, .design]
        if configuration.cloneCapableOverride != false {
            simSupportedModes.insert(.clone)
        }

        let fakeEngine = IOSSimulatorTTSEngine(
            modelRegistry: registry,
            documentIO: documentIO,
            configuration: configuration
        )

        let engineStore = TTSEngineStore(
            backend: AnyTTSEngineBackend(
                engine: fakeEngine,
                supportsSavedVoiceMutation: true,
                supportsModelManagementMutation: true,
                supportedModes: simSupportedModes
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

        return QVoiceiOSApp.SelectedBackend(
            engineStore: engineStore,
            modelManager: modelManager,
            modelInstaller: modelInstaller
        )
    }
}

#else

// Keep the factory unavailable on device so accidental references fail at compile time.
enum IOSSimulatorBackendFactory {}

#endif
