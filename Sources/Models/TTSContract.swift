import Foundation

private struct TTSContractManifest: Decodable {
    let defaultSpeaker: String
    let speakers: [String: [String]]
    let models: [TTSModel]

    static let empty = TTSContractManifest(
        defaultSpeaker: "",
        speakers: [:],
        models: []
    )
}

struct ContractLoadError: LocalizedError, Equatable, Sendable {
    let summary: String
    let details: String
    let manifestPath: String?

    var errorDescription: String? {
        details
    }
}

private struct TTSContractLoadState {
    let manifest: TTSContractManifest
    let manifestURL: URL?
    let loadError: ContractLoadError?
}

private final class TTSContractBundleLocator: NSObject { }

enum TTSContract {
    static var manifestURL: URL? {
        loadState.manifestURL
    }

    static var loadError: ContractLoadError? {
        loadState.loadError
    }

    static var models: [TTSModel] {
        loadState.manifest.models
    }

    static var defaultSpeaker: String {
        loadState.manifest.defaultSpeaker
    }

    static var groupedSpeakers: [String: [String]] {
        loadState.manifest.speakers
    }

    static var allSpeakers: [String] {
        loadState.manifest.speakers.keys.sorted().flatMap { loadState.manifest.speakers[$0] ?? [] }
    }

    static func model(for mode: GenerationMode) -> TTSModel? {
        loadState.manifest.models.first { $0.mode == mode }
    }

    static func model(id: String) -> TTSModel? {
        loadState.manifest.models.first { $0.id == id }
    }

    private static let loadState: TTSContractLoadState = loadManifestState()

    private static func loadManifestState() -> TTSContractLoadState {
        var locatedManifestURL: URL?
        do {
            let url = try locateManifestURL()
            locatedManifestURL = url
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(TTSContractManifest.self, from: data)
            try validate(decoded)
            return TTSContractLoadState(
                manifest: decoded,
                manifestURL: url,
                loadError: nil
            )
        } catch let error as ContractLoadError {
            return handleLoadFailure(error)
        } catch {
            let failure = ContractLoadError(
                summary: "Failed to load qwenvoice_contract.json",
                details: error.localizedDescription,
                manifestPath: locatedManifestURL?.path
            )
            return handleLoadFailure(failure)
        }
    }

    private static func handleLoadFailure(_ error: ContractLoadError) -> TTSContractLoadState {
        #if DEBUG
        fatalError("\(error.summary): \(error.details)")
        #else
        let manifestURL = error.manifestPath.map { URL(fileURLWithPath: $0) }
        return TTSContractLoadState(
            manifest: .empty,
            manifestURL: manifestURL,
            loadError: error
        )
        #endif
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

    private static func locateManifestURL() throws -> URL {
        let bundles = [Bundle.main, Bundle(for: TTSContractBundleLocator.self)] + Bundle.allBundles + Bundle.allFrameworks

        for bundle in bundles {
            if let url = bundle.url(forResource: "qwenvoice_contract", withExtension: "json") {
                return url
            }
        }

        let searchedBundles = bundles
            .map(\.bundlePath)
            .joined(separator: "\n")
        throw ContractLoadError(
            summary: "Could not locate bundled qwenvoice_contract.json",
            details: "Searched bundles:\n\(searchedBundles)",
            manifestPath: nil
        )
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
