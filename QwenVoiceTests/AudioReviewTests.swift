import AVFoundation
import Foundation
import XCTest
@testable import QwenVoice

final class AudioReviewTests: XCTestCase {
    func testTextMetricsFailWhenFinalWordsAreMissing() throws {
        let report = AudioReview.evaluate(
            input: clipInput(expectedText: "The final sentence should include every important word"),
            transcript: "The final sentence should include every",
            alignment: alignedItems(for: "The final sentence should include every"),
            technicalReport: passingTechnicalReport(),
            acoustic: acoustic(duration: 3.0)
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failureReasons.contains("transcript_completeness"))
        XCTAssertEqual(report.completeness.missingFinalWords, ["important", "word"])
        XCTAssertGreaterThan(report.completeness.wordErrorRate, 0)
    }

    func testBalancedGateKeepsToneAndPacingAdvisory() throws {
        let input = clipInput(
            expectedText: "This delivery should stay very excited and animated while keeping pronunciation clear.",
            deliveryInstruction: "Very excited and animated, energetic and anticipatory, with lively emphasis, controlled pacing, and clear pronunciation."
        )
        let report = AudioReview.evaluate(
            input: input,
            transcript: input.expectedText,
            alignment: alignedItems(for: input.expectedText, spacing: 0.9),
            technicalReport: passingTechnicalReport(),
            acoustic: acoustic(duration: 8.0, energyVariation: 0.03)
        )

        XCTAssertTrue(report.passed)
        XCTAssertTrue(report.tone.advisoryOnly)
        XCTAssertFalse(report.tone.warnings.isEmpty)
        XCTAssertTrue(report.warnings.contains { $0.contains("tone:") })
    }

    func testStrictGateCanFailPacingAndDictionWarnings() throws {
        let input = clipInput(
            expectedText: "Pronunciation-sensitive terminology includes observability and reproducibility.",
            strictness: .strict
        )
        let report = AudioReview.evaluate(
            input: input,
            transcript: "Pronunciation sensitive term includes observability.",
            alignment: [
                .init(text: "Pronunciation", startTime: 0.0, endTime: 0.4),
                .init(text: "sensitive", startTime: 2.0, endTime: 2.4),
                .init(text: "term", startTime: 2.5, endTime: 2.9),
            ],
            technicalReport: passingTechnicalReport(),
            acoustic: acoustic(duration: 6.0)
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failureReasons.contains("transcript_completeness"))
        XCTAssertTrue(report.failureReasons.contains("pacing_cadence"))
        XCTAssertTrue(report.failureReasons.contains("diction_risk"))
        XCTAssertTrue(report.diction.riskyTerms.contains("reproducibility"))
    }

    func testReportEncodingKeepsSchemaAndSummaryFields() throws {
        let input = clipInput(expectedText: "A complete phrase remains easy to inspect.")
        let report = AudioReview.evaluate(
            input: input,
            transcript: input.expectedText,
            alignment: alignedItems(for: input.expectedText),
            technicalReport: passingTechnicalReport(),
            acoustic: acoustic(duration: 2.0)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        let decoded = try JSONDecoder().decode(AudioReview.Report.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, AudioReview.schemaVersion)
        XCTAssertEqual(decoded.clipID, input.clipID)
        XCTAssertTrue(decoded.passed)
        XCTAssertEqual(decoded.transcript, input.expectedText)
    }

    func testPipelineUsesFakeASRAndAlignerFixtures() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwenvoice-audio-review-tests", isDirectory: true)
        try? FileManager.default.removeItem(at: tempDir)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let wavURL = tempDir.appendingPathComponent("clip.wav")
        try writeSineWave(to: wavURL, durationSeconds: 1.4)

        let expected = "A clear local review fixture speaks every word."
        let pipeline = AudioReviewPipeline(
            transcriber: FakeTranscriber(transcript: expected),
            aligner: FakeAligner(items: alignedItems(for: expected, spacing: 0.22))
        )
        let report = try await pipeline.review(
            input: clipInput(expectedText: expected, audioURL: wavURL)
        )

        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.transcript, expected)
        XCTAssertGreaterThan(report.acoustic.durationSeconds, 1.0)
        XCTAssertFalse(report.alignment.isEmpty)
    }

    func testRunManifestMarkdownIncludesFailedClips() throws {
        let manifest = AudioReview.RunManifest(
            schemaVersion: AudioReview.schemaVersion,
            generatedAt: "2026-05-08T00:00:00Z",
            strictness: .balanced,
            modelsRoot: "/tmp/models",
            asrRepoID: AudioReview.defaultASRRepoID,
            forcedAlignerRepoID: AudioReview.defaultForcedAlignerRepoID,
            passed: false,
            skipped: false,
            skipReason: nil,
            memoryGuard: nil,
            reviewedClipCount: 1,
            failedClipCount: 1,
            warningCount: 1,
            clips: [
                .init(
                    clipID: "clip-1",
                    mode: "CustomVoice",
                    phase: "repeat",
                    runIndex: 1,
                    audioPath: "/tmp/clip.wav",
                    reportPath: "/tmp/review.json",
                    transcriptPath: "/tmp/transcript.txt",
                    alignmentPath: "/tmp/alignment.json",
                    passed: false,
                    failureReasons: ["transcript_completeness"],
                    warnings: ["pacing: slow"],
                    wordErrorRate: 0.25,
                    characterErrorRate: 0.12,
                    speechRateWordsPerMinute: 88
                ),
            ]
        )

        let markdown = AudioReviewArtifactWriter.markdown(for: manifest)
        XCTAssertTrue(markdown.contains("Audio Review"))
        XCTAssertTrue(markdown.contains("transcript_completeness"))
        XCTAssertTrue(markdown.contains("clip-1"))
    }

    func testMemoryGuardBlocksReviewWhenHeadroomIsBelowFloor() {
        let snapshot = memorySnapshot(availableHeadroomBytes: 2 * 1_073_741_824)
        let result = AudioReview.evaluateMemoryGuard(
            snapshot: snapshot,
            minimumAvailableMemoryBytes: 4 * 1_073_741_824
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.effectiveAvailableMemoryBytes, 2 * 1_073_741_824)
        XCTAssertTrue(result.reason.contains("skipped local ASR/alignment review"))
    }

    func testMemoryGuardAllowsReviewWhenHeadroomMeetsFloor() {
        let snapshot = memorySnapshot(availableHeadroomBytes: 5 * 1_073_741_824)
        let result = AudioReview.evaluateMemoryGuard(
            snapshot: snapshot,
            minimumAvailableMemoryBytes: 4 * 1_073_741_824
        )

        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.effectiveAvailableMemoryBytes, 5 * 1_073_741_824)
        XCTAssertTrue(result.reason.contains("meets"))
    }

    func testRunManifestMarkdownReportsMemoryGuardSkip() throws {
        let guardResult = AudioReview.evaluateMemoryGuard(
            snapshot: memorySnapshot(availableHeadroomBytes: 1 * 1_073_741_824),
            minimumAvailableMemoryBytes: 4 * 1_073_741_824
        )
        let manifest = try AudioReviewArtifactWriter.writeRunManifest(
            reviewRoot: temporaryDirectory(named: "qwenvoice-audio-review-skip"),
            configuration: AudioReview.RunConfiguration(
                enabled: true,
                modelsRoot: URL(fileURLWithPath: "/tmp/models")
            ),
            clips: [],
            memoryGuard: guardResult,
            skippedReason: guardResult.reason
        )

        XCTAssertTrue(manifest.passed)
        XCTAssertTrue(manifest.skipped)
        XCTAssertEqual(manifest.reviewedClipCount, 0)

        let markdown = AudioReviewArtifactWriter.markdown(for: manifest)
        XCTAssertTrue(markdown.contains("- Status: skipped"))
        XCTAssertTrue(markdown.contains("- Memory guard: blocked"))
        XCTAssertTrue(markdown.contains("Skip reason"))
    }

    private func clipInput(
        expectedText: String,
        deliveryInstruction: String? = nil,
        strictness: AudioReview.Strictness = .balanced,
        audioURL: URL = URL(fileURLWithPath: "/tmp/qwenvoice-audio-review.wav")
    ) -> AudioReview.ClipInput {
        AudioReview.ClipInput(
            clipID: "unit-clip",
            mode: "CustomVoice",
            phase: "repeat",
            runIndex: 1,
            expectedText: expectedText,
            audioURL: audioURL,
            deliveryInstruction: deliveryInstruction,
            strictness: strictness,
            language: AudioReview.defaultLanguage
        )
    }

    private func passingTechnicalReport() -> AudioQualityGate.Report {
        AudioQualityGate.Report(
            passed: true,
            requiredFailures: [],
            warnings: [],
            metrics: [:],
            checks: [
                AudioQualityGate.Check(
                    name: "unit",
                    passed: true,
                    severity: .error,
                    message: nil,
                    metrics: [:]
                ),
            ]
        )
    }

    private func acoustic(
        duration: Double,
        energyVariation: Double = 0.24
    ) -> AudioReview.AcousticFeatures {
        AudioReview.AcousticFeatures(
            durationSeconds: duration,
            rmsMean: 0.08,
            rmsStandardDeviation: 0.08 * energyVariation,
            peak: 0.3,
            voicedWindowRatio: 0.8,
            energyVariation: energyVariation,
            estimatedPitchMeanHz: 170,
            estimatedPitchRangeSemitones: 4
        )
    }

    private func alignedItems(
        for text: String,
        spacing: Double = 0.3
    ) -> [AudioReview.AlignmentItem] {
        AudioReview.normalizedWords(text).enumerated().map { index, word in
            let start = Double(index) * spacing
            return AudioReview.AlignmentItem(
                text: word,
                startTime: start,
                endTime: start + min(0.22, spacing * 0.8)
            )
        }
    }

    private func writeSineWave(
        to url: URL,
        durationSeconds: Double,
        sampleRate: Double = 16_000
    ) throws {
        let frameCount = Int(durationSeconds * sampleRate)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        )!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = buffer.floatChannelData![0]
        for index in 0..<frameCount {
            samples[index] = Float(sin(2 * Double.pi * 220 * Double(index) / sampleRate) * 0.2)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: tempDir)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func memorySnapshot(availableHeadroomBytes: UInt64?) -> AudioReview.MemorySnapshot {
        AudioReview.MemorySnapshot(
            totalMemoryBytes: 8 * 1_073_741_824,
            availableHeadroomBytes: availableHeadroomBytes,
            fallbackAvailableBytes: nil,
            residentBytes: 512 * 1_048_576,
            physicalFootprintBytes: 640 * 1_048_576,
            compressedBytes: nil,
            gpuAllocatedBytes: nil,
            gpuRecommendedWorkingSetBytes: nil,
            mlxActiveMB: 0,
            mlxCacheMB: 0,
            mlxPeakMB: 0
        )
    }
}

private struct FakeTranscriber: AudioReviewTranscribing {
    let transcript: String

    func transcript(for audioURL: URL, language: String) async throws -> String {
        transcript
    }
}

private struct FakeAligner: AudioReviewAligning {
    let items: [AudioReview.AlignmentItem]

    func alignment(
        for audioURL: URL,
        expectedText: String,
        language: String
    ) async throws -> [AudioReview.AlignmentItem] {
        items
    }
}
