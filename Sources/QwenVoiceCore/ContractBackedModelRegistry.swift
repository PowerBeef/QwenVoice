import Foundation

private struct ContractManifest: Decodable {
    let defaultSpeaker: String
    let speakers: [String: [String]]
    let models: [ModelDescriptor]
}

public struct ContractBackedModelRegistry: ModelRegistry, Hashable, Sendable {
    public enum Error: LocalizedError, Equatable {
        case missingModels
        case missingSpeakers
        case defaultSpeakerNotFound(String)
        case duplicateModelIDs([String])
        case duplicateModes([String])
        case invalidModel(id: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .missingModels:
                return "Manifest must define at least one model."
            case .missingSpeakers:
                return "Manifest must define at least one speaker group."
            case .defaultSpeakerNotFound(let id):
                return "Default speaker '\(id)' is not present in the manifest speaker list."
            case .duplicateModelIDs(let ids):
                return "Manifest contains duplicate model ids: \(ids.joined(separator: ", "))."
            case .duplicateModes(let modes):
                return "Manifest contains duplicate model modes: \(modes.joined(separator: ", "))."
            case .invalidModel(let id, let reason):
                return "Model '\(id)' is invalid: \(reason)"
            }
        }
    }

    public let manifestURL: URL
    public let models: [ModelDescriptor]
    public let defaultSpeaker: SpeakerDescriptor
    public let groupedSpeakers: [String: [SpeakerDescriptor]]

    public init(manifestURL: URL) throws {
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ContractManifest.self, from: data)
        try Self.validate(manifest)

        self.manifestURL = manifestURL
        self.models = manifest.models

        var grouped: [String: [SpeakerDescriptor]] = [:]
        for group in manifest.speakers.keys.sorted() {
            let speakers = manifest.speakers[group] ?? []
            grouped[group] = speakers.map { SpeakerDescriptor(group: group, id: $0) }
        }
        self.groupedSpeakers = grouped
        self.defaultSpeaker = grouped
            .values
            .flatMap { $0 }
            .first(where: { $0.id == manifest.defaultSpeaker })!
    }

    private init(
        manifestURL: URL,
        models: [ModelDescriptor],
        defaultSpeaker: SpeakerDescriptor,
        groupedSpeakers: [String: [SpeakerDescriptor]]
    ) {
        self.manifestURL = manifestURL
        self.models = models
        self.defaultSpeaker = defaultSpeaker
        self.groupedSpeakers = groupedSpeakers
    }

    public var allSpeakers: [SpeakerDescriptor] {
        groupedSpeakers.keys.sorted().flatMap { groupedSpeakers[$0] ?? [] }
    }

    public func model(for mode: GenerationMode) -> ModelDescriptor? {
        models.first { $0.mode == mode }
    }

    public func model(id: String) -> ModelDescriptor? {
        models.first { $0.id == id }
    }

    public func resolvedForPlatform(_ platform: ModelArtifactPlatform) -> ContractBackedModelRegistry {
        ContractBackedModelRegistry(
            manifestURL: manifestURL,
            models: models.map { $0.resolvedForPlatform(platform) },
            defaultSpeaker: defaultSpeaker,
            groupedSpeakers: groupedSpeakers
        )
    }

    /// Lists required model files that the manifest declares but cannot be
    /// found under the supplied root. Callers use this to surface missing
    /// assets at app launch instead of discovering the gap deep inside a
    /// later model-load (Tier 6). Non-fatal: returns an empty list when all
    /// required files resolve.
    public func missingRequiredFiles(installedUnder root: URL) -> [String] {
        var missing: [String] = []
        for model in models {
            let modelRoot = root.appendingPathComponent(model.folder, isDirectory: true)
            for relativePath in model.requiredRelativePaths {
                let candidate = modelRoot.appendingPathComponent(relativePath)
                if !FileManager.default.fileExists(atPath: candidate.path) {
                    missing.append("\(model.id)/\(relativePath)")
                }
            }
        }
        return missing
    }

    private static func validate(_ manifest: ContractManifest) throws {
        guard !manifest.models.isEmpty else {
            throw Error.missingModels
        }

        guard !manifest.speakers.isEmpty else {
            throw Error.missingSpeakers
        }

        let allSpeakers = manifest.speakers.keys.sorted().flatMap { manifest.speakers[$0] ?? [] }
        guard allSpeakers.contains(manifest.defaultSpeaker) else {
            throw Error.defaultSpeakerNotFound(manifest.defaultSpeaker)
        }

        let duplicateModelIDs = duplicateValues(in: manifest.models.map(\.id))
        guard duplicateModelIDs.isEmpty else {
            throw Error.duplicateModelIDs(duplicateModelIDs)
        }

        let duplicateModes = duplicateValues(in: manifest.models.map(\.mode.rawValue))
        guard duplicateModes.isEmpty else {
            throw Error.duplicateModes(duplicateModes)
        }

        for model in manifest.models {
            try validate(model: model, context: model.id)
        }
    }

    private static func validate(model: ModelDescriptor, context: String) throws {
        guard !model.tier.isEmpty else {
            throw Error.invalidModel(id: context, reason: "missing tier")
        }
        guard !model.artifactVersion.isEmpty else {
            throw Error.invalidModel(id: context, reason: "missing artifactVersion")
        }
        guard !model.outputSubfolder.isEmpty else {
            throw Error.invalidModel(id: context, reason: "missing outputSubfolder")
        }
        guard !model.requiredRelativePaths.isEmpty else {
            throw Error.invalidModel(id: context, reason: "missing requiredRelativePaths")
        }
        if let estimatedDownloadBytes = model.estimatedDownloadBytes,
           estimatedDownloadBytes < 0 {
            throw Error.invalidModel(id: context, reason: "estimatedDownloadBytes must be non-negative")
        }

        for variant in model.variants {
            guard !variant.artifactVersion.isEmpty else {
                throw Error.invalidModel(id: context, reason: "variant '\(variant.id)' missing artifactVersion")
            }
            guard !variant.requiredRelativePaths.isEmpty else {
                throw Error.invalidModel(id: context, reason: "variant '\(variant.id)' missing requiredRelativePaths")
            }
            if let estimatedDownloadBytes = variant.estimatedDownloadBytes,
               estimatedDownloadBytes < 0 {
                throw Error.invalidModel(id: context, reason: "variant '\(variant.id)' estimatedDownloadBytes must be non-negative")
            }
        }
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
