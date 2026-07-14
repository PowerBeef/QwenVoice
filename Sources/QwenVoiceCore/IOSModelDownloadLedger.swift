import Foundation

public struct IOSModelDownloadLedger: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public enum Status: String, Codable, Sendable {
        case queued
        case waitingForConnectivity
        case downloading
        case retrying
        case verifying
        case installing
        case cancelRequested
        case installed
        case failed
        case deleted
    }

    public struct VerifiedFile: Codable, Equatable, Sendable {
        public let relativePath: String
        public let expectedSize: Int64
        public let sha256: String?

        public init(relativePath: String, expectedSize: Int64, sha256: String?) {
            self.relativePath = relativePath
            self.expectedSize = expectedSize
            self.sha256 = sha256
        }
    }

    public struct Request: Codable, Equatable, Sendable {
        public let logicalRequestID: String
        public let modelID: String
        public let artifactVersion: String
        public let repo: String
        public let revision: String
        public let targetFolder: String
        public let expectedFiles: [String]
        public var verifiedFiles: [VerifiedFile]
        public var retryCount: Int
        public var receivedBytes: Int64
        public var totalBytes: Int64
        public var status: Status

        public init(
            logicalRequestID: String,
            modelID: String,
            artifactVersion: String,
            repo: String,
            revision: String,
            targetFolder: String,
            expectedFiles: [String],
            verifiedFiles: [VerifiedFile],
            retryCount: Int,
            receivedBytes: Int64,
            totalBytes: Int64,
            status: Status
        ) {
            self.logicalRequestID = logicalRequestID
            self.modelID = modelID
            self.artifactVersion = artifactVersion
            self.repo = repo
            self.revision = revision
            self.targetFolder = targetFolder
            self.expectedFiles = expectedFiles
            self.verifiedFiles = verifiedFiles
            self.retryCount = retryCount
            self.receivedBytes = receivedBytes
            self.totalBytes = totalBytes
            self.status = status
        }
    }

    public let schemaVersion: Int
    public var requests: [Request]

    public init(requests: [Request] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.requests = requests
    }

    public func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw IOSModelDownloadLedgerError.unsupportedSchema(schemaVersion)
        }
        var logicalIDs = Set<String>()
        var modelIDs = Set<String>()
        for request in requests {
            guard !request.logicalRequestID.isEmpty,
                  !request.modelID.isEmpty,
                  !request.artifactVersion.isEmpty,
                  !request.targetFolder.isEmpty,
                  !request.targetFolder.contains("/"),
                  request.expectedFiles.allSatisfy({ isSafeRelativePath($0) }),
                  request.verifiedFiles.allSatisfy({ isSafeRelativePath($0.relativePath) }),
                  request.receivedBytes >= 0,
                  request.totalBytes >= 0,
                  request.retryCount >= 0,
                  logicalIDs.insert(request.logicalRequestID).inserted,
                  modelIDs.insert(request.modelID).inserted else {
                throw IOSModelDownloadLedgerError.invalidDocument
            }
        }
        return self
    }

    private func isSafeRelativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.split(separator: "/").contains("..")
    }
}

public enum IOSModelDownloadLedgerError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidDocument

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported model-download ledger schema \(version)."
        case .invalidDocument:
            return "The model-download ledger is invalid."
        }
    }
}

public struct IOSModelDownloadLedgerStore {
    public let fileURL: URL
    public let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() throws -> IOSModelDownloadLedger {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return IOSModelDownloadLedger()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(IOSModelDownloadLedger.self, from: data).validated()
    }

    public func save(_ ledger: IOSModelDownloadLedger) throws {
        let validated = try ledger.validated()
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(validated).write(to: fileURL, options: [.atomic])
    }
}
