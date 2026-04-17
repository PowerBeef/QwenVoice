import Foundation

struct NativeModelDescriptor: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let folder: String
    let modeIdentifier: String
    let requiredRelativePaths: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case folder
        case modeIdentifier = "mode"
        case requiredRelativePaths
    }
}

enum NativeModelAvailability: Equatable, Sendable {
    case unknown
    case unavailable(descriptor: NativeModelDescriptor, missingRequiredPaths: [String])
    case available(descriptor: NativeModelDescriptor)
}

struct NativeModelRegistry {
    enum RegistryError: LocalizedError, Equatable {
        case manifestNotFound
        case invalidManifest(String)

        var errorDescription: String? {
            switch self {
            case .manifestNotFound:
                return "Couldn't locate the bundled qwenvoice_contract.json manifest for the native runtime."
            case .invalidManifest(let message):
                return "The native model manifest is invalid: \(message)"
            }
        }
    }

    private struct Manifest: Decodable {
        let models: [NativeModelDescriptor]
    }

    private final class BundleLocator: NSObject {}

    let manifestURL: URL
    private let descriptorsByID: [String: NativeModelDescriptor]

    init(manifestURL: URL? = nil) throws {
        let resolvedURL = try manifestURL ?? Self.defaultManifestURL()
        let data = try Data(contentsOf: resolvedURL)
        let decoded = try JSONDecoder().decode(Manifest.self, from: data)

        var descriptorsByID: [String: NativeModelDescriptor] = [:]
        for descriptor in decoded.models {
            guard !descriptor.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RegistryError.invalidManifest("model IDs must not be empty")
            }
            guard !descriptor.folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RegistryError.invalidManifest("model '\(descriptor.id)' is missing a folder name")
            }
            guard !descriptor.requiredRelativePaths.isEmpty else {
                throw RegistryError.invalidManifest("model '\(descriptor.id)' is missing requiredRelativePaths")
            }
            guard descriptorsByID[descriptor.id] == nil else {
                throw RegistryError.invalidManifest("duplicate model id '\(descriptor.id)'")
            }
            descriptorsByID[descriptor.id] = descriptor
        }

        self.manifestURL = resolvedURL
        self.descriptorsByID = descriptorsByID
    }

    func descriptor(id: String) -> NativeModelDescriptor? {
        descriptorsByID[id]
    }

    func installDirectory(for descriptor: NativeModelDescriptor, in modelsDirectory: URL) -> URL {
        modelsDirectory.appendingPathComponent(descriptor.folder, isDirectory: true)
    }

    func availability(
        forModelID modelID: String,
        in modelsDirectory: URL,
        fileManager: FileManager = .default
    ) -> NativeModelAvailability {
        guard let descriptor = descriptor(id: modelID) else {
            return .unknown
        }

        let installDirectory = installDirectory(for: descriptor, in: modelsDirectory)
        let missingRequiredPaths = descriptor.requiredRelativePaths.filter { relativePath in
            !fileManager.fileExists(
                atPath: installDirectory.appendingPathComponent(relativePath).path
            )
        }

        if missingRequiredPaths.isEmpty {
            return .available(descriptor: descriptor)
        }

        return .unavailable(
            descriptor: descriptor,
            missingRequiredPaths: missingRequiredPaths.sorted()
        )
    }

    static func defaultManifestURL() throws -> URL {
        let bundles = [Bundle.main, Bundle(for: BundleLocator.self)] + Bundle.allBundles + Bundle.allFrameworks

        for bundle in bundles {
            if let url = bundle.url(forResource: "qwenvoice_contract", withExtension: "json") {
                return url
            }
        }

        throw RegistryError.manifestNotFound
    }
}
