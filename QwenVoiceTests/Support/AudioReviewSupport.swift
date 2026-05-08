import AVFoundation
import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT
import QwenVoiceCore
@testable import QwenVoice

enum AudioReview {
    static let schemaVersion = 1
    static let defaultASRRepoID = "mlx-community/Qwen3-ASR-0.6B-4bit"
    static let defaultForcedAlignerRepoID = "mlx-community/Qwen3-ForcedAligner-0.6B-4bit"
    static let defaultLanguage = "English"
    static let defaultMinimumAvailableMemoryBytes: UInt64 = 4 * 1_073_741_824
    static let defaultMemorySettleSeconds = 2.0

    enum Strictness: String, Codable, Sendable {
        case advisory
        case balanced
        case strict

        var shouldFailOnAdvisoryFindings: Bool {
            self == .strict
        }
    }

    struct RunConfiguration: Sendable {
        let enabled: Bool
        let modelsRoot: URL
        let strictness: Strictness
        let language: String
        let asrRepoID: String
        let forcedAlignerRepoID: String
        let minimumAvailableMemoryBytes: UInt64
        let memorySettleSeconds: Double

        init(
            enabled: Bool,
            modelsRoot: URL,
            strictness: Strictness = .balanced,
            language: String = AudioReview.defaultLanguage,
            asrRepoID: String = AudioReview.defaultASRRepoID,
            forcedAlignerRepoID: String = AudioReview.defaultForcedAlignerRepoID,
            minimumAvailableMemoryBytes: UInt64 = AudioReview.defaultMinimumAvailableMemoryBytes,
            memorySettleSeconds: Double = AudioReview.defaultMemorySettleSeconds
        ) {
            self.enabled = enabled
            self.modelsRoot = modelsRoot
            self.strictness = strictness
            self.language = language
            self.asrRepoID = asrRepoID
            self.forcedAlignerRepoID = forcedAlignerRepoID
            self.minimumAvailableMemoryBytes = minimumAvailableMemoryBytes
            self.memorySettleSeconds = memorySettleSeconds
        }

        var memorySettleNanoseconds: UInt64 {
            UInt64(max(0, memorySettleSeconds) * 1_000_000_000)
        }
    }

    struct ClipInput: Sendable {
        let clipID: String
        let mode: String
        let phase: String
        let runIndex: Int
        let expectedText: String
        let audioURL: URL
        let deliveryInstruction: String?
        let strictness: Strictness
        let language: String
    }

    struct Report: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let clipID: String
        let generatedAt: String
        let mode: String
        let phase: String
        let runIndex: Int
        let audioPath: String
        let expectedText: String
        let transcript: String
        let strictness: Strictness
        let passed: Bool
        let failureReasons: [String]
        let warnings: [String]
        let technical: AudioQualityGate.Report
        let completeness: CompletenessReview
        let pacing: PacingReview
        let diction: DictionReview
        let tone: ToneReview
        let acoustic: AcousticFeatures
        let alignment: [AlignmentItem]
    }

    struct CompletenessReview: Codable, Equatable, Sendable {
        let passed: Bool
        let wordErrorRate: Double
        let characterErrorRate: Double
        let expectedWordCount: Int
        let transcriptWordCount: Int
        let insertions: Int
        let deletions: Int
        let substitutions: Int
        let missingFinalWords: [String]
        let missingRequiredTerms: [String]
    }

    struct PacingReview: Codable, Equatable, Sendable {
        let passed: Bool
        let warnings: [String]
        let alignedTokenCount: Int
        let alignmentCoverage: Double
        let speechRateWordsPerMinute: Double?
        let medianWordDurationSeconds: Double?
        let maxPauseSeconds: Double?
        let longPauseCount: Int
        let outlierWordDurations: [AlignmentItem]
    }

    struct DictionReview: Codable, Equatable, Sendable {
        let passed: Bool
        let warnings: [String]
        let substitutionRate: Double
        let deletionRate: Double
        let riskyTerms: [String]
        let substitutions: [WordSubstitution]
    }

    struct ToneReview: Codable, Equatable, Sendable {
        let passed: Bool
        let advisoryOnly: Bool
        let requestedTone: String?
        let detectedProfile: String
        let confidence: String
        let warnings: [String]
        let metrics: [String: Double]
    }

    struct AcousticFeatures: Codable, Equatable, Sendable {
        let durationSeconds: Double
        let rmsMean: Double
        let rmsStandardDeviation: Double
        let peak: Double
        let voicedWindowRatio: Double
        let energyVariation: Double
        let estimatedPitchMeanHz: Double?
        let estimatedPitchRangeSemitones: Double?
    }

    struct AlignmentItem: Codable, Equatable, Sendable {
        let text: String
        let startTime: Double
        let endTime: Double

        var duration: Double {
            max(0, endTime - startTime)
        }
    }

    struct WordSubstitution: Codable, Equatable, Sendable {
        let expected: String
        let actual: String
    }

    struct RunManifest: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let generatedAt: String
        let strictness: Strictness
        let modelsRoot: String
        let asrRepoID: String
        let forcedAlignerRepoID: String
        let passed: Bool
        let skipped: Bool
        let skipReason: String?
        let memoryGuard: MemoryGuardResult?
        let reviewedClipCount: Int
        let failedClipCount: Int
        let warningCount: Int
        let clips: [ClipSummary]
    }

    struct MemorySnapshot: Codable, Equatable, Sendable {
        let totalMemoryBytes: UInt64
        let availableHeadroomBytes: UInt64?
        let fallbackAvailableBytes: UInt64?
        let residentBytes: UInt64?
        let physicalFootprintBytes: UInt64?
        let compressedBytes: UInt64?
        let gpuAllocatedBytes: UInt64?
        let gpuRecommendedWorkingSetBytes: UInt64?
        let mlxActiveMB: Double?
        let mlxCacheMB: Double?
        let mlxPeakMB: Double?

        var effectiveAvailableBytes: UInt64? {
            availableHeadroomBytes ?? fallbackAvailableBytes
        }
    }

    struct MemoryGuardResult: Codable, Equatable, Sendable {
        let passed: Bool
        let minimumAvailableMemoryBytes: UInt64
        let effectiveAvailableMemoryBytes: UInt64?
        let snapshot: MemorySnapshot
        let reason: String
    }

    struct ClipSummary: Codable, Equatable, Sendable {
        let clipID: String
        let mode: String
        let phase: String
        let runIndex: Int
        let audioPath: String
        let reportPath: String
        let transcriptPath: String
        let alignmentPath: String
        let passed: Bool
        let failureReasons: [String]
        let warnings: [String]
        let wordErrorRate: Double
        let characterErrorRate: Double
        let speechRateWordsPerMinute: Double?
    }

    static func parseStrictness(_ rawValue: String?) throws -> Strictness {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return .balanced }
        guard let strictness = Strictness(rawValue: trimmed.lowercased()) else {
            throw NSError(
                domain: "AudioReview",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported audio review strictness '\(trimmed)'."]
            )
        }
        return strictness
    }

    static func trimMLXCacheForReview() {
        Memory.clearCache()
    }

    static func captureMemorySnapshot() -> MemorySnapshot {
        let osSnapshot = IOSMemorySnapshot.capture()
        let mlxSnapshot = NativeMemoryPolicyResolver.snapshot()
        let usedBytes = osSnapshot.physFootprintBytes ?? osSnapshot.residentBytes
        let fallbackAvailable = usedBytes.flatMap { used -> UInt64? in
            guard osSnapshot.totalDeviceRAMBytes > used else { return nil }
            return osSnapshot.totalDeviceRAMBytes - used
        }
        return MemorySnapshot(
            totalMemoryBytes: osSnapshot.totalDeviceRAMBytes,
            availableHeadroomBytes: osSnapshot.availableHeadroomBytes,
            fallbackAvailableBytes: fallbackAvailable,
            residentBytes: osSnapshot.residentBytes,
            physicalFootprintBytes: osSnapshot.physFootprintBytes,
            compressedBytes: osSnapshot.compressedBytes,
            gpuAllocatedBytes: osSnapshot.gpuAllocatedBytes,
            gpuRecommendedWorkingSetBytes: osSnapshot.gpuRecommendedWorkingSetBytes,
            mlxActiveMB: mlxSnapshot.activeMB,
            mlxCacheMB: mlxSnapshot.cacheMB,
            mlxPeakMB: mlxSnapshot.peakMB
        )
    }

    static func evaluateMemoryGuard(
        snapshot: MemorySnapshot,
        minimumAvailableMemoryBytes: UInt64
    ) -> MemoryGuardResult {
        guard let available = snapshot.effectiveAvailableBytes else {
            return MemoryGuardResult(
                passed: false,
                minimumAvailableMemoryBytes: minimumAvailableMemoryBytes,
                effectiveAvailableMemoryBytes: nil,
                snapshot: snapshot,
                reason: "Unable to measure process memory headroom; skipped local ASR/alignment review to avoid memory-pressure termination."
            )
        }

        let passed = available >= minimumAvailableMemoryBytes
        let reason = passed
            ? "Available memory headroom \(formattedBytes(available)) meets the \(formattedBytes(minimumAvailableMemoryBytes)) guard."
            : "Available memory headroom \(formattedBytes(available)) is below the \(formattedBytes(minimumAvailableMemoryBytes)) guard; skipped local ASR/alignment review to avoid memory-pressure termination."
        return MemoryGuardResult(
            passed: passed,
            minimumAvailableMemoryBytes: minimumAvailableMemoryBytes,
            effectiveAvailableMemoryBytes: available,
            snapshot: snapshot,
            reason: reason
        )
    }

    private static func formattedBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.includesCount = true
        return formatter.string(fromByteCount: Int64(bytes))
    }

    static func normalizedWords(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current.removeAll(keepingCapacity: true)
        }

        let apostrophe = UnicodeScalar("'")
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == apostrophe {
                current.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    static func normalizedCharacters(_ text: String) -> [Character] {
        Array(normalizedWords(text).joined(separator: " "))
    }

    static func evaluate(
        input: ClipInput,
        transcript: String,
        alignment: [AlignmentItem],
        technicalReport: AudioQualityGate.Report,
        acoustic: AcousticFeatures,
        generatedAt: String = ISO8601DateFormatter().string(from: Date())
    ) -> Report {
        let expectedWords = normalizedWords(input.expectedText)
        let transcriptWords = normalizedWords(transcript)
        let wordEdit = editSummary(expected: expectedWords, actual: transcriptWords)
        let characterEdit = editDistance(
            expected: normalizedCharacters(input.expectedText),
            actual: normalizedCharacters(transcript)
        )

        let wordErrorRate = rate(wordEdit.distance, expectedWords.count)
        let characterErrorRate = rate(characterEdit, max(normalizedCharacters(input.expectedText).count, 1))
        let missingFinalWords = missingFinalWords(expected: expectedWords, actual: transcriptWords)
        let missingRequiredTerms = missingRequiredTerms(expected: expectedWords, actual: transcriptWords)

        let completenessPassed = wordErrorRate <= 0.18
            && characterErrorRate <= 0.12
            && missingFinalWords.isEmpty
            && missingRequiredTerms.isEmpty
        let completeness = CompletenessReview(
            passed: completenessPassed,
            wordErrorRate: wordErrorRate,
            characterErrorRate: characterErrorRate,
            expectedWordCount: expectedWords.count,
            transcriptWordCount: transcriptWords.count,
            insertions: wordEdit.insertions,
            deletions: wordEdit.deletions,
            substitutions: wordEdit.substitutions.count,
            missingFinalWords: missingFinalWords,
            missingRequiredTerms: missingRequiredTerms
        )

        let pacing = pacingReview(
            expectedWordCount: expectedWords.count,
            alignment: alignment,
            durationSeconds: acoustic.durationSeconds
        )
        let diction = dictionReview(
            expectedWordCount: expectedWords.count,
            editSummary: wordEdit,
            missingRequiredTerms: missingRequiredTerms
        )
        let tone = toneReview(
            requestedInstruction: input.deliveryInstruction,
            acoustic: acoustic,
            pacing: pacing
        )

        var failureReasons = technicalReport.requiredFailures
        if !completeness.passed {
            failureReasons.append("transcript_completeness")
        }
        if input.strictness == .strict {
            if !pacing.passed {
                failureReasons.append("pacing_cadence")
            }
            if !diction.passed {
                failureReasons.append("diction_risk")
            }
            if !tone.passed {
                failureReasons.append("tone_style_match")
            }
        }

        var warnings = technicalReport.warnings
        if !pacing.warnings.isEmpty {
            warnings.append(contentsOf: pacing.warnings.map { "pacing: \($0)" })
        }
        if !diction.warnings.isEmpty {
            warnings.append(contentsOf: diction.warnings.map { "diction: \($0)" })
        }
        if !tone.warnings.isEmpty {
            warnings.append(contentsOf: tone.warnings.map { "tone: \($0)" })
        }

        return Report(
            schemaVersion: schemaVersion,
            clipID: input.clipID,
            generatedAt: generatedAt,
            mode: input.mode,
            phase: input.phase,
            runIndex: input.runIndex,
            audioPath: input.audioURL.path,
            expectedText: input.expectedText,
            transcript: transcript,
            strictness: input.strictness,
            passed: failureReasons.isEmpty,
            failureReasons: failureReasons,
            warnings: warnings,
            technical: technicalReport,
            completeness: completeness,
            pacing: pacing,
            diction: diction,
            tone: tone,
            acoustic: acoustic,
            alignment: alignment
        )
    }

    private static func rate(_ editDistance: Int, _ denominator: Int) -> Double {
        guard denominator > 0 else {
            return editDistance == 0 ? 0 : 1
        }
        return Double(editDistance) / Double(denominator)
    }

    private struct EditSummary {
        let distance: Int
        let insertions: Int
        let deletions: Int
        let substitutions: [WordSubstitution]

        var substitutionRateDenominator: Int {
            max(insertions + deletions + substitutions.count, 1)
        }
    }

    private static func editSummary(expected: [String], actual: [String]) -> EditSummary {
        let rows = expected.count + 1
        let columns = actual.count + 1
        var costs = Array(repeating: Array(repeating: 0, count: columns), count: rows)

        for row in 0..<rows { costs[row][0] = row }
        for column in 0..<columns { costs[0][column] = column }

        if rows > 1 && columns > 1 {
            for row in 1..<rows {
                for column in 1..<columns {
                    if expected[row - 1] == actual[column - 1] {
                        costs[row][column] = costs[row - 1][column - 1]
                    } else {
                        costs[row][column] = min(
                            costs[row - 1][column] + 1,
                            costs[row][column - 1] + 1,
                            costs[row - 1][column - 1] + 1
                        )
                    }
                }
            }
        }

        var row = expected.count
        var column = actual.count
        var insertions = 0
        var deletions = 0
        var substitutions: [WordSubstitution] = []

        while row > 0 || column > 0 {
            if row > 0,
               column > 0,
               expected[row - 1] == actual[column - 1],
               costs[row][column] == costs[row - 1][column - 1] {
                row -= 1
                column -= 1
            } else if row > 0,
                      column > 0,
                      costs[row][column] == costs[row - 1][column - 1] + 1 {
                substitutions.append(WordSubstitution(expected: expected[row - 1], actual: actual[column - 1]))
                row -= 1
                column -= 1
            } else if row > 0,
                      costs[row][column] == costs[row - 1][column] + 1 {
                deletions += 1
                row -= 1
            } else {
                insertions += 1
                column -= 1
            }
        }

        return EditSummary(
            distance: costs[expected.count][actual.count],
            insertions: insertions,
            deletions: deletions,
            substitutions: Array(substitutions.reversed())
        )
    }

    private static func editDistance<T: Equatable>(expected: [T], actual: [T]) -> Int {
        let rows = expected.count + 1
        let columns = actual.count + 1
        var previous = Array(0..<columns)
        var current = Array(repeating: 0, count: columns)

        guard rows > 1 else { return actual.count }
        for row in 1..<rows {
            current[0] = row
            if columns > 1 {
                for column in 1..<columns {
                    if expected[row - 1] == actual[column - 1] {
                        current[column] = previous[column - 1]
                    } else {
                        current[column] = min(
                            previous[column] + 1,
                            current[column - 1] + 1,
                            previous[column - 1] + 1
                        )
                    }
                }
            }
            swap(&previous, &current)
        }
        return previous[actual.count]
    }

    private static func missingFinalWords(expected: [String], actual: [String]) -> [String] {
        let suffix = Array(expected.suffix(min(5, expected.count)))
        guard !suffix.isEmpty else { return [] }
        if actual.suffix(suffix.count).elementsEqual(suffix) {
            return []
        }
        return suffix.filter { !actual.contains($0) }
    }

    private static func missingRequiredTerms(expected: [String], actual: [String]) -> [String] {
        let candidates = expected.filter { word in
            word.count >= 10 || word.contains { $0.isNumber }
        }
        var seen = Set<String>()
        return candidates.filter { term in
            seen.insert(term).inserted && !actual.contains(term)
        }
    }

    private static func pacingReview(
        expectedWordCount: Int,
        alignment: [AlignmentItem],
        durationSeconds: Double
    ) -> PacingReview {
        let aligned = alignment.filter { $0.duration > 0 }
        let coverage = expectedWordCount == 0 ? 1 : Double(aligned.count) / Double(expectedWordCount)
        let speechDuration = aligned.last.map { max($0.endTime, durationSeconds) } ?? durationSeconds
        let wpm = speechDuration > 0 ? Double(expectedWordCount) / speechDuration * 60 : nil
        let durations = aligned.map(\.duration)
        let medianDuration = durations.isEmpty ? nil : median(durations)

        let pauses = zip(aligned, aligned.dropFirst()).map { previous, next in
            max(0, next.startTime - previous.endTime)
        }
        let maxPause = pauses.max()
        let longPauses = pauses.filter { $0 >= 0.85 }
        let outliers = aligned.filter { $0.duration >= 1.25 && normalizedWords($0.text).first?.count ?? 0 <= 12 }

        var warnings: [String] = []
        if coverage < 0.82 {
            warnings.append("forced alignment covered \(Int(coverage * 100))% of expected words")
        }
        if let wpm, wpm < 95 {
            warnings.append("speech rate is slow at \(Int(wpm)) words per minute")
        }
        if let wpm, wpm > 215 {
            warnings.append("speech rate is fast at \(Int(wpm)) words per minute")
        }
        if let maxPause, maxPause >= 1.2 {
            warnings.append("longest internal pause is \(String(format: "%.2f", maxPause)) seconds")
        }
        if !outliers.isEmpty {
            warnings.append("\(outliers.count) aligned word(s) have unusually long durations")
        }

        return PacingReview(
            passed: warnings.isEmpty || coverage >= 0.75,
            warnings: warnings,
            alignedTokenCount: aligned.count,
            alignmentCoverage: coverage,
            speechRateWordsPerMinute: wpm,
            medianWordDurationSeconds: medianDuration,
            maxPauseSeconds: maxPause,
            longPauseCount: longPauses.count,
            outlierWordDurations: Array(outliers.prefix(8))
        )
    }

    private static func dictionReview(
        expectedWordCount: Int,
        editSummary: EditSummary,
        missingRequiredTerms: [String]
    ) -> DictionReview {
        let denominator = max(expectedWordCount, 1)
        let substitutionRate = Double(editSummary.substitutions.count) / Double(denominator)
        let deletionRate = Double(editSummary.deletions) / Double(denominator)
        let riskyTerms = missingRequiredTerms

        var warnings: [String] = []
        if substitutionRate > 0.08 {
            warnings.append("substitution rate is \(String(format: "%.2f", substitutionRate))")
        }
        if deletionRate > 0.08 {
            warnings.append("deletion rate is \(String(format: "%.2f", deletionRate))")
        }
        if !riskyTerms.isEmpty {
            warnings.append("pronunciation-sensitive or long terms missing: \(riskyTerms.joined(separator: ", "))")
        }

        return DictionReview(
            passed: warnings.isEmpty,
            warnings: warnings,
            substitutionRate: substitutionRate,
            deletionRate: deletionRate,
            riskyTerms: riskyTerms,
            substitutions: Array(editSummary.substitutions.prefix(12))
        )
    }

    private static func toneReview(
        requestedInstruction: String?,
        acoustic: AcousticFeatures,
        pacing: PacingReview
    ) -> ToneReview {
        let tone = requestedTone(from: requestedInstruction)
        var warnings: [String] = []
        let wpm = pacing.speechRateWordsPerMinute

        switch tone {
        case "happy", "excited":
            if let wpm, wpm < 120 {
                warnings.append("requested bright delivery but measured pace is subdued")
            }
            if acoustic.energyVariation < 0.18 {
                warnings.append("requested bright delivery but energy variation is low")
            }
        case "angry", "fearful", "dramatic":
            if acoustic.energyVariation < 0.16 {
                warnings.append("requested high expression but energy contour is flat")
            }
        case "calm", "sad":
            if let wpm, wpm > 190 {
                warnings.append("requested restrained delivery but measured pace is fast")
            }
        case "whisper":
            if acoustic.voicedWindowRatio > 0.95 && acoustic.energyVariation < 0.10 {
                warnings.append("whisper requests need manual calibration; measured signal is very uniform")
            }
        default:
            break
        }

        let detected = detectedProfile(acoustic: acoustic, pacing: pacing)
        return ToneReview(
            passed: warnings.isEmpty,
            advisoryOnly: true,
            requestedTone: tone,
            detectedProfile: detected,
            confidence: tone == nil ? "none" : "low",
            warnings: warnings,
            metrics: [
                "energy_variation": acoustic.energyVariation,
                "voiced_window_ratio": acoustic.voicedWindowRatio,
                "speech_rate_wpm": wpm ?? 0,
                "pitch_range_semitones": acoustic.estimatedPitchRangeSemitones ?? 0,
            ]
        )
    }

    private static func requestedTone(from instruction: String?) -> String? {
        guard let instruction = instruction?.lowercased() else { return nil }
        let candidates = ["happy", "excited", "angry", "fearful", "sad", "calm", "whisper", "dramatic"]
        return candidates.first { instruction.contains($0) }
    }

    private static func detectedProfile(acoustic: AcousticFeatures, pacing: PacingReview) -> String {
        let wpm = pacing.speechRateWordsPerMinute ?? 0
        if wpm >= 190 || acoustic.energyVariation >= 0.35 {
            return "energetic"
        }
        if wpm > 0 && wpm <= 115 {
            return "slow"
        }
        if acoustic.energyVariation <= 0.12 {
            return "steady"
        }
        return "moderate"
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let midpoint = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[midpoint - 1] + sorted[midpoint]) / 2
        }
        return sorted[midpoint]
    }
}

protocol AudioReviewTranscribing: Sendable {
    func transcript(for audioURL: URL, language: String) async throws -> String
}

protocol AudioReviewAligning: Sendable {
    func alignment(for audioURL: URL, expectedText: String, language: String) async throws -> [AudioReview.AlignmentItem]
}

struct AudioReviewPipeline: Sendable {
    let transcriber: any AudioReviewTranscribing
    let aligner: any AudioReviewAligning

    func review(input: AudioReview.ClipInput) async throws -> AudioReview.Report {
        let technical = AudioQualityGate.evaluate(url: input.audioURL)
        let acoustic = try AudioReviewAcousticAnalyzer.analyze(url: input.audioURL)
        let transcript = try await transcriber.transcript(for: input.audioURL, language: input.language)
        AudioReview.trimMLXCacheForReview()
        let alignment = try await aligner.alignment(
            for: input.audioURL,
            expectedText: input.expectedText,
            language: input.language
        )
        AudioReview.trimMLXCacheForReview()
        return AudioReview.evaluate(
            input: input,
            transcript: transcript,
            alignment: alignment,
            technicalReport: technical,
            acoustic: acoustic
        )
    }
}

final class Qwen3AudioReviewModels: @unchecked Sendable, AudioReviewTranscribing, AudioReviewAligning {
    private let asrModel: Qwen3ASRModel
    private let alignerModel: Qwen3ForcedAlignerModel

    init(configuration: AudioReview.RunConfiguration) async throws {
        try Self.validatePreparedCache(configuration: configuration)
        let cache = HubCache(cacheDirectory: configuration.modelsRoot)
        self.asrModel = try await Qwen3ASRModel.fromPretrained(configuration.asrRepoID, cache: cache)
        self.alignerModel = try await Qwen3ForcedAlignerModel.fromPretrained(
            configuration.forcedAlignerRepoID,
            cache: cache
        )
    }

    func transcript(for audioURL: URL, language: String) async throws -> String {
        let (_, audio) = try loadAudioArray(from: audioURL, sampleRate: 16_000)
        let output = asrModel.generate(
            audio: audio,
            generationParameters: STTGenerateParameters(
                maxTokens: 1_024,
                temperature: 0,
                language: language
            )
        )
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func alignment(
        for audioURL: URL,
        expectedText: String,
        language: String
    ) async throws -> [AudioReview.AlignmentItem] {
        let (_, audio) = try loadAudioArray(from: audioURL, sampleRate: 16_000)
        let result = alignerModel.generate(
            audio: audio,
            text: expectedText,
            language: language
        )
        return result.items.map {
            AudioReview.AlignmentItem(
                text: $0.text,
                startTime: $0.startTime,
                endTime: $0.endTime
            )
        }
    }

    static func validatePreparedCache(configuration: AudioReview.RunConfiguration) throws {
        try validatePreparedModel(
            repoID: configuration.asrRepoID,
            modelsRoot: configuration.modelsRoot
        )
        try validatePreparedModel(
            repoID: configuration.forcedAlignerRepoID,
            modelsRoot: configuration.modelsRoot
        )
    }

    private static func validatePreparedModel(repoID: String, modelsRoot: URL) throws {
        let directory = modelsRoot
            .appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent(repoID.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        let configPath = directory.appendingPathComponent("config.json")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let hasWeights = files.contains { $0.pathExtension == "safetensors" }
        guard FileManager.default.fileExists(atPath: configPath.path), hasWeights else {
            throw NSError(
                domain: "AudioReview",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Missing prepared audio review model '\(repoID)' under \(directory.path). Run scripts/bootstrap_audio_review_models.sh before enabling QWENVOICE_AUDIO_REVIEW_ENABLED=1."
                ]
            )
        }
    }
}

enum AudioReviewAcousticAnalyzer {
    static func analyze(url: URL) throws -> AudioReview.AcousticFeatures {
        let file = try AVAudioFile(forReading: url)
        let frameCount = Int(file.length)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw NSError(
                domain: "AudioReview",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unable to allocate audio buffer."]
            )
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            throw NSError(
                domain: "AudioReview",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Unable to read floating point audio samples."]
            )
        }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        let sampleRate = file.processingFormat.sampleRate
        let duration = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        let peak = samples.map { abs(Double($0)) }.max() ?? 0
        let windowSize = max(1, Int(sampleRate * 0.05))
        var rmsWindows: [Double] = []
        var pitchEstimates: [Double] = []

        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + windowSize)
            let window = Array(samples[index..<end])
            let rms = rootMeanSquare(window)
            rmsWindows.append(rms)
            if rms > 0.002, let pitch = estimatePitch(window, sampleRate: sampleRate) {
                pitchEstimates.append(pitch)
            }
            index += windowSize
        }

        let rmsMean = mean(rmsWindows)
        let rmsStdDev = standardDeviation(rmsWindows, mean: rmsMean)
        let voicedRatio = rmsWindows.isEmpty
            ? 0
            : Double(rmsWindows.filter { $0 > 0.002 }.count) / Double(rmsWindows.count)
        let energyVariation = rmsMean > 0 ? rmsStdDev / rmsMean : 0
        let pitchMean = pitchEstimates.isEmpty ? nil : mean(pitchEstimates)
        let pitchRange = pitchEstimates.count < 2 ? nil : semitoneRange(pitchEstimates)

        return AudioReview.AcousticFeatures(
            durationSeconds: duration,
            rmsMean: rmsMean,
            rmsStandardDeviation: rmsStdDev,
            peak: peak,
            voicedWindowRatio: voicedRatio,
            energyVariation: energyVariation,
            estimatedPitchMeanHz: pitchMean,
            estimatedPitchRangeSemitones: pitchRange
        )
    }

    private static func rootMeanSquare(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(0.0) { partial, sample in
            let value = Double(sample)
            return partial + value * value
        }
        return sqrt(sumSquares / Double(samples.count))
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func standardDeviation(_ values: [Double], mean: Double) -> Double {
        guard values.count > 1 else { return 0 }
        let variance = values.reduce(0.0) { partial, value in
            let delta = value - mean
            return partial + delta * delta
        } / Double(values.count)
        return sqrt(variance)
    }

    private static func estimatePitch(_ samples: [Float], sampleRate: Double) -> Double? {
        guard samples.count > 8, sampleRate > 0 else { return nil }
        let minLag = max(1, Int(sampleRate / 420))
        let maxLag = min(samples.count / 2, Int(sampleRate / 70))
        guard minLag < maxLag else { return nil }

        var bestLag = minLag
        var bestCorrelation = 0.0
        for lag in minLag...maxLag {
            var correlation = 0.0
            var energy = 0.0
            for index in 0..<(samples.count - lag) {
                let a = Double(samples[index])
                let b = Double(samples[index + lag])
                correlation += a * b
                energy += a * a + b * b
            }
            guard energy > 0 else { continue }
            let normalized = correlation / energy
            if normalized > bestCorrelation {
                bestCorrelation = normalized
                bestLag = lag
            }
        }
        guard bestCorrelation > 0.12 else { return nil }
        return sampleRate / Double(bestLag)
    }

    private static func semitoneRange(_ pitches: [Double]) -> Double? {
        let positive = pitches.filter { $0 > 0 }
        guard let minPitch = positive.min(), let maxPitch = positive.max(), minPitch > 0 else {
            return nil
        }
        return 12 * log2(maxPitch / minPitch)
    }
}

enum AudioReviewArtifactWriter {
    private static var artifactEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func writeClipArtifacts(
        report: AudioReview.Report,
        reviewRoot: URL
    ) throws -> AudioReview.ClipSummary {
        let clipRoot = reviewRoot
            .appendingPathComponent("clips", isDirectory: true)
            .appendingPathComponent(report.clipID, isDirectory: true)
        try FileManager.default.createDirectory(at: clipRoot, withIntermediateDirectories: true)

        let reportURL = clipRoot.appendingPathComponent("review.json")
        let transcriptURL = clipRoot.appendingPathComponent("transcript.txt")
        let alignmentURL = clipRoot.appendingPathComponent("alignment.json")

        try artifactEncoder.encode(report).write(to: reportURL)
        try report.transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try artifactEncoder.encode(report.alignment).write(to: alignmentURL)

        return AudioReview.ClipSummary(
            clipID: report.clipID,
            mode: report.mode,
            phase: report.phase,
            runIndex: report.runIndex,
            audioPath: report.audioPath,
            reportPath: reportURL.path,
            transcriptPath: transcriptURL.path,
            alignmentPath: alignmentURL.path,
            passed: report.passed,
            failureReasons: report.failureReasons,
            warnings: report.warnings,
            wordErrorRate: report.completeness.wordErrorRate,
            characterErrorRate: report.completeness.characterErrorRate,
            speechRateWordsPerMinute: report.pacing.speechRateWordsPerMinute
        )
    }

    static func writeRunManifest(
        reviewRoot: URL,
        configuration: AudioReview.RunConfiguration,
        clips: [AudioReview.ClipSummary],
        memoryGuard: AudioReview.MemoryGuardResult? = nil,
        skippedReason: String? = nil
    ) throws -> AudioReview.RunManifest {
        try FileManager.default.createDirectory(at: reviewRoot, withIntermediateDirectories: true)
        let skipped = skippedReason != nil
        let manifest = AudioReview.RunManifest(
            schemaVersion: AudioReview.schemaVersion,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            strictness: configuration.strictness,
            modelsRoot: configuration.modelsRoot.path,
            asrRepoID: configuration.asrRepoID,
            forcedAlignerRepoID: configuration.forcedAlignerRepoID,
            passed: skipped || clips.allSatisfy(\.passed),
            skipped: skipped,
            skipReason: skippedReason,
            memoryGuard: memoryGuard,
            reviewedClipCount: clips.count,
            failedClipCount: clips.filter { !$0.passed }.count,
            warningCount: clips.reduce(0) { $0 + $1.warnings.count },
            clips: clips
        )
        try artifactEncoder.encode(manifest)
            .write(to: reviewRoot.appendingPathComponent("audio-review-manifest.json"))
        try markdown(for: manifest)
            .write(to: reviewRoot.appendingPathComponent("audio-review.md"), atomically: true, encoding: .utf8)
        return manifest
    }

    static func markdown(for manifest: AudioReview.RunManifest) -> String {
        let status = manifest.skipped ? "skipped" : (manifest.passed ? "passed" : "failed")
        var lines: [String] = [
            "# Audio Review",
            "",
            "- Status: \(status)",
            "- Reviewed clips: \(manifest.reviewedClipCount)",
            "- Failed clips: \(manifest.failedClipCount)",
            "- Warnings: \(manifest.warningCount)",
            "- Strictness: \(manifest.strictness.rawValue)",
            "- ASR model: \(manifest.asrRepoID)",
            "- Forced aligner: \(manifest.forcedAlignerRepoID)",
        ]
        if let memoryGuard = manifest.memoryGuard {
            lines.append("- Memory guard: \(memoryGuard.passed ? "passed" : "blocked")")
            lines.append("- Memory headroom: \(byteSummary(memoryGuard.effectiveAvailableMemoryBytes)) / required \(byteSummary(memoryGuard.minimumAvailableMemoryBytes))")
        }
        if let skipReason = manifest.skipReason {
            lines.append("- Skip reason: \(skipReason)")
        }
        lines.append(contentsOf: [
            "",
            "| Clip | Mode | Phase | WER | CER | WPM | Status |",
            "| --- | --- | --- | ---: | ---: | ---: | --- |",
        ])
        for clip in manifest.clips {
            let wpm = clip.speechRateWordsPerMinute.map { String(format: "%.0f", $0) } ?? "-"
            lines.append(
                "| \(clip.clipID) | \(clip.mode) | \(clip.phase) | \(String(format: "%.3f", clip.wordErrorRate)) | \(String(format: "%.3f", clip.characterErrorRate)) | \(wpm) | \(clip.passed ? "passed" : "failed") |"
            )
        }
        if manifest.clips.contains(where: { !$0.failureReasons.isEmpty || !$0.warnings.isEmpty }) {
            lines.append(contentsOf: ["", "## Findings"])
            for clip in manifest.clips where !clip.failureReasons.isEmpty || !clip.warnings.isEmpty {
                lines.append("")
                lines.append("### \(clip.clipID)")
                if !clip.failureReasons.isEmpty {
                    lines.append("- Failures: \(clip.failureReasons.joined(separator: ", "))")
                }
                if !clip.warnings.isEmpty {
                    lines.append("- Warnings: \(clip.warnings.joined(separator: "; "))")
                }
                lines.append("- Report: \(clip.reportPath)")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func byteSummary(_ bytes: UInt64?) -> String {
        guard let bytes else { return "unavailable" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
