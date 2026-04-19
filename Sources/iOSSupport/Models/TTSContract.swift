import Foundation
import QwenVoiceCore

private final class TTSContractBundleLocator: NSObject { }

enum TTSContract {
    static var manifestURL: URL {
        locateManifestURL()
    }

    static var registry: ContractBackedModelRegistry {
        loadedRegistry
    }

    static var models: [ModelDescriptor] {
        registry.models
    }

    static var defaultSpeaker: String {
        registry.defaultSpeaker.id
    }

    static var groupedSpeakers: [String: [String]] {
        registry.groupedSpeakers.mapValues { speakers in
            speakers.map(\.id)
        }
    }

    static var allSpeakers: [String] {
        registry.allSpeakers.map(\.id)
    }

    static func model(for mode: GenerationMode) -> ModelDescriptor? {
        registry.model(for: mode)
    }

    static func model(id: String) -> ModelDescriptor? {
        registry.model(id: id)
    }

    private static let loadedRegistry: ContractBackedModelRegistry = {
        let url = locateManifestURL()
        do {
            return try ContractBackedModelRegistry(manifestURL: url)
                .resolvedForPlatform(.iOS)
        } catch {
            fatalError("Failed to load qwenvoice_contract.json: \(error.localizedDescription)")
        }
    }()

    private static func locateManifestURL() -> URL {
        let bundles = [Bundle.main, Bundle(for: TTSContractBundleLocator.self)] + Bundle.allBundles + Bundle.allFrameworks

        for bundle in bundles {
            if let url = bundle.url(forResource: "qwenvoice_contract", withExtension: "json") {
                return url
            }
        }

        fatalError("Could not locate bundled qwenvoice_contract.json")
    }
}
