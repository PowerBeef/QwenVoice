import Foundation

/// Stable identity encoded in `URLSessionTask.taskDescription`. It deliberately contains no URL
/// or filesystem path so it is safe to persist and use when adopting background tasks.
public struct ModelDownloadTaskIdentity: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let logicalRequestID: String
    public let modelID: String
    public let artifactVersion: String
    public let relativePath: String
    public let expectedSize: Int64
    public let expectedSHA256: String?

    public init(
        logicalRequestID: String,
        modelID: String,
        artifactVersion: String,
        relativePath: String,
        expectedSize: Int64,
        expectedSHA256: String?
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.logicalRequestID = logicalRequestID
        self.modelID = modelID
        self.artifactVersion = artifactVersion
        self.relativePath = relativePath
        self.expectedSize = expectedSize
        self.expectedSHA256 = expectedSHA256
    }

    public var encodedTaskDescription: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return data.base64EncodedString()
    }

    public static func decode(taskDescription: String?) -> Self? {
        guard let taskDescription,
              let data = Data(base64Encoded: taskDescription),
              let identity = try? JSONDecoder().decode(Self.self, from: data),
              identity.schemaVersion == currentSchemaVersion else {
            return nil
        }
        return identity
    }
}

public struct ModelDownloadRequestIdentity: Equatable, Hashable, Sendable {
    public let logicalRequestID: String
    public let modelID: String
    public let artifactVersion: String

    public init(logicalRequestID: String, modelID: String, artifactVersion: String) {
        self.logicalRequestID = logicalRequestID
        self.modelID = modelID
        self.artifactVersion = artifactVersion
    }
}

public struct ModelDownloadExistingTask: Equatable, Sendable {
    public let taskID: Int
    public let identity: ModelDownloadTaskIdentity?

    public init(taskID: Int, identity: ModelDownloadTaskIdentity?) {
        self.taskID = taskID
        self.identity = identity
    }
}

public struct ModelDownloadReconciliationPlan: Equatable, Sendable {
    public let adoptedTaskByRelativePath: [String: Int]
    public let cancelledTaskIDs: [Int]
    public let missingRelativePaths: [String]
}

/// Small production-used state machine that makes UIKit background-event completion testable
/// without creating a URLSession or launching an app. The completion is released exactly once,
/// and only after URLSession has delivered all delegate events and durable postprocessing ended.
public struct ModelDownloadBackgroundCompletionGate: Equatable, Sendable {
    public private(set) var eventsFinished = false
    public private(set) var postprocessingFinished = false
    public private(set) var completionDelivered = false

    public init() {}

    public mutating func markEventsFinished() -> Bool {
        eventsFinished = true
        return takeCompletionIfReady()
    }

    public mutating func markPostprocessingFinished() -> Bool {
        postprocessingFinished = true
        return takeCompletionIfReady()
    }

    /// Start another logical request while preserving an already-delivered session event only
    /// when UIKit has not yet received its completion. A fully delivered cycle starts cleanly.
    public mutating func resetForRequest() {
        postprocessingFinished = false
        if completionDelivered {
            eventsFinished = false
            completionDelivered = false
        }
    }

    private mutating func takeCompletionIfReady() -> Bool {
        guard eventsFinished, postprocessingFinished, !completionDelivered else { return false }
        completionDelivered = true
        return true
    }
}

/// Deterministic task-inventory reconciliation used by the live URLSession bridge and fake-task
/// tests. Exactly one valid task may own a file; stale, unknown, or duplicate tasks are cancelled.
public enum ModelDownloadTaskReconciler {
    public static func plan(
        expected: [ModelDownloadTaskIdentity],
        existing: [ModelDownloadExistingTask]
    ) -> ModelDownloadReconciliationPlan {
        let expectedByPath = Dictionary(uniqueKeysWithValues: expected.map { ($0.relativePath, $0) })
        var adopted: [String: Int] = [:]
        var cancelled: [Int] = []

        for task in existing.sorted(by: { $0.taskID < $1.taskID }) {
            guard let identity = task.identity,
                  expectedByPath[identity.relativePath] == identity,
                  adopted[identity.relativePath] == nil else {
                cancelled.append(task.taskID)
                continue
            }
            adopted[identity.relativePath] = task.taskID
        }

        return ModelDownloadReconciliationPlan(
            adoptedTaskByRelativePath: adopted,
            cancelledTaskIDs: cancelled.sorted(),
            missingRelativePaths: expectedByPath.keys.filter { adopted[$0] == nil }.sorted()
        )
    }
}

public enum ModelDownloadProgressReconciler {
    /// A relaunched or retried task may report fewer bytes than the durable ledger while it is
    /// being adopted. User-visible progress never moves backward and never exceeds the total.
    public static func visibleBytes(current: Int64, persisted: Int64, total: Int64?) -> Int64 {
        let value = max(0, max(current, persisted))
        guard let total, total > 0 else { return value }
        return min(value, total)
    }
}

/// Proof that one immutable staged file was read and verified in this process generation.
/// The receipt lets final installation avoid a second multi-gigabyte hash pass while still
/// invalidating on relaunch or any metadata change.
public struct VerifiedArtifactReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let relativePath: String
    public let artifactVersion: String
    public let expectedSize: Int64
    public let expectedSHA256: String?
    public let fileSize: Int64
    public let modificationTimeNanoseconds: Int64
    public let fileIdentifier: UInt64?
    public let verificationProcessGeneration: String

    public init(
        relativePath: String,
        artifactVersion: String,
        expectedSize: Int64,
        expectedSHA256: String?,
        fileSize: Int64,
        modificationTimeNanoseconds: Int64,
        fileIdentifier: UInt64?,
        verificationProcessGeneration: String
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.relativePath = relativePath
        self.artifactVersion = artifactVersion
        self.expectedSize = expectedSize
        self.expectedSHA256 = expectedSHA256
        self.fileSize = fileSize
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
        self.fileIdentifier = fileIdentifier
        self.verificationProcessGeneration = verificationProcessGeneration
    }

    public func matches(
        relativePath: String,
        artifactVersion: String,
        expectedSize: Int64,
        expectedSHA256: String?,
        fileSize: Int64,
        modificationTimeNanoseconds: Int64,
        fileIdentifier: UInt64?,
        processGeneration: String
    ) -> Bool {
        self.relativePath == relativePath
            && self.artifactVersion == artifactVersion
            && self.expectedSize == expectedSize
            && self.expectedSHA256 == expectedSHA256
            && self.fileSize == fileSize
            && self.modificationTimeNanoseconds == modificationTimeNanoseconds
            && self.fileIdentifier == fileIdentifier
            && verificationProcessGeneration == processGeneration
    }
}

public enum ModelDownloadRetryDisposition: Equatable, Sendable {
    case retry(afterSeconds: Double)
    case retryClean(afterSeconds: Double)
    case fail
    case cancelled
}

/// Pure retry classifier shared by the downloader and deterministic tests.
public enum ModelDownloadRetryPolicy {
    public static func disposition(
        error: Error,
        retryNumber: Int,
        integrityRetryAlreadyUsed: Bool,
        retryAfterSeconds: Double? = nil
    ) -> ModelDownloadRetryDisposition {
        if error is CancellationError {
            return .cancelled
        }

        if let downloadError = error as? HuggingFaceDownloader.DownloadError {
            switch downloadError {
            case .cancelled:
                return .cancelled
            case .integrityCheckFailed:
                guard !integrityRetryAlreadyUsed else { return .fail }
                return .retryClean(afterSeconds: boundedDelay(retryAfterSeconds ?? backoff(retryNumber)))
            case .httpError(let statusCode, _, let responseRetryAfter):
                if statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode) {
                    return retryNumber <= 3
                        ? .retry(afterSeconds: boundedDelay(retryAfterSeconds ?? responseRetryAfter ?? backoff(retryNumber)))
                        : .fail
                }
                return .fail
            case .rangeUnsupported, .chunkAssemblyFailed:
                return retryNumber <= 3
                    ? .retryClean(afterSeconds: boundedDelay(backoff(retryNumber)))
                    : .fail
            case .fileDownloadFailed(_, let underlying):
                return dispositionForFoundationError(underlying, retryNumber: retryNumber)
            case .invalidRemotePath, .invalidLocalDestination, .apiError:
                return .fail
            }
        }

        return dispositionForFoundationError(error, retryNumber: retryNumber)
    }

    private static func dispositionForFoundationError(
        _ error: Error,
        retryNumber: Int
    ) -> ModelDownloadRetryDisposition {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return .fail }
        if nsError.code == NSURLErrorCancelled { return .cancelled }

        let permanentCodes: Set<Int> = [
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid,
            NSURLErrorSecureConnectionFailed,
            NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired,
            NSURLErrorCannotWriteToFile,
            NSURLErrorDataLengthExceedsMaximum,
            NSURLErrorFileDoesNotExist,
            NSURLErrorNoPermissionsToReadFile,
        ]
        guard !permanentCodes.contains(nsError.code), retryNumber <= 3 else { return .fail }

        let transientCodes: Set<Int> = [
            NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorResourceUnavailable,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorCallIsActive,
            NSURLErrorDataNotAllowed,
        ]
        return transientCodes.contains(nsError.code)
            ? .retry(afterSeconds: boundedDelay(backoff(retryNumber)))
            : .fail
    }

    private static func backoff(_ retryNumber: Int) -> Double {
        min(pow(2, Double(max(0, retryNumber - 1))), 10)
    }

    private static func boundedDelay(_ seconds: Double) -> Double {
        min(max(seconds, 0), 300)
    }
}
