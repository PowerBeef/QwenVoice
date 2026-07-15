import Foundation

/// Immutable, cross-platform artifact catalog used by production model downloads.
///
/// The product contract chooses a model and variant. This catalog supplies the exact pinned
/// repository identity plus a size and SHA-256 for every required file. A missing, staged, or
/// descriptor-mismatched entry is a hard error: production callers must never fall back to the
/// live repository file listing, because that path cannot authenticate ordinary Git files.
public struct ProductionModelCatalog: Decodable, Sendable {
    public enum Error: LocalizedError, Equatable, Sendable {
        case unreadable(String)
        case incomplete([String])
        case malformed(String)
        case artifactNotFound(modelID: String, variantID: String)
        case descriptorMismatch(identity: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let reason):
                return "The production model catalog could not be read: \(reason)"
            case .incomplete(let missing):
                return "The production model catalog is incomplete: \(missing.joined(separator: ", "))."
            case .malformed(let reason):
                return "The production model catalog is invalid: \(reason)"
            case .artifactNotFound(let modelID, let variantID):
                return "No authenticated model artifact exists for \(modelID):\(variantID)."
            case .descriptorMismatch(let identity, let reason):
                return "Authenticated artifact \(identity) does not match the model contract: \(reason)"
            }
        }
    }

    public struct File: Decodable, Hashable, Sendable {
        public let relativePath: String
        public let sizeBytes: Int64
        public let sha256: String
    }

    public struct Artifact: Decodable, Hashable, Sendable {
        public let modelID: String
        public let variantID: String
        public let platforms: Set<ModelArtifactPlatform>
        public let folder: String
        public let repo: String
        public let revision: String
        public let artifactVersion: String
        public let baseURL: URL
        public let totalBytes: Int64
        public let files: [File]

        public var identity: String { "\(modelID):\(variantID)" }

        /// Exact downloader inputs. Every URL remains pinned to the catalog's immutable revision.
        public var downloadFiles: [HuggingFaceDownloader.RepoFile] {
            files.map { file in
                var url = baseURL
                for component in file.relativePath.split(separator: "/") {
                    url.appendPathComponent(String(component), isDirectory: false)
                }
                return HuggingFaceDownloader.RepoFile(
                    path: file.relativePath,
                    size: file.sizeBytes,
                    sha256: file.sha256,
                    absoluteURL: url
                )
            }
        }
    }

    public let schemaVersion: Int
    public let catalogSchema: String
    public let activationState: String
    public let allowedArtifactHosts: Set<String>
    public let allowedRedirectHostSuffixes: Set<String>
    public let sourceDigests: [String: String]
    public let artifacts: [Artifact]
    public let missingArtifactIdentities: [String]

    public init(contentsOf url: URL) throws {
        do {
            self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch {
            throw Error.unreadable(error.localizedDescription)
        }
        try validate()
    }

    public var downloadURLPolicy: ModelArtifactURLPolicy {
        ModelArtifactURLPolicy(
            allowedInitialHosts: allowedArtifactHosts,
            allowedRedirectHostSuffixes: allowedRedirectHostSuffixes
        )
    }

    /// Resolve one macOS production artifact and prove that every catalog field still agrees with
    /// the selected product descriptor before the downloader creates any task.
    public func artifact(
        modelID: String,
        variantID: String,
        folder: String,
        repo: String,
        revision: String?,
        artifactVersion: String,
        estimatedDownloadBytes: Int64?,
        requiredRelativePaths: [String]
    ) throws -> Artifact {
        guard let artifact = artifacts.first(where: {
            $0.modelID == modelID && $0.variantID == variantID
        }) else {
            throw Error.artifactNotFound(modelID: modelID, variantID: variantID)
        }
        guard artifact.platforms.contains(.macOS) else {
            throw Error.descriptorMismatch(identity: artifact.identity, reason: "macOS is not an allowed platform")
        }
        let expectations: [(Bool, String)] = [
            (artifact.folder == folder, "folder differs"),
            (artifact.repo == repo, "repository differs"),
            (artifact.revision == revision, "revision differs"),
            (artifact.artifactVersion == artifactVersion, "artifact version differs"),
            (artifact.totalBytes == estimatedDownloadBytes, "payload size differs"),
            (Set(artifact.files.map(\.relativePath)) == Set(requiredRelativePaths), "required file set differs"),
        ]
        if let mismatch = expectations.first(where: { !$0.0 }) {
            throw Error.descriptorMismatch(identity: artifact.identity, reason: mismatch.1)
        }
        return artifact
    }

    /// Resolve an expanded registry descriptor (used by the CLI) without deriving a base model
    /// identity from its variant-scoped id. The immutable repository/folder/version tuple must
    /// identify exactly one catalog entry, after which the same full descriptor validation runs.
    public func artifactMatchingMacOSDescriptor(
        folder: String,
        repo: String,
        revision: String?,
        artifactVersion: String,
        estimatedDownloadBytes: Int64?,
        requiredRelativePaths: [String]
    ) throws -> Artifact {
        let matches = artifacts.filter {
            $0.folder == folder && $0.repo == repo && $0.revision == revision
                && $0.artifactVersion == artifactVersion
        }
        guard matches.count == 1, let match = matches.first else {
            throw Error.descriptorMismatch(
                identity: repo,
                reason: "descriptor resolves to \(matches.count) catalog artifacts"
            )
        }
        return try artifact(
            modelID: match.modelID,
            variantID: match.variantID,
            folder: folder,
            repo: repo,
            revision: revision,
            artifactVersion: artifactVersion,
            estimatedDownloadBytes: estimatedDownloadBytes,
            requiredRelativePaths: requiredRelativePaths
        )
    }

    private func validate() throws {
        guard schemaVersion == 1,
              catalogSchema == "config/model-catalog-schema-v1.json" else {
            throw Error.malformed("unsupported schema")
        }
        guard activationState == "complete", missingArtifactIdentities.isEmpty else {
            throw Error.incomplete(missingArtifactIdentities)
        }
        guard !allowedArtifactHosts.isEmpty, !allowedRedirectHostSuffixes.isEmpty else {
            throw Error.malformed("URL host policy is empty")
        }
        guard !artifacts.isEmpty else {
            throw Error.malformed("artifact list is empty")
        }

        var identities = Set<String>()
        for artifact in artifacts {
            guard identities.insert(artifact.identity).inserted else {
                throw Error.malformed("duplicate artifact \(artifact.identity)")
            }
            guard Self.isSafeIdentity(artifact.modelID), Self.isSafeIdentity(artifact.variantID),
                  Self.isSafeIdentity(artifact.artifactVersion), Self.isSafeFolder(artifact.folder),
                  Self.isPinnedRevision(artifact.revision), Self.isRepo(artifact.repo) else {
                throw Error.malformed("unsafe identity for \(artifact.identity)")
            }
            guard artifact.totalBytes > 0, !artifact.files.isEmpty,
                  artifact.totalBytes == artifact.files.reduce(Int64(0), { $0 + $1.sizeBytes }) else {
                throw Error.malformed("incorrect total size for \(artifact.identity)")
            }
            guard let components = URLComponents(url: artifact.baseURL, resolvingAgainstBaseURL: false),
                  components.scheme == "https", components.user == nil, components.password == nil,
                  components.port == nil || components.port == 443,
                  let host = components.host?.lowercased(), allowedArtifactHosts.contains(host),
                  components.query == nil, components.fragment == nil,
                  components.percentEncodedPath == "/\(artifact.repo)/resolve/\(artifact.revision)" else {
                throw Error.malformed("unpinned or untrusted base URL for \(artifact.identity)")
            }

            var paths = Set<String>()
            for file in artifact.files {
                guard paths.insert(file.relativePath).inserted,
                      Self.isSafeRelativePath(file.relativePath), file.sizeBytes > 0,
                      Self.isSHA256(file.sha256) else {
                    throw Error.malformed("invalid file identity for \(artifact.identity)")
                }
            }
        }
    }

    private static func isSafeIdentity(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.contains("/") && !value.contains("\\") && !value.contains("://")
    }

    private static func isSafeFolder(_ value: String) -> Bool {
        isSafeIdentity(value) && value != "." && value != ".."
    }

    private static func isRepo(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 2 && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isPinnedRevision(_ value: String) -> Bool {
        value.count == 40 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"),
              value.removingPercentEncoding == value else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
