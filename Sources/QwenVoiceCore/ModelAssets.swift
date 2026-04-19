import CryptoKit
import Foundation

public enum ModelAssetScope: String, Codable, Hashable, Sendable {
    case shared
    case modelSpecific
}

public struct ModelAssetArtifact: Hashable, Codable, Sendable {
    public let relativePath: String
    public let scope: ModelAssetScope

    public init(relativePath: String, scope: ModelAssetScope) {
        self.relativePath = relativePath
        self.scope = scope
    }
}

public struct ModelAssetDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let model: ModelDescriptor
    public let version: String
    public let artifacts: [ModelAssetArtifact]

    public init(model: ModelDescriptor, version: String, artifacts: [ModelAssetArtifact]) {
        self.model = model
        self.version = version
        self.artifacts = artifacts
    }

    public var id: String {
        model.id
    }

    public var name: String {
        model.name
    }

    public var installFolder: String {
        model.folder
    }
}

public struct AssetIntegrity: Hashable, Codable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case missing
        case incomplete
        case verified
    }

    public let status: Status
    public let localRootPath: String
    public let missingRelativePaths: [String]
    public let presentRelativePaths: [String]
    public let sizeBytes: Int64

    public init(
        status: Status,
        localRootPath: String,
        missingRelativePaths: [String],
        presentRelativePaths: [String],
        sizeBytes: Int64
    ) {
        self.status = status
        self.localRootPath = localRootPath
        self.missingRelativePaths = missingRelativePaths
        self.presentRelativePaths = presentRelativePaths
        self.sizeBytes = sizeBytes
    }

    public var isComplete: Bool {
        status == .verified
    }

    public var localRootURL: URL {
        URL(fileURLWithPath: localRootPath, isDirectory: true)
    }
}

public enum ModelAssetState: Hashable, Codable, Sendable {
    case notInstalled
    case available(AssetIntegrity)
    case incomplete(AssetIntegrity)
    case downloading(downloadedBytes: Int64, totalBytes: Int64?)
    case deleting
    case failed(message: String)

    public var integrity: AssetIntegrity? {
        switch self {
        case .available(let integrity), .incomplete(let integrity):
            return integrity
        case .notInstalled, .downloading, .deleting, .failed:
            return nil
        }
    }
}

public protocol ModelAssetStore: Sendable {
    var rootDirectory: URL { get }
    var descriptors: [ModelAssetDescriptor] { get }

    func descriptor(id: String) -> ModelAssetDescriptor?
    func localRoot(for descriptor: ModelAssetDescriptor) -> URL
    func localURL(for descriptor: ModelAssetDescriptor, artifact: ModelAssetArtifact) -> URL
    func integrity(for descriptor: ModelAssetDescriptor) -> AssetIntegrity
    func state(for descriptor: ModelAssetDescriptor) -> ModelAssetState
}

public struct LocalModelAssetStore: ModelAssetStore, Hashable, Sendable {
    static let legacyInstallFolderNames: Set<String> = [
        "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
        "Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit",
        "Qwen3-TTS-12Hz-1.7B-Base-8bit",
    ]

    public let rootDirectory: URL
    public let descriptors: [ModelAssetDescriptor]
    public let storeVersionSeed: String

    public init(
        modelRegistry: any ModelRegistry,
        rootDirectory: URL,
        storeVersionSeed: String
    ) {
        self.rootDirectory = rootDirectory
        self.storeVersionSeed = storeVersionSeed
        self.descriptors = modelRegistry.models.map { model in
            ModelAssetDescriptor(
                model: model,
                version: Self.makeVersion(seed: storeVersionSeed, model: model),
                artifacts: model.requiredRelativePaths.map {
                    ModelAssetArtifact(relativePath: $0, scope: .modelSpecific)
                }
            )
        }
        Self.cleanupLegacyInstallFolders(
            at: rootDirectory,
            activeInstallFolders: Set(descriptors.map(\.installFolder))
        )
    }

    public func descriptor(id: String) -> ModelAssetDescriptor? {
        descriptors.first { $0.id == id }
    }

    public func localRoot(for descriptor: ModelAssetDescriptor) -> URL {
        rootDirectory.appendingPathComponent(descriptor.installFolder, isDirectory: true)
    }

    public func localURL(for descriptor: ModelAssetDescriptor, artifact: ModelAssetArtifact) -> URL {
        localRoot(for: descriptor).appendingPathComponent(artifact.relativePath)
    }

    public func integrity(for descriptor: ModelAssetDescriptor) -> AssetIntegrity {
        let fileManager = FileManager.default
        let root = localRoot(for: descriptor)
        var present: [String] = []
        var missing: [String] = []

        for artifact in descriptor.artifacts {
            let url = localURL(for: descriptor, artifact: artifact)
            if fileManager.fileExists(atPath: url.path) {
                present.append(artifact.relativePath)
            } else {
                missing.append(artifact.relativePath)
            }
        }

        let status: AssetIntegrity.Status
        if present.isEmpty {
            status = .missing
        } else if missing.isEmpty {
            status = .verified
        } else {
            status = .incomplete
        }

        return AssetIntegrity(
            status: status,
            localRootPath: root.path,
            missingRelativePaths: missing.sorted(),
            presentRelativePaths: present.sorted(),
            sizeBytes: Self.directorySize(at: root)
        )
    }

    public func state(for descriptor: ModelAssetDescriptor) -> ModelAssetState {
        let integrity = integrity(for: descriptor)
        switch integrity.status {
        case .missing:
            return .notInstalled
        case .verified:
            return .available(integrity)
        case .incomplete:
            return .incomplete(integrity)
        }
    }

    private static func makeVersion(seed: String, model: ModelDescriptor) -> String {
        let digest = SHA256.hash(
            data: Data(
                "\(seed)|\(model.id)|\(model.folder)|\(model.artifactVersion)|\(model.huggingFaceRepo)".utf8
            )
        )
        return "store-\(digest.prefix(8).map { String(format: "%02x", $0) }.joined())"
    }

    private static func directorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private static func cleanupLegacyInstallFolders(
        at rootDirectory: URL,
        activeInstallFolders: Set<String>,
        fileManager: FileManager = .default
    ) {
        let managedRoot = rootDirectory.standardizedFileURL
        let obsoleteFolders = legacyInstallFolderNames.subtracting(activeInstallFolders)
        guard !obsoleteFolders.isEmpty else { return }

        for folder in obsoleteFolders {
            let folderURL = managedRoot.appendingPathComponent(folder, isDirectory: true)
            guard folderURL.deletingLastPathComponent() == managedRoot else {
                continue
            }
            guard fileManager.fileExists(atPath: folderURL.path) else {
                continue
            }
            try? fileManager.removeItem(at: folderURL)
        }
    }
}
