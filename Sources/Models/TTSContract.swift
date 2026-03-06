import Foundation

private struct TTSContractManifest: Decodable {
    let defaultSpeaker: String
    let speakers: [String: [String]]
    let models: [TTSModel]
}

private final class TTSContractBundleLocator: NSObject { }

enum TTSContract {
    static var manifestURL: URL {
        locateManifestURL()
    }

    static var models: [TTSModel] {
        manifest.models
    }

    static var defaultSpeaker: String {
        manifest.defaultSpeaker
    }

    static var groupedSpeakers: [String: [String]] {
        manifest.speakers
    }

    static var allSpeakers: [String] {
        manifest.speakers.keys.sorted().flatMap { manifest.speakers[$0] ?? [] }
    }

    static func model(for mode: GenerationMode) -> TTSModel? {
        manifest.models.first { $0.mode == mode }
    }

    static func model(id: String) -> TTSModel? {
        manifest.models.first { $0.id == id }
    }

    private static let manifest: TTSContractManifest = loadManifest()

    private static func loadManifest() -> TTSContractManifest {
        let url = locateManifestURL()

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(TTSContractManifest.self, from: data)
            try validate(decoded)
            return decoded
        } catch {
            fatalError("Failed to load qwenvoice_contract.json: \(error.localizedDescription)")
        }
    }

    private static func validate(_ manifest: TTSContractManifest) throws {
        guard !manifest.models.isEmpty else {
            throw ValidationError("Manifest must define at least one model.")
        }

        guard !manifest.speakers.isEmpty else {
            throw ValidationError("Manifest must define at least one speaker group.")
        }

        let allSpeakers = manifest.speakers.keys.sorted().flatMap { manifest.speakers[$0] ?? [] }
        guard allSpeakers.contains(manifest.defaultSpeaker) else {
            throw ValidationError("Default speaker '\(manifest.defaultSpeaker)' is not present in the manifest speaker list.")
        }

        let duplicateModelIDs = duplicateValues(in: manifest.models.map(\.id))
        guard duplicateModelIDs.isEmpty else {
            throw ValidationError("Manifest contains duplicate model ids: \(duplicateModelIDs.joined(separator: ", ")).")
        }

        let duplicateModes = duplicateValues(in: manifest.models.map(\.mode.rawValue))
        guard duplicateModes.isEmpty else {
            throw ValidationError("Manifest contains duplicate model modes: \(duplicateModes.joined(separator: ", ")).")
        }

        for model in manifest.models {
            guard !model.tier.isEmpty else {
                throw ValidationError("Model '\(model.id)' must define a tier.")
            }
            guard !model.outputSubfolder.isEmpty else {
                throw ValidationError("Model '\(model.id)' must define an output subfolder.")
            }
            guard !model.requiredRelativePaths.isEmpty else {
                throw ValidationError("Model '\(model.id)' must define required files.")
            }
        }
    }

    private static func locateManifestURL() -> URL {
        let bundles = [Bundle.main, Bundle(for: TTSContractBundleLocator.self)] + Bundle.allBundles + Bundle.allFrameworks

        for bundle in bundles {
            if let url = bundle.url(forResource: "qwenvoice_contract", withExtension: "json") {
                return url
            }
        }

        fatalError("Could not locate bundled qwenvoice_contract.json")
    }

    private static func duplicateValues(in values: [String]) -> [String] {
        var seen = Set<String>()
        var duplicates = Set<String>()

        for value in values {
            if !seen.insert(value).inserted {
                duplicates.insert(value)
            }
        }

        return duplicates.sorted()
    }
}

private struct ValidationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
