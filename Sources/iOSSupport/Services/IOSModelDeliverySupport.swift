import CryptoKit
import Foundation
import QwenVoiceCore

struct IOSModelDeliveryConfiguration: Sendable {
    static let catalogURLEnvironmentKey = "QVOICE_IOS_MODEL_CATALOG_URL"
    static let allowedHostsEnvironmentKey = "QVOICE_IOS_MODEL_ALLOWED_HOSTS"
    static let catalogURLInfoPlistKey = "QVoiceModelCatalogURL"
    static let defaultCatalogURLString = "https://downloads.qvoice.app/ios/catalog/v1/models.json"
    static let backgroundSessionIdentifierPrefix = "com.qvoice.ios.model-delivery"

    let catalogURL: URL
    let allowedHosts: Set<String>
    let backgroundSessionIdentifier: String
    let allowsInsecureTransport: Bool

    init(
        catalogURL: URL,
        allowedHosts: Set<String>? = nil,
        backgroundSessionIdentifier: String,
        allowsInsecureTransport: Bool = false
    ) {
        self.catalogURL = catalogURL
        self.allowedHosts = allowedHosts ?? Set([catalogURL.host].compactMap { $0?.lowercased() })
        self.backgroundSessionIdentifier = backgroundSessionIdentifier
        self.allowsInsecureTransport = allowsInsecureTransport
    }

    static func `default`(bundle: Bundle = .main) -> IOSModelDeliveryConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let rawOverride = environment[catalogURLEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOverride = rawOverride.flatMap(normalizedCatalogOverrideString(_:))
        let overrideURL = normalizedOverride.flatMap(URL.init(string:))
        let bundleDefault = (bundle.object(forInfoDictionaryKey: catalogURLInfoPlistKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBundleDefault = bundleDefault.flatMap(normalizedCatalogOverrideString(_:))
        let bundleURL = normalizedBundleDefault.flatMap(URL.init(string:))
        let catalogURL = overrideURL ?? bundleURL ?? URL(string: defaultCatalogURLString)!
        let overrideHosts = Set(
            environment[allowedHostsEnvironmentKey]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty } ?? []
        )
        let defaultHost = Set([catalogURL.host].compactMap { $0?.lowercased() })
        let bundleIdentifier = bundle.bundleIdentifier ?? "com.qvoice.ios"
        let backgroundIdentifier = "\(backgroundSessionIdentifierPrefix).\(bundleIdentifier)"
        return IOSModelDeliveryConfiguration(
            catalogURL: catalogURL,
            allowedHosts: defaultHost.union(overrideHosts),
            backgroundSessionIdentifier: backgroundIdentifier,
            allowsInsecureTransport: false
        )
    }

    private static func normalizedCatalogOverrideString(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        if raw.hasPrefix("http:/"), !raw.hasPrefix("http://") {
            return raw.replacingOccurrences(of: "http:/", with: "http://", options: [.anchored])
        }
        if raw.hasPrefix("https:/"), !raw.hasPrefix("https://") {
            return raw.replacingOccurrences(of: "https:/", with: "https://", options: [.anchored])
        }
        return raw
    }
}

struct IOSModelCatalogDocument: Codable, Hashable, Sendable {
    let generatedAt: String?
    let models: [IOSModelCatalogEntry]
}

struct IOSModelCatalogEntry: Codable, Hashable, Sendable, Identifiable {
    let modelID: String
    let artifactVersion: String
    let totalBytes: Int64
    let baseURL: URL
    let files: [IOSModelCatalogFile]

    var id: String {
        "\(modelID)|\(artifactVersion)"
    }
}

struct IOSModelCatalogFile: Codable, Hashable, Sendable {
    let relativePath: String
    let sizeBytes: Int64
    let sha256: String
    let url: URL?
}

enum IOSModelDeliveryError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidCatalog(String)
    case missingCatalogEntry(modelID: String, artifactVersion: String)
    case notEligibleForIOS(modelID: String)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case missingRequiredFiles([String])
    case unexpectedFile(String)
    case fileHashMismatch(relativePath: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .invalidCatalog(let message):
            return message
        case .missingCatalogEntry(let modelID, let artifactVersion):
            return "Model catalog is missing \(modelID) artifact \(artifactVersion)."
        case .notEligibleForIOS(let modelID):
            return "\(modelID) is not available for iPhone downloads in this build."
        case .insufficientDiskSpace(let requiredBytes, let availableBytes):
            let required = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
            return "Not enough free storage. Need \(required), but only \(available) is available."
        case .missingRequiredFiles(let files):
            return "Downloaded model is missing required files: \(files.joined(separator: ", "))."
        case .unexpectedFile(let path):
            return "Catalog contains an invalid file path: \(path)."
        case .fileHashMismatch(let relativePath):
            return "Integrity check failed for \(relativePath)."
        case .cancelled:
            return "Download cancelled."
        }
    }
}

enum IOSModelDeliverySupport {
    static func matchingCatalogEntry(
        for descriptor: ModelDescriptor,
        in document: IOSModelCatalogDocument,
        configuration: IOSModelDeliveryConfiguration
    ) throws -> IOSModelCatalogEntry {
        guard descriptor.iosDownloadEligible else {
            throw IOSModelDeliveryError.notEligibleForIOS(modelID: descriptor.id)
        }

        guard let entry = document.models.first(where: {
            $0.modelID == descriptor.id && $0.artifactVersion == descriptor.artifactVersion
        }) else {
            throw IOSModelDeliveryError.missingCatalogEntry(
                modelID: descriptor.id,
                artifactVersion: descriptor.artifactVersion
            )
        }

        try validate(entry: entry, configuration: configuration)
        let catalogPaths = Set(entry.files.map(\.relativePath))
        let requiredPaths = Set(descriptor.requiredRelativePaths)

        let missingRequired = requiredPaths.subtracting(catalogPaths).sorted()
        guard missingRequired.isEmpty else {
            throw IOSModelDeliveryError.missingRequiredFiles(missingRequired)
        }

        return entry
    }

    static func validate(
        entry: IOSModelCatalogEntry,
        configuration: IOSModelDeliveryConfiguration
    ) throws {
        try validateCatalogURL(url: configuration.catalogURL, configuration: configuration)
        try validateArtifactURL(url: entry.baseURL, configuration: configuration, label: "model base")

        guard !entry.files.isEmpty else {
            throw IOSModelDeliveryError.invalidCatalog("Catalog entry for \(entry.modelID) has no files.")
        }

        var seenRelativePaths = Set<String>()
        var totalBytes: Int64 = 0
        for file in entry.files {
            guard !file.relativePath.isEmpty else {
                throw IOSModelDeliveryError.invalidCatalog("Catalog entry for \(entry.modelID) contains an empty relative path.")
            }
            guard !file.relativePath.hasPrefix("/"), !file.relativePath.contains("..") else {
                throw IOSModelDeliveryError.unexpectedFile(file.relativePath)
            }
            guard seenRelativePaths.insert(file.relativePath).inserted else {
                throw IOSModelDeliveryError.invalidCatalog("Catalog entry for \(entry.modelID) contains duplicate path \(file.relativePath).")
            }
            guard file.sizeBytes >= 0 else {
                throw IOSModelDeliveryError.invalidCatalog("Catalog entry for \(entry.modelID) contains a negative size for \(file.relativePath).")
            }
            guard file.sha256.count == 64 else {
                throw IOSModelDeliveryError.invalidCatalog("Catalog entry for \(entry.modelID) contains an invalid SHA-256 for \(file.relativePath).")
            }
            if let fileURL = file.url {
                try validateArtifactURL(url: fileURL, configuration: configuration, label: "artifact")
            }
            totalBytes += file.sizeBytes
        }

        if entry.totalBytes > 0, entry.totalBytes != totalBytes {
            throw IOSModelDeliveryError.invalidCatalog(
                "Catalog entry for \(entry.modelID) reports \(entry.totalBytes) total bytes, but files sum to \(totalBytes)."
            )
        }
    }

    static func downloadURL(
        for file: IOSModelCatalogFile,
        entry: IOSModelCatalogEntry,
        configuration: IOSModelDeliveryConfiguration
    ) throws -> URL {
        if let fileURL = file.url {
            try validateArtifactURL(url: fileURL, configuration: configuration, label: "artifact")
            return fileURL
        }

        var url = entry.baseURL
        for component in file.relativePath.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        try validateArtifactURL(url: url, configuration: configuration, label: "artifact")
        return url
    }

    static func verifyDownloadedModel(
        descriptor: ModelDescriptor,
        entry: IOSModelCatalogEntry,
        stagedRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        let expectedPaths = Set(entry.files.map(\.relativePath))
        let requiredPaths = Set(descriptor.requiredRelativePaths)
        let missingRequired = requiredPaths.filter { relativePath in
            !fileManager.fileExists(atPath: stagedRoot.appendingPathComponent(relativePath).path)
        }
        guard missingRequired.isEmpty else {
            throw IOSModelDeliveryError.missingRequiredFiles(missingRequired.sorted())
        }

        for file in entry.files {
            let fileURL = stagedRoot.appendingPathComponent(file.relativePath)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                throw IOSModelDeliveryError.missingRequiredFiles([file.relativePath])
            }
            let digest = try sha256Hex(for: fileURL)
            guard digest == file.sha256.lowercased() else {
                throw IOSModelDeliveryError.fileHashMismatch(relativePath: file.relativePath)
            }
        }

        if let enumerator = fileManager.enumerator(
            at: stagedRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let isRegularFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                guard isRegularFile else {
                    continue
                }
                let relativePath = try relativePath(for: fileURL, within: stagedRoot)
                if !expectedPaths.contains(relativePath) {
                    throw IOSModelDeliveryError.unexpectedFile(relativePath)
                }
            }
        }
    }

    private static func relativePath(for fileURL: URL, within rootURL: URL) throws -> String {
        let normalizedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let normalizedFile = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = normalizedRoot.pathComponents
        let fileComponents = normalizedFile.pathComponents

        guard fileComponents.starts(with: rootComponents), fileComponents.count > rootComponents.count else {
            throw IOSModelDeliveryError.unexpectedFile(normalizedFile.path)
        }

        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    static func sha256Hex(for fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func ensureSufficientDiskSpace(
        requiredBytes: Int64,
        at rootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let values = try rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let availableBytes = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        let safetyBuffer = Int64(256 * 1_024 * 1_024)
        let minimumRequired = max(requiredBytes * 2, requiredBytes + safetyBuffer)
        guard availableBytes >= minimumRequired else {
            throw IOSModelDeliveryError.insufficientDiskSpace(
                requiredBytes: minimumRequired,
                availableBytes: availableBytes
            )
        }
        _ = fileManager
    }

    static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private static func validateCatalogURL(
        url: URL,
        configuration: IOSModelDeliveryConfiguration
    ) throws {
        if !configuration.allowsInsecureTransport, url.scheme?.lowercased() != "https" {
            throw IOSModelDeliveryError.invalidConfiguration("Catalog URL must use HTTPS.")
        }

        if let host = url.host?.lowercased(),
           !configuration.allowedHosts.isEmpty,
           !configuration.allowedHosts.contains(host) {
            throw IOSModelDeliveryError.invalidConfiguration("Catalog URL host \(host) is not allowed.")
        }
    }

    private static func validateArtifactURL(
        url: URL,
        configuration: IOSModelDeliveryConfiguration,
        label: String
    ) throws {
        if !configuration.allowsInsecureTransport, url.scheme?.lowercased() != "https" {
            throw IOSModelDeliveryError.invalidConfiguration("\(label.capitalized) URL must use HTTPS.")
        }
    }
}
