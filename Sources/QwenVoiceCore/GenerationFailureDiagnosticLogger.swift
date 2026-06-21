import Foundation

/// Durable, append-only log for generation failures so the underlying error can be
/// recovered from a device without needing root console access.
///
/// Writes one JSON line per failure to `<documents>/generation-failures.jsonl`.
/// The file is intended for debugging sessions only; callers should still surface a
/// user-friendly message through the normal engine error pipeline.
public final class GenerationFailureDiagnosticLogger: @unchecked Sendable {
    public static let shared = GenerationFailureDiagnosticLogger()

    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let fileName = "generation-failures.jsonl"

    private init() {
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
    }

    /// Records a generation failure together with the underlying error that caused it.
    public func log(
        surfacedMessage: String,
        stage: String?,
        underlyingError: Error,
        request: GenerationRequest? = nil
    ) {
        let entry = FailureEntry(
            timestamp: Date(),
            surfacedMessage: surfacedMessage,
            stage: stage,
            underlyingError: String(reflecting: underlyingError),
            underlyingLocalizedDescription: underlyingError.localizedDescription,
            requestMode: request?.mode.rawValue,
            modelID: request?.modelID,
            textLength: request.map { $0.text.count },
            shouldStream: request?.shouldStream,
            stack: Array(Thread.callStackSymbols.prefix(30))
        )

        guard let data = try? encoder.encode(entry) else { return }

        lock.lock()
        defer { lock.unlock() }

        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return
        }

        let url = documentsURL.appendingPathComponent(fileName, isDirectory: false)
        var line = data
        line.append(0x0A)

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch {
            // Best-effort: do not let diagnostic logging itself break generation.
        }
    }

    private struct FailureEntry: Codable {
        let timestamp: Date
        let surfacedMessage: String
        let stage: String?
        let underlyingError: String
        let underlyingLocalizedDescription: String
        let requestMode: String?
        let modelID: String?
        let textLength: Int?
        let shouldStream: Bool?
        let stack: [String]
    }
}
