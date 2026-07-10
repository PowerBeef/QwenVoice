import Foundation
import QwenVoiceCore

/// Pure, bounded middle-layer probe state used by the XPC event drain.
/// JSONL publication remains the host's responsibility at terminal boundaries.
public struct EngineServiceTransportAccumulator: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let generationID: UUID?
        public let chunksForwarded: Int
        public let chunkGaps: Int
        public let duplicateChunks: Int
        public let outOfOrderChunks: Int
        public let terminalCount: Int
        public let finishReason: GenerationTerminalReason?
    }

    private let sessionIdentity = UUID().uuidString
    private let telemetryEnabled: Bool
    private var generationID: UUID?
    private var mode: String?
    private var firstChunkUptime: Double?
    private var chunksForwarded = 0
    private var firstChunkSequence: UInt64?
    private var lastChunkSequence: UInt64?
    private var gapCount = 0
    private var duplicateChunks = 0
    private var outOfOrderChunks = 0
    private var terminalCount = 0
    private var lastFinishReason: GenerationTerminalReason?

    public init(telemetryEnabled: Bool = TelemetryGate.resolvedEnabled) {
        self.telemetryEnabled = telemetryEnabled
    }

    public var snapshot: Snapshot {
        Snapshot(
            generationID: generationID,
            chunksForwarded: chunksForwarded,
            chunkGaps: gapCount,
            duplicateChunks: duplicateChunks,
            outOfOrderChunks: outOfOrderChunks,
            terminalCount: terminalCount,
            finishReason: lastFinishReason
        )
    }

    /// Returns at most one durable record for a terminal or superseded generation.
    public mutating func observe(event: GenerationEvent) -> GenerationTelemetryRecord? {
        switch event {
        case .chunk(let chunk):
            var superseded: GenerationTelemetryRecord?
            if chunk.generationID != generationID {
                superseded = makeRecord(finishReason: .superseded, usedStreaming: true, notes: [:])
                begin(chunk)
            }
            observeSequence(chunk.chunkSequence)
            chunksForwarded += 1
            return superseded
        case .completed(let result):
            let reason = GenerationTerminalReason(compatibilityValue: result.finishReason?.rawValue ?? "completed")
            let record = makeRecord(finishReason: reason, usedStreaming: result.usedStreaming, notes: [:])
            if record != nil {
                terminalCount += 1
                lastFinishReason = reason
            }
            resetGeneration()
            return record
        case .failed(let message):
            let reason: GenerationTerminalReason = message.localizedCaseInsensitiveContains("cancel") ? .cancelled : .failed
            let notes = telemetryEnabled
                ? GenerationTelemetryPrivacy.failureNotes(message: message)
                : [:]
            let record = makeRecord(finishReason: reason, usedStreaming: true, notes: notes)
            if record != nil {
                terminalCount += 1
                lastFinishReason = reason
            }
            resetGeneration()
            return record
        case .progress:
            return nil
        }
    }

    private mutating func begin(_ chunk: GenerationChunk) {
        generationID = chunk.generationID
        mode = chunk.mode
        firstChunkUptime = ProcessInfo.processInfo.systemUptime
        chunksForwarded = 0
        firstChunkSequence = nil
        lastChunkSequence = nil
        gapCount = 0
        duplicateChunks = 0
        outOfOrderChunks = 0
    }

    private mutating func observeSequence(_ sequence: UInt64?) {
        guard let sequence else { return }
        if firstChunkSequence == nil { firstChunkSequence = sequence }
        if let previous = lastChunkSequence {
            if sequence == previous {
                duplicateChunks += 1
            } else if sequence < previous {
                outOfOrderChunks += 1
            } else if sequence > previous + 1 {
                gapCount += Int(sequence - previous - 1)
            }
        } else if sequence > 0 {
            gapCount += Int(sequence)
        }
        lastChunkSequence = max(lastChunkSequence ?? sequence, sequence)
    }

    private mutating func resetGeneration() {
        generationID = nil
        mode = nil
        firstChunkUptime = nil
        chunksForwarded = 0
        firstChunkSequence = nil
        lastChunkSequence = nil
        gapCount = 0
        duplicateChunks = 0
        outOfOrderChunks = 0
    }

    private func makeRecord(
        finishReason: GenerationTerminalReason,
        usedStreaming: Bool,
        notes: [String: String]
    ) -> GenerationTelemetryRecord? {
        guard telemetryEnabled, let generationID, chunksForwarded > 0 else { return nil }
        var timingsMS: [String: Int] = [:]
        var stageMarks: [NativeTelemetryStageMark] = []
        if let firstChunkUptime {
            let spanSeconds = max(0, ProcessInfo.processInfo.systemUptime - firstChunkUptime)
            timingsMS["chunkForwardingSpanMS"] = Int(spanSeconds * 1_000)
            timingsMS["chunkForwardingSpanNS"] = Int(min(Double(Int.max), spanSeconds * 1_000_000_000))
            stageMarks.append(NativeTelemetryStageMark(tMS: 0, stage: "firstChunk"))
        }
        let mergedNotes = notes
            .merging(currentTaskQOSNotes()) { current, _ in current }
            .merging(BenchRunContext.telemetryNotes()) { current, _ in current }
        return GenerationTelemetryRecord(
            generationID: generationID.uuidString,
            layer: .engineService,
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            mode: mode,
            usedStreaming: usedStreaming,
            finishReason: finishReason.rawValue,
            stageMarks: stageMarks,
            timingsMS: timingsMS,
            counters: [
                "chunksForwarded": chunksForwarded,
                "chunkGaps": gapCount,
                "duplicateChunks": duplicateChunks,
                "outOfOrderChunks": outOfOrderChunks,
            ],
            notes: mergedNotes,
            transportMetrics: EngineTransportMetrics(
                finishReason: finishReason,
                firstChunkToTerminalMS: timingsMS["chunkForwardingSpanMS"],
                counters: EngineTransportCounters(
                    chunksForwarded: chunksForwarded,
                    chunkGaps: gapCount,
                    duplicateChunks: duplicateChunks,
                    outOfOrderChunks: outOfOrderChunks
                ),
                cancellation: finishReason == .cancelled ? .completed : .notRequested,
                requestAccepted: true,
                sessionIdentity: sessionIdentity,
                firstChunkSequence: firstChunkSequence,
                lastChunkSequence: lastChunkSequence
            )
        )
    }
}
