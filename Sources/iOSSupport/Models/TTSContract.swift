import Foundation
import QwenVoiceCore

private final class TTSContractBundleLocator: NSObject { }

enum TTSContractError: LocalizedError, Equatable, Sendable {
    case manifestNotFound

    var errorDescription: String? {
        switch self {
        case .manifestNotFound:
            return "Could not locate bundled qwenvoice_contract.json."
        }
    }
}

enum TTSContract {
    static var manifestURL: URL {
        try locateManifestURL()
    }

    static var registryLoadError: String? {
        switch loadedRegistryResult {
        case .success:
            return nil
        case .failure(let error):
            return error.localizedDescription
        }
    }

    static func loadRegistry() throws -> ContractBackedModelRegistry {
        try loadedRegistryResult.get()
    }

    static var registry: ContractBackedModelRegistry {
        get throws {
            try loadRegistry()
        }
    }

    static var models: [ModelDescriptor] {
        (try? loadRegistry().models) ?? []
    }

    static var defaultSpeaker: String {
        (try? loadRegistry().defaultSpeaker.id) ?? ""
    }

    static var groupedSpeakers: [String: [String]] {
        guard let registry = try? loadRegistry() else { return [:] }
        return registry.groupedSpeakers.mapValues { speakers in
            speakers.map(\.id)
        }
    }

    static var groupedSpeakerDescriptors: [String: [SpeakerDescriptor]] {
        (try? loadRegistry().groupedSpeakers) ?? [:]
    }

    static var allSpeakers: [String] {
        (try? loadRegistry().allSpeakers.map(\.id)) ?? []
    }

    static var allSpeakerDescriptors: [SpeakerDescriptor] {
        (try? loadRegistry().allSpeakers) ?? []
    }

    static func speakerDescriptor(id: String) -> SpeakerDescriptor? {
        try? loadRegistry().allSpeakers.first { $0.id == id }
    }

    static func model(for mode: GenerationMode) -> ModelDescriptor? {
        try? loadRegistry().model(for: mode)
    }

    static func model(id: String) -> ModelDescriptor? {
        try? loadRegistry().model(id: id)
    }

    private static let loadedRegistryResult: Result<ContractBackedModelRegistry, Error> = {
        do {
            let url = try locateManifestURL()
            let registry = try ContractBackedModelRegistry(manifestURL: url)
                .resolvedForPlatform(.iOS, deviceClass: .iPhonePro)
            return .success(registry)
        } catch {
            return .failure(error)
        }
    }()

    private static func locateManifestURL() throws -> URL {
        let bundles = [Bundle.main, Bundle(for: TTSContractBundleLocator.self)] + Bundle.allBundles + Bundle.allFrameworks

        for bundle in bundles {
            if let url = bundle.url(forResource: "qwenvoice_contract", withExtension: "json") {
                return url
            }
        }

        throw TTSContractError.manifestNotFound
    }
}
