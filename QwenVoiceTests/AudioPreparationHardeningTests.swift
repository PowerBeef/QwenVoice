import Foundation
import XCTest
@testable import QwenVoiceCore

final class AudioPreparationHardeningTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioPreparationHardeningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
        try await super.tearDown()
    }

    func testRejectsOversizedInputBeforeDecode() async throws {
        let input = temporaryRoot.appendingPathComponent("oversized.wav")
        try Data(repeating: 0, count: 2_048).write(to: input)
        let service = NativeAudioPreparationService(
            preparedAudioDirectory: temporaryRoot,
            limits: AudioPreparationLimits(
                maxInputFileSizeBytes: 1_024,
                maxDecodedDurationSeconds: 120,
                trackLoadTimeoutSeconds: 60
            )
        )

        do {
            _ = try await service.normalizeAudio(AudioPreparationRequest(inputURL: input))
            XCTFail("Oversized input should be rejected.")
        } catch let error as AudioPreparationError {
            guard case .inputFileTooLarge(_, let maxBytes, let actualBytes) = error else {
                return XCTFail("Expected inputFileTooLarge, got \(error).")
            }
            XCTAssertEqual(maxBytes, 1_024)
            XCTAssertEqual(actualBytes, 2_048)
        }
    }

    func testRejectsOverDurationInputBeforeConversion() async throws {
        let input = temporaryRoot.appendingPathComponent("long.wav")
        try Self.writeCanonicalWAV(to: input, durationSeconds: 1.0)
        let service = NativeAudioPreparationService(
            preparedAudioDirectory: temporaryRoot,
            limits: AudioPreparationLimits(
                maxInputFileSizeBytes: 250 * 1_024 * 1_024,
                maxDecodedDurationSeconds: 0.25,
                trackLoadTimeoutSeconds: 60
            )
        )

        do {
            _ = try await service.normalizeAudio(AudioPreparationRequest(inputURL: input))
            XCTFail("Over-duration input should be rejected.")
        } catch let error as AudioPreparationError {
            guard case .inputDurationTooLong(let maxSeconds, let actualSeconds) = error else {
                return XCTFail("Expected inputDurationTooLong, got \(error).")
            }
            XCTAssertEqual(maxSeconds, 0.25)
            XCTAssertGreaterThan(actualSeconds, 0.9)
        }
    }

    func testDecodeTimeoutRemovesPartialOutput() async throws {
        let input = temporaryRoot.appendingPathComponent("timeout-source.wav")
        let output = temporaryRoot.appendingPathComponent("timeout-output.wav")
        try Data("stale output".utf8).write(to: output)
        try Self.writeCanonicalWAV(to: input, durationSeconds: 0.2)
        let service = NativeAudioPreparationService(
            preparedAudioDirectory: temporaryRoot,
            limits: AudioPreparationLimits(
                maxInputFileSizeBytes: 250 * 1_024 * 1_024,
                maxDecodedDurationSeconds: 120,
                trackLoadTimeoutSeconds: 0
            )
        )

        do {
            _ = try await service.normalizeAudio(AudioPreparationRequest(inputURL: input, outputURL: output))
            XCTFail("Zero timeout should reject conversion.")
        } catch let error as AudioPreparationError {
            guard case .decodeTimedOut = error else {
                return XCTFail("Expected decodeTimedOut, got \(error).")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testNormalizationDeadlineRemovesPartialOutput() async throws {
        let input = temporaryRoot.appendingPathComponent("deadline-source.wav")
        let output = temporaryRoot.appendingPathComponent("deadline-output.wav")
        try Self.writeCanonicalWAV(to: input, durationSeconds: 0.2)
        let service = NativeAudioPreparationService(
            preparedAudioDirectory: temporaryRoot,
            limits: AudioPreparationLimits(
                maxInputFileSizeBytes: 250 * 1_024 * 1_024,
                maxDecodedDurationSeconds: 120,
                trackLoadTimeoutSeconds: 60,
                normalizationTimeoutSeconds: 0.01
            ),
            testingHooks: AudioPreparationTestingHooks(
                beforeConversionLoop: {
                    try await Task.sleep(nanoseconds: 30_000_000)
                }
            )
        )

        do {
            _ = try await service.normalizeAudio(AudioPreparationRequest(inputURL: input, outputURL: output))
            XCTFail("Expired normalization deadline should reject conversion.")
        } catch let error as AudioPreparationError {
            guard case .decodeTimedOut = error else {
                return XCTFail("Expected decodeTimedOut, got \(error).")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testNormalizationDeadlineBeforeWriterCreationPreservesTimeoutAndRemovesPartialOutput() async throws {
        let input = temporaryRoot.appendingPathComponent("writer-deadline-source.wav")
        let output = temporaryRoot.appendingPathComponent("writer-deadline-output.wav")
        try Self.writeCanonicalWAV(to: input, durationSeconds: 0.2)
        try Data("stale output".utf8).write(to: output)
        let service = NativeAudioPreparationService(
            preparedAudioDirectory: temporaryRoot,
            limits: AudioPreparationLimits(
                maxInputFileSizeBytes: 250 * 1_024 * 1_024,
                maxDecodedDurationSeconds: 120,
                trackLoadTimeoutSeconds: 60,
                normalizationTimeoutSeconds: 0.01
            ),
            testingHooks: AudioPreparationTestingHooks(
                beforeWriterCreation: {
                    try await Task.sleep(nanoseconds: 30_000_000)
                }
            )
        )

        do {
            _ = try await service.normalizeAudio(AudioPreparationRequest(inputURL: input, outputURL: output))
            XCTFail("Expired normalization deadline should reject writer setup.")
        } catch let error as AudioPreparationError {
            guard case .decodeTimedOut = error else {
                return XCTFail("Expected decodeTimedOut, got \(error).")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCancelledTaskReportsCancellationAndRemovesPartialOutput() async throws {
        let input = temporaryRoot.appendingPathComponent("cancel-source.wav")
        let output = temporaryRoot.appendingPathComponent("cancel-output.wav")
        try Self.writeCanonicalWAV(to: input, durationSeconds: 0.2)
        let gate = ConversionHookGate()
        let service = NativeAudioPreparationService(
            preparedAudioDirectory: temporaryRoot,
            testingHooks: AudioPreparationTestingHooks(
                beforeConversionLoop: {
                    await gate.enterAndWait()
                }
            )
        )
        let task = Task<AudioNormalizationResult, Error> {
            try await service.normalizeAudio(AudioPreparationRequest(inputURL: input, outputURL: output))
        }
        await gate.waitForEntries(1)
        task.cancel()
        await gate.releaseOne()

        do {
            _ = try await task.value
            XCTFail("Cancelled normalization should throw.")
        } catch let error as AudioPreparationError {
            XCTAssertEqual(error, .cancelled)
        } catch is CancellationError {
            // Accept the raw task cancellation shape if the cancellation wins
            // before the service can map it.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testAudioPreparationWorkQueueRunsOneNormalizationAtATime() async throws {
        let firstInput = temporaryRoot.appendingPathComponent("serial-first.wav")
        let secondInput = temporaryRoot.appendingPathComponent("serial-second.wav")
        let firstOutput = temporaryRoot.appendingPathComponent("serial-first-output.wav")
        let secondOutput = temporaryRoot.appendingPathComponent("serial-second-output.wav")
        try Self.writeCanonicalWAV(to: firstInput, durationSeconds: 0.2)
        try Self.writeCanonicalWAV(to: secondInput, durationSeconds: 0.2)
        let gate = ConversionHookGate()
        let service = NativeAudioPreparationService(
            preparedAudioDirectory: temporaryRoot,
            testingHooks: AudioPreparationTestingHooks(
                beforeConversionLoop: {
                    await gate.enterAndWait()
                }
            )
        )

        let firstTask = Task {
            try await service.normalizeAudio(AudioPreparationRequest(inputURL: firstInput, outputURL: firstOutput))
        }
        await gate.waitForEntries(1)

        let secondTask = Task {
            try await service.normalizeAudio(AudioPreparationRequest(inputURL: secondInput, outputURL: secondOutput))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let entryCountWhileFirstIsBlocked = await gate.entryCount
        XCTAssertEqual(entryCountWhileFirstIsBlocked, 1)

        await gate.releaseOne()
        _ = try await firstTask.value
        await gate.waitForEntries(2)
        await gate.releaseOne()
        _ = try await secondTask.value
    }

    func testAudioPreparationDeadlineUsesMonotonicClock() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("QwenVoiceCore", isDirectory: true)
            .appendingPathComponent("AudioPreparation.swift", isDirectory: false)
        let source = try String(contentsOf: sourceURL)
        guard let deadlineRange = source.range(of: "private struct AudioPreparationDeadline"),
              let serviceRange = source.range(of: "public struct NativeAudioPreparationService") else {
            return XCTFail("Could not locate AudioPreparationDeadline source.")
        }
        let deadlineSource = String(source[deadlineRange.lowerBound..<serviceRange.lowerBound])
        XCTAssertTrue(deadlineSource.contains("ContinuousClock.Instant"))
        XCTAssertTrue(deadlineSource.contains("startedAt.duration(to: .now)"))
        XCTAssertFalse(deadlineSource.contains("Date()"))
    }

    private static func writeCanonicalWAV(to url: URL, durationSeconds: Double) throws {
        let sampleRate = 24_000
        let frameCount = Int(durationSeconds * Double(sampleRate))
        var data = Data()
        let pcmByteCount = frameCount * MemoryLayout<Int16>.size
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(UInt32(36 + pcmByteCount))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * MemoryLayout<Int16>.size))
        data.appendLittleEndian(UInt16(MemoryLayout<Int16>.size))
        data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(UInt32(pcmByteCount))
        data.append(Data(repeating: 0, count: pcmByteCount))
        try data.write(to: url)
    }
}

private actor ConversionHookGate {
    private var entries = 0
    private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    var entryCount: Int {
        entries
    }

    func enterAndWait() async {
        entries += 1
        resumeSatisfiedEntryWaiters()
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitForEntries(_ count: Int) async {
        if entries >= count {
            return
        }
        await withCheckedContinuation { continuation in
            entryWaiters.append((count, continuation))
        }
    }

    func releaseOne() {
        guard !releaseWaiters.isEmpty else {
            return
        }
        releaseWaiters.removeFirst().resume()
    }

    private func resumeSatisfiedEntryWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in entryWaiters {
            if entries >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        entryWaiters = remaining
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
