import Foundation

#if targetEnvironment(simulator)

@MainActor
enum IOSSimulatorStateReset {
    static func perform(
        registry: IOSSimulatorFakeInstallRegistry,
        modelAssetStore: LocalModelAssetStore
    ) {
        // Stub: filled in by Task 7.
    }
}

#endif
