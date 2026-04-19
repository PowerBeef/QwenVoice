import CryptoKit
import Foundation

public enum DocumentIOError: LocalizedError, Equatable {
    case missingSource(String)
    case failedToCreateDirectory(String)
    case failedToCopy(String)

    public var errorDescription: String? {
        switch self {
        case .missingSource(let path):
            return "Document file not found: \(path)"
        case .failedToCreateDirectory(let path):
            return "Couldn't create document directory at \(path)."
        case .failedToCopy(let path):
            return "Couldn't copy the document to \(path)."
        }
    }
}

public struct ImportedReferenceAudio: Hashable, Codable, Sendable {
    public let originalPath: String
    public let materializedPath: String
    public let transcriptSidecarPath: String?
    public let fingerprint: String

    public init(
        originalPath: String,
        materializedPath: String,
        transcriptSidecarPath: String?,
        fingerprint: String
    ) {
        self.originalPath = originalPath
        self.materializedPath = materializedPath
        self.transcriptSidecarPath = transcriptSidecarPath
        self.fingerprint = fingerprint
    }

    public var originalURL: URL {
        URL(fileURLWithPath: originalPath)
    }

    public var materializedURL: URL {
        URL(fileURLWithPath: materializedPath)
    }

    public var transcriptSidecarURL: URL? {
        guard let transcriptSidecarPath else { return nil }
        return URL(fileURLWithPath: transcriptSidecarPath)
    }
}

public struct ExportedDocument: Hashable, Codable, Sendable {
    public let sourcePath: String
    public let destinationPath: String

    public init(sourcePath: String, destinationPath: String) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
    }

    public var sourceURL: URL {
        URL(fileURLWithPath: sourcePath)
    }

    public var destinationURL: URL {
        URL(fileURLWithPath: destinationPath)
    }
}

public protocol DocumentIO: Sendable {
    func importReferenceAudio(from sourceURL: URL) throws -> ImportedReferenceAudio
    func exportGeneratedAudio(from sourceURL: URL, to destinationURL: URL) throws -> ExportedDocument
}

public struct LocalDocumentIO: DocumentIO, Hashable, Sendable {
    public let importedReferenceDirectory: URL

    public init(importedReferenceDirectory: URL) {
        self.importedReferenceDirectory = importedReferenceDirectory
    }

    public func importReferenceAudio(from sourceURL: URL) throws -> ImportedReferenceAudio {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw DocumentIOError.missingSource(sourceURL.path)
        }

        do {
            try fileManager.createDirectory(at: importedReferenceDirectory, withIntermediateDirectories: true)
        } catch {
            throw DocumentIOError.failedToCreateDirectory(importedReferenceDirectory.path)
        }

        let fingerprint = Self.fileFingerprint(for: sourceURL)
        let destinationURL = importedReferenceDirectory.appendingPathComponent(
            "\(Self.sanitizedStem(for: sourceURL))_\(fingerprint).\(sourceURL.pathExtension.lowercased())"
        )
        try Self.copyReplacingIfNeeded(sourceURL, to: destinationURL)

        let sourceSidecarURL = sourceURL.deletingPathExtension().appendingPathExtension("txt")
        let destinationSidecarURL = destinationURL.deletingPathExtension().appendingPathExtension("txt")
        if fileManager.fileExists(atPath: sourceSidecarURL.path) {
            try Self.copyReplacingIfNeeded(sourceSidecarURL, to: destinationSidecarURL)
        } else if fileManager.fileExists(atPath: destinationSidecarURL.path) {
            try? fileManager.removeItem(at: destinationSidecarURL)
        }

        return ImportedReferenceAudio(
            originalPath: sourceURL.path,
            materializedPath: destinationURL.path,
            transcriptSidecarPath: fileManager.fileExists(atPath: destinationSidecarURL.path)
                ? destinationSidecarURL.path
                : nil,
            fingerprint: fingerprint
        )
    }

    public func exportGeneratedAudio(from sourceURL: URL, to destinationURL: URL) throws -> ExportedDocument {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw DocumentIOError.missingSource(sourceURL.path)
        }

        let parentDirectory = destinationURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        } catch {
            throw DocumentIOError.failedToCreateDirectory(parentDirectory.path)
        }

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw DocumentIOError.failedToCopy(destinationURL.path)
        }

        return ExportedDocument(sourcePath: sourceURL.path, destinationPath: destinationURL.path)
    }

    private static func copyReplacingIfNeeded(_ sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        if sourceURL.standardizedFileURL == destinationURL.standardizedFileURL {
            return
        }

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw DocumentIOError.failedToCopy(destinationURL.path)
        }
    }

    private static func fileFingerprint(for url: URL) -> String {
        let fileManager = FileManager.default
        let resolvedPath = url.resolvingSymlinksInPath().path
        let attributes = (try? fileManager.attributesOfItem(atPath: resolvedPath)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let data = Data("\(resolvedPath)|\(size)|\(mtime)".utf8)
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizedStem(for url: URL) -> String {
        let raw = url.deletingPathExtension().lastPathComponent
        let sanitized = raw
            .replacingOccurrences(of: #"[^\w\s-]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        return sanitized.isEmpty ? "reference" : sanitized
    }
}
