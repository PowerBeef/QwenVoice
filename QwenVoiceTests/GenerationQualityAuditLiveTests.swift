import QwenVoiceCore
import AVFoundation
import Foundation
import Dispatch
import XCTest
@testable import QwenVoice
@testable import QwenVoiceNative
import QwenVoiceEngineSupport

final class GenerationQualityAuditLiveTests: XCTestCase {
    private enum AuditMode: String, CaseIterable {
        case customVoice = "CustomVoice"
        case voiceDesign = "VoiceDesign"
        case clones = "Clones"

        static func parse(_ rawName: String) -> AuditMode? {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case Self.customVoice.rawValue:
                return .customVoice
            case Self.voiceDesign.rawValue:
                return .voiceDesign
            case Self.clones.rawValue, "VoiceCloning":
                return .clones
            default:
                return nil
            }
        }

        var modelID: String {
            switch self {
            case .customVoice:
                "pro_custom"
            case .voiceDesign:
                "pro_design"
            case .clones:
                "pro_clone"
            }
        }

        var fileStem: String {
            switch self {
            case .customVoice:
                "custom-voice"
            case .voiceDesign:
                "voice-design"
            case .clones:
                "voice-clone"
            }
        }

        var generationMode: QwenVoiceCore.GenerationMode {
            switch self {
            case .customVoice:
                .custom
            case .voiceDesign:
                .design
            case .clones:
                .clone
            }
        }
    }

    private enum BenchmarkProfile: String {
        case standard = "repeat"
        case coldWarm = "cold-warm"
        case warmFocus = "warm-focus"
        case customUICold = "custom-ui-cold"
        case exhaustive
        case deliveryMatrix = "delivery-matrix"
    }

    private enum AuditVariant: String, CaseIterable, Codable {
        case speed
        case quality

        var displayName: String {
            switch self {
            case .speed:
                "Speed"
            case .quality:
                "Quality"
            }
        }

        var bitDepthLabel: String {
            switch self {
            case .speed:
                "4-bit"
            case .quality:
                "8-bit"
            }
        }
    }

    private enum DeliveryAuditScope: String {
        case standard
        case full
        case knownRisk = "known-risk"
        case whisperRisk = "whisper-risk"
    }

    private struct CloneAuditReference: Codable, Equatable {
        let path: String
        let transcript: String?
        let label: String
    }

    private enum AuditPhase: String {
        case standard = "repeat"
        case cold
        case warm
        case primer
        case endurance
        case direct900 = "direct-900"
        case direct2700 = "direct-2700"
        case batchLongForm = "batch-long-form"
        case deliveryMatrix = "delivery-matrix"
    }

    private struct AuditManifest: Codable {
        let generatedAt: String
        let benchmarkProfile: String
        let coldRuns: Int?
        let warmRuns: Int?
        let appSupportDirectory: String
        let modelsRoot: String
        let artifacts: [AuditArtifact]
        let longText: LongTextManifest?
        let deliveryMatrix: DeliveryAuditManifest?
        let audioReview: AudioReview.RunManifest?
    }

    private struct AuditArtifact: Codable {
        let iteration: Int
        let phase: String
        let runIndex: Int
        let measured: Bool
        let qcEligible: Bool
        let mode: String
        let modelID: String
        let text: String
        let textCharacterCount: Int
        let textWordCount: Int
        let segmentCount: Int?
        let segmentIndex: Int?
        let batchTotal: Int?
        let speakerID: String?
        let deliveryInstruction: String?
        let resolvedQwenInstruction: String?
        let deliveryAuditCaseID: String?
        let deliveryPresetID: String?
        let deliveryIntensity: String?
        let deliveryVoiceDescription: String?
        let deliveryReferenceToneLabel: String?
        let modelVariantKind: String?
        let modelBitDepth: String?
        let appSupportDirectory: String
        let outputPath: String
        let streamSessionDirectory: String?
        let durationSeconds: Double
        let audioFeatures: AudioFeatureSummary?
        let wallClockMS: Int
        let realTimeFactor: Double?
        let streamingUsed: Bool
        let timingsMS: [String: Int]
        let booleanFlags: [String: Bool]
        let stringFlags: [String: String]
    }

    private struct AudioFeatureSummary: Codable, Equatable {
        let durationSeconds: Double
        let rmsAmplitude: Double?
        let peakAmplitude: Double?
        let clippingSampleCount: Int
        let estimatedWordsPerMinute: Double?
    }

    private struct DeliveryAuditCase: Codable, Equatable {
        let id: String
        let presetID: String?
        let intensity: String?
        let customText: String?
        let deliveryInstruction: String?
        let voiceDescription: String?
        let speakerID: String?
        let cloneReferencePath: String?
        let cloneTranscript: String?
        let text: String
        let referenceToneLabel: String?
    }

    private struct DeliveryAuditManifest: Codable, Equatable {
        let schemaVersion: Int
        let generatedAt: String
        let variants: [String]
        let scope: String
        let artifacts: [String]
        let skippedRows: [SkippedRow]

        struct SkippedRow: Codable, Equatable {
            let mode: String
            let variant: String
            let caseID: String?
            let reason: String
        }
    }

    private struct SelectedPrefetchDiagnostics {
        var timingsMS: [String: Int]
        var booleanFlags: [String: Bool]
    }

    private struct LongTextManifest: Codable {
        var schemaVersion: Int = 1
        var generatedAt: String = ISO8601DateFormatter().string(from: Date())
        var segmentMaxCharacters: Int = LongFormBatchSegmenter.defaultMaxCharacters
        var directCases: [DirectCase] = []
        var batchCases: [BatchCase] = []
        var boundedFailures: [BoundedFailure] = []

        struct DirectCase: Codable {
            let mode: String
            let phase: String
            let characterCount: Int
            let wordCount: Int
            let outputPath: String?
            let error: String?
        }

        struct BatchCase: Codable {
            let mode: String
            let characterCount: Int
            let wordCount: Int
            let segmentCount: Int
            let generated: Int
            let failed: Int
            let totalAudioDurationSeconds: Double
            let segmentOutputPaths: [String?]
        }

        struct BoundedFailure: Codable {
            let mode: String
            let phase: String
            let characterCount: Int
            let wordCount: Int
            let error: String
        }
    }

    private struct AuditRunResult {
        var artifacts: [AuditArtifact]
        var longText: LongTextManifest?
        var deliveryMatrix: DeliveryAuditManifest? = nil
    }

    private struct InitializedAuditClient {
        let client: XPCNativeEngineClient
        let timingsMS: [String: Int]
    }

    private struct LiveAuditRequest: Codable {
        let live: Bool
        let allowModelLoad: Bool
        let outputDirectory: String
        let modes: [String]
        let modelsRoot: String
        let cloneReference: String?
        let cloneTranscript: String?
        let repeatCount: Int?
        let benchmarkProfile: String?
        let coldRuns: Int?
        let warmRuns: Int?
        let streamingIntervalOverride: Double?
        let customPrewarmDepth: String?
        let customVoiceProfile: String?
        let streamStepEvalPolicy: String?
        let generationSpeedProfile: String?
        let memoryClearCadence: Int?
        let postRequestCachePolicy: String?
        let deliveryAuditVariants: [String]?
        let deliveryAuditScope: String?
        let cloneReferences: [String]?
        let cloneToneLabel: String?
        let expiresAt: String?
        let audioReviewEnabled: Bool?
        let audioReviewModelsRoot: String?
        let audioReviewStrictness: String?
        let audioReviewMinimumAvailableGB: Double?
        let audioReviewMemorySettleSeconds: Double?
    }

    private struct LiveAuditConfiguration {
        let outputRoot: URL
        let modelsRoot: URL
        let modes: [AuditMode]
        let cloneReference: String?
        let cloneTranscript: String?
        let repeatCount: Int
        let benchmarkProfile: BenchmarkProfile
        let coldRuns: Int
        let warmRuns: Int
        let streamingIntervalOverride: Double?
        let customPrewarmDepth: String?
        let customVoiceProfile: String?
        let streamStepEvalPolicy: String?
        let generationSpeedProfile: String?
        let memoryClearCadence: Int?
        let postRequestCachePolicy: String?
        let deliveryAuditVariants: [AuditVariant]
        let deliveryAuditScope: DeliveryAuditScope
        let cloneReferences: [CloneAuditReference]
        let cloneToneLabel: String?
        let audioReview: AudioReview.RunConfiguration?
    }

    func testWarmFocusBenchmarkProfileUsesWarmRunLayout() throws {
        XCTAssertEqual(try parseBenchmarkProfile("warm-focus"), .warmFocus)

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qwenvoice-warm-focus-test", isDirectory: true)
        let generatedRoot = root.appendingPathComponent("generated", isDirectory: true)
        let configuration = LiveAuditConfiguration(
            outputRoot: root,
            modelsRoot: root.appendingPathComponent("models", isDirectory: true),
            modes: [.voiceDesign],
            cloneReference: nil,
            cloneTranscript: nil,
            repeatCount: 1,
            benchmarkProfile: .warmFocus,
            coldRuns: 2,
            warmRuns: 10,
            streamingIntervalOverride: nil,
            customPrewarmDepth: nil,
            customVoiceProfile: nil,
            streamStepEvalPolicy: nil,
            generationSpeedProfile: nil,
            memoryClearCadence: nil,
            postRequestCachePolicy: nil,
            deliveryAuditVariants: [.speed, .quality],
            deliveryAuditScope: .standard,
            cloneReferences: [],
            cloneToneLabel: nil,
            audioReview: nil
        )

        let runRoot = outputRootForRun(
            mode: .voiceDesign,
            iteration: 7,
            phase: .warm,
            runIndex: 7,
            outputRoot: generatedRoot,
            configuration: configuration
        )

        XCTAssertTrue(
            runRoot.path.hasSuffix("/generated/warm/VoiceDesign/run_007"),
            "Unexpected warm-focus run root: \(runRoot.path)"
        )
    }

    func testExhaustiveBenchmarkProfileUsesLongTextRunLayout() throws {
        XCTAssertEqual(try parseBenchmarkProfile("exhaustive"), .exhaustive)

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qwenvoice-exhaustive-test", isDirectory: true)
        let generatedRoot = root.appendingPathComponent("generated", isDirectory: true)
        let configuration = LiveAuditConfiguration(
            outputRoot: root,
            modelsRoot: root.appendingPathComponent("models", isDirectory: true),
            modes: [.customVoice, .voiceDesign, .clones],
            cloneReference: "/tmp/reference.wav",
            cloneTranscript: "Reference speech",
            repeatCount: 1,
            benchmarkProfile: .exhaustive,
            coldRuns: 3,
            warmRuns: 5,
            streamingIntervalOverride: nil,
            customPrewarmDepth: nil,
            customVoiceProfile: nil,
            streamStepEvalPolicy: nil,
            generationSpeedProfile: nil,
            memoryClearCadence: nil,
            postRequestCachePolicy: nil,
            deliveryAuditVariants: [.speed, .quality],
            deliveryAuditScope: .standard,
            cloneReferences: [
                CloneAuditReference(path: "/tmp/reference.wav", transcript: "Reference speech", label: "reference"),
            ],
            cloneToneLabel: nil,
            audioReview: nil
        )

        let runRoot = outputRootForRun(
            mode: .customVoice,
            iteration: 1,
            phase: .direct2700,
            runIndex: 1,
            outputRoot: generatedRoot,
            configuration: configuration
        )

        XCTAssertTrue(
            runRoot.path.hasSuffix("/generated/direct-2700/CustomVoice/run_001"),
            "Unexpected exhaustive direct-run root: \(runRoot.path)"
        )
    }

    func testCustomUIColdBenchmarkProfileUsesCustomVoiceColdWarmLayout() throws {
        XCTAssertEqual(try parseBenchmarkProfile("custom-ui-cold"), .customUICold)

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qwenvoice-custom-ui-cold-test", isDirectory: true)
        let generatedRoot = root.appendingPathComponent("generated", isDirectory: true)
        let configuration = LiveAuditConfiguration(
            outputRoot: root,
            modelsRoot: root.appendingPathComponent("models", isDirectory: true),
            modes: [.customVoice],
            cloneReference: nil,
            cloneTranscript: nil,
            repeatCount: 1,
            benchmarkProfile: .customUICold,
            coldRuns: 5,
            warmRuns: 5,
            streamingIntervalOverride: 0.4,
            customPrewarmDepth: "skip-stream-step",
            customVoiceProfile: "balanced-short",
            streamStepEvalPolicy: nil,
            generationSpeedProfile: "balanced-all-modes",
            memoryClearCadence: 50,
            postRequestCachePolicy: "failure-only",
            deliveryAuditVariants: [.speed, .quality],
            deliveryAuditScope: .standard,
            cloneReferences: [],
            cloneToneLabel: nil,
            audioReview: nil
        )

        let request = try makeRequest(
            mode: .customVoice,
            iteration: 1,
            phase: .cold,
            runIndex: 1,
            outputRoot: generatedRoot,
            configuration: configuration
        )
        let runRoot = outputRootForRun(
            mode: .customVoice,
            iteration: 1,
            phase: .cold,
            runIndex: 1,
            outputRoot: generatedRoot,
            configuration: configuration
        )

        XCTAssertEqual(request.streamingInterval, 0.4)
        XCTAssertFalse(request.shouldStream)
        XCTAssertEqual(configuration.customVoiceProfile, "balanced-short")
        XCTAssertEqual(request.benchmarkOptions?.generationSpeedProfile, "balanced-all-modes")
        XCTAssertEqual(request.benchmarkOptions?.memoryClearCadence, 50)
        XCTAssertEqual(request.benchmarkOptions?.postRequestCachePolicy, "failure-only")
        XCTAssertTrue(
            runRoot.path.hasSuffix("/generated/cold/CustomVoice/run_001"),
            "Unexpected custom-ui-cold run root: \(runRoot.path)"
        )
    }

    func testLongTextFixturesAndBatchSegmentationUseNineHundredCharacterBudget() {
        let directText = Self.longText(characterCount: 2_700, mode: .voiceDesign)
        XCTAssertEqual(directText.count, 2_700)
        XCTAssertGreaterThan(Self.wordCount(directText), 100)

        let batchText = Self.longText(characterCount: 9_000, mode: .clones)
        XCTAssertEqual(batchText.count, 9_000)
        let segments = LongFormBatchSegmenter.segments(from: batchText)

        XCTAssertGreaterThanOrEqual(segments.count, 10)
        XCTAssertTrue(segments.allSatisfy { $0.count <= LongFormBatchSegmenter.defaultMaxCharacters })
        XCTAssertEqual(
            segments.joined(separator: " ").prefix(80),
            LongFormBatchSegmenter.segments(from: batchText).joined(separator: " ").prefix(80)
        )
    }

    func testAudioQCModesAcceptVoiceCloningAlias() throws {
        XCTAssertEqual(
            try parseModes("CustomVoice,VoiceDesign,VoiceCloning,Clones"),
            [.customVoice, .voiceDesign, .clones]
        )
    }

    func testDeliveryMatrixProfileDefaultsToBothMacVariants() throws {
        let profile = try parseBenchmarkProfile("delivery-matrix")

        XCTAssertEqual(profile, .deliveryMatrix)
        XCTAssertEqual(
            try parseAuditVariants(nil, benchmarkProfile: profile),
            [.speed, .quality]
        )
        XCTAssertEqual(
            try parseAuditVariants("quality,speed,quality", benchmarkProfile: profile),
            [.quality, .speed]
        )
    }

    func testDeliveryAuditCasesCoverBuiltInPresetsAndCustomText() {
        let cases = deliveryAuditCases(for: .customVoice, cloneToneLabel: nil)

        XCTAssertEqual(cases.map(\.id), [
            "speaker-aiden-neutral-normal",
            "speaker-aiden-happy-normal",
            "speaker-aiden-sad-normal",
            "speaker-aiden-angry-normal",
            "speaker-aiden-calm-normal",
            "speaker-aiden-whisper-normal",
            "speaker-aiden-dramatic-normal",
            "speaker-aiden-excited-normal",
            "speaker-aiden-custom-controlled-urgency",
        ])
        XCTAssertEqual(cases.first?.deliveryInstruction, DeliveryProfile.neutralInstruction)
        XCTAssertEqual(cases.last?.customText, "Controlled urgency with quick pacing, focused stress, and clear pronunciation.")
    }

    func testFullDeliveryAuditCasesCoverSpeakersIntensitiesAndDesignBriefs() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qwenvoice-full-delivery-test", isDirectory: true)
        let configuration = LiveAuditConfiguration(
            outputRoot: root,
            modelsRoot: root.appendingPathComponent("models", isDirectory: true),
            modes: [.customVoice, .voiceDesign, .clones],
            cloneReference: "/tmp/reference.wav",
            cloneTranscript: "Reference speech",
            repeatCount: 1,
            benchmarkProfile: .deliveryMatrix,
            coldRuns: 2,
            warmRuns: 3,
            streamingIntervalOverride: nil,
            customPrewarmDepth: nil,
            customVoiceProfile: nil,
            streamStepEvalPolicy: nil,
            generationSpeedProfile: nil,
            memoryClearCadence: nil,
            postRequestCachePolicy: nil,
            deliveryAuditVariants: [.speed, .quality],
            deliveryAuditScope: .full,
            cloneReferences: [
                CloneAuditReference(path: "/tmp/reference.wav", transcript: "Reference speech", label: "Warm Reference"),
            ],
            cloneToneLabel: nil,
            audioReview: nil
        )

        let customCases = deliveryAuditCases(for: .customVoice, configuration: configuration)
        XCTAssertTrue(customCases.contains { $0.id == "speaker-ryan-excited-strong" })
        XCTAssertTrue(customCases.contains { $0.id == "speaker-serena-excited-strong" })
        XCTAssertTrue(customCases.contains { $0.id == "speaker-aiden-fearful-subtle" })
        XCTAssertTrue(customCases.contains { $0.id == "speaker-vivian-whisper-subtle" })
        XCTAssertEqual(Set(customCases.compactMap(\.speakerID)), ["aiden", "ryan", "vivian", "serena"])

        let designCases = deliveryAuditCases(for: .voiceDesign, configuration: configuration)
        XCTAssertTrue(designCases.contains { $0.id == "brief-warm-british-dramatic-strong" })
        XCTAssertTrue(designCases.contains { $0.voiceDescription?.contains("British") == true })

        let cloneCases = deliveryAuditCases(for: .clones, configuration: configuration)
        XCTAssertEqual(cloneCases.map(\.referenceToneLabel), ["Warm Reference"])
        XCTAssertEqual(cloneCases.first?.cloneReferencePath, "/tmp/reference.wav")
    }

    func testKnownRiskDeliveryScopeTargetsRyanSpeedExcitedStrongCluster() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qwenvoice-known-risk-delivery-test", isDirectory: true)
        let configuration = LiveAuditConfiguration(
            outputRoot: root,
            modelsRoot: root.appendingPathComponent("models", isDirectory: true),
            modes: [.customVoice, .voiceDesign, .clones],
            cloneReference: nil,
            cloneTranscript: nil,
            repeatCount: 1,
            benchmarkProfile: .deliveryMatrix,
            coldRuns: 2,
            warmRuns: 3,
            streamingIntervalOverride: nil,
            customPrewarmDepth: nil,
            customVoiceProfile: nil,
            streamStepEvalPolicy: nil,
            generationSpeedProfile: nil,
            memoryClearCadence: nil,
            postRequestCachePolicy: nil,
            deliveryAuditVariants: [.speed, .quality],
            deliveryAuditScope: .knownRisk,
            cloneReferences: [],
            cloneToneLabel: nil,
            audioReview: nil
        )

        XCTAssertEqual(try parseDeliveryAuditScope("known-risk"), .knownRisk)

        let customCases = deliveryAuditCases(for: .customVoice, configuration: configuration)
        XCTAssertEqual(customCases.map(\.id), [
            "speaker-ryan-neutral-normal",
            "speaker-ryan-excited-strong",
            "speaker-aiden-excited-strong",
        ])
        XCTAssertTrue(deliveryAuditCases(for: .voiceDesign, configuration: configuration).isEmpty)
        XCTAssertTrue(deliveryAuditCases(for: .clones, configuration: configuration).isEmpty)
        XCTAssertEqual(
            deliveryAuditCases(customCases, for: .speed, scope: .knownRisk).map(\.id),
            [
                "speaker-ryan-neutral-normal",
                "speaker-ryan-excited-strong",
                "speaker-aiden-excited-strong",
            ]
        )
        XCTAssertEqual(
            deliveryAuditCases(customCases, for: .quality, scope: .knownRisk).map(\.id),
            ["speaker-ryan-excited-strong"]
        )
    }

    func testWhisperRiskDeliveryScopeTargetsVivianWhisperSubtleCluster() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qwenvoice-whisper-risk-delivery-test", isDirectory: true)
        let configuration = LiveAuditConfiguration(
            outputRoot: root,
            modelsRoot: root.appendingPathComponent("models", isDirectory: true),
            modes: [.customVoice, .voiceDesign, .clones],
            cloneReference: nil,
            cloneTranscript: nil,
            repeatCount: 1,
            benchmarkProfile: .deliveryMatrix,
            coldRuns: 2,
            warmRuns: 3,
            streamingIntervalOverride: nil,
            customPrewarmDepth: nil,
            customVoiceProfile: nil,
            streamStepEvalPolicy: nil,
            generationSpeedProfile: nil,
            memoryClearCadence: nil,
            postRequestCachePolicy: nil,
            deliveryAuditVariants: [.speed, .quality],
            deliveryAuditScope: .whisperRisk,
            cloneReferences: [],
            cloneToneLabel: nil,
            audioReview: nil
        )

        XCTAssertEqual(try parseDeliveryAuditScope("whisper-risk"), .whisperRisk)

        let customCases = deliveryAuditCases(for: .customVoice, configuration: configuration)
        XCTAssertEqual(customCases.map(\.id), [
            "speaker-vivian-whisper-subtle",
            "speaker-vivian-whisper-normal",
            "speaker-vivian-whisper-strong",
            "speaker-ryan-whisper-subtle",
            "speaker-aiden-whisper-subtle",
        ])
        XCTAssertTrue(deliveryAuditCases(for: .voiceDesign, configuration: configuration).isEmpty)
        XCTAssertTrue(deliveryAuditCases(for: .clones, configuration: configuration).isEmpty)
        XCTAssertEqual(
            deliveryAuditCases(customCases, for: .speed, scope: .whisperRisk).map(\.id),
            [
                "speaker-vivian-whisper-subtle",
                "speaker-vivian-whisper-normal",
                "speaker-vivian-whisper-strong",
                "speaker-ryan-whisper-subtle",
                "speaker-aiden-whisper-subtle",
            ]
        )
        XCTAssertEqual(
            deliveryAuditCases(customCases, for: .quality, scope: .whisperRisk).map(\.id),
            ["speaker-vivian-whisper-subtle"]
        )
    }

    func testLiveXPCGenerationQualityAuditArtifacts() async throws {
        let environment = ProcessInfo.processInfo.environment
        let configuration = try loadLiveAuditConfiguration(environment: environment)
        executionTimeAllowance = [.exhaustive, .deliveryMatrix].contains(configuration.benchmarkProfile) ? 7_200 : 1_800
        let outputRoot = configuration.outputRoot
        let modelsRoot = configuration.modelsRoot
        let modes = configuration.modes
        let appSupportRoot = outputRoot.appendingPathComponent("app-support", isDirectory: true)
        let generatedRoot = outputRoot.appendingPathComponent("generated", isDirectory: true)

        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: generatedRoot, withIntermediateDirectories: true)

        let runResult: AuditRunResult
        switch configuration.benchmarkProfile {
        case .standard:
            let repeatAppSupportRoot = appSupportRoot.appendingPathComponent("repeat", isDirectory: true)
            runResult = AuditRunResult(
                artifacts: try await runRepeatAudit(
                    configuration: configuration,
                    modes: modes,
                    modelsRoot: modelsRoot,
                    appSupportRoot: repeatAppSupportRoot,
                    generatedRoot: generatedRoot
                ),
                longText: nil
            )
        case .coldWarm:
            runResult = AuditRunResult(
                artifacts: try await runColdWarmBenchmark(
                    configuration: configuration,
                    modes: modes,
                    modelsRoot: modelsRoot,
                    appSupportBase: appSupportRoot,
                    generatedRoot: generatedRoot
                ),
                longText: nil
            )
        case .customUICold:
            runResult = AuditRunResult(
                artifacts: try await runCustomUIColdBenchmark(
                    configuration: configuration,
                    modes: modes,
                    modelsRoot: modelsRoot,
                    appSupportBase: appSupportRoot,
                    generatedRoot: generatedRoot
                ),
                longText: nil
            )
        case .warmFocus:
            runResult = AuditRunResult(
                artifacts: try await runWarmFocusBenchmark(
                    configuration: configuration,
                    modes: modes,
                    modelsRoot: modelsRoot,
                    appSupportBase: appSupportRoot,
                    generatedRoot: generatedRoot
                ),
                longText: nil
            )
        case .exhaustive:
            runResult = try await runExhaustiveBenchmark(
                configuration: configuration,
                modes: modes,
                modelsRoot: modelsRoot,
                appSupportBase: appSupportRoot,
                generatedRoot: generatedRoot
            )
        case .deliveryMatrix:
            runResult = try await runDeliveryMatrixAudit(
                configuration: configuration,
                modes: modes,
                modelsRoot: modelsRoot,
                appSupportBase: appSupportRoot,
                generatedRoot: generatedRoot
            )
        }

        let audioReviewManifest = try await runAudioReviewIfEnabled(
            configuration: configuration,
            artifacts: runResult.artifacts,
            outputRoot: outputRoot
        )
        let manifest = AuditManifest(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            benchmarkProfile: configuration.benchmarkProfile.rawValue,
            coldRuns: [.coldWarm, .customUICold, .exhaustive].contains(configuration.benchmarkProfile) ? configuration.coldRuns : nil,
            warmRuns: configuration.benchmarkProfile == .standard ? nil : configuration.warmRuns,
            appSupportDirectory: appSupportRoot.path,
            modelsRoot: modelsRoot.path,
            artifacts: runResult.artifacts,
            longText: runResult.longText,
            deliveryMatrix: runResult.deliveryMatrix,
            audioReview: audioReviewManifest
        )
        let data = try JSONEncoder.audioQCEncoder.encode(manifest)
        try data.write(to: outputRoot.appendingPathComponent("generation-manifest.json"))
        if let longText = runResult.longText {
            let longTextData = try JSONEncoder.audioQCEncoder.encode(longText)
            try longTextData.write(to: outputRoot.appendingPathComponent("long-text-manifest.json"))
        }
        if let deliveryMatrix = runResult.deliveryMatrix {
            let deliveryData = try JSONEncoder.audioQCEncoder.encode(deliveryMatrix)
            try deliveryData.write(to: outputRoot.appendingPathComponent("delivery-matrix-manifest.json"))
        }
    }

    private func runAudioReviewIfEnabled(
        configuration: LiveAuditConfiguration,
        artifacts: [AuditArtifact],
        outputRoot: URL
    ) async throws -> AudioReview.RunManifest? {
        guard let reviewConfiguration = configuration.audioReview, reviewConfiguration.enabled else {
            return nil
        }
        terminateEngineServiceIfRunning()
        let reviewRoot = outputRoot.appendingPathComponent("audio-review", isDirectory: true)
        AudioReview.trimMLXCacheForReview()
        try? await Task.sleep(nanoseconds: reviewConfiguration.memorySettleNanoseconds)
        AudioReview.trimMLXCacheForReview()

        let memoryGuard = AudioReview.evaluateMemoryGuard(
            snapshot: AudioReview.captureMemorySnapshot(),
            minimumAvailableMemoryBytes: reviewConfiguration.minimumAvailableMemoryBytes
        )
        guard memoryGuard.passed else {
            return try AudioReviewArtifactWriter.writeRunManifest(
                reviewRoot: reviewRoot,
                configuration: reviewConfiguration,
                clips: [],
                memoryGuard: memoryGuard,
                skippedReason: memoryGuard.reason
            )
        }

        let reviewModels = try await Qwen3AudioReviewModels(configuration: reviewConfiguration)
        let pipeline = AudioReviewPipeline(transcriber: reviewModels, aligner: reviewModels)
        let eligibleArtifacts = artifacts.filter(\.qcEligible)
        var clipSummaries: [AudioReview.ClipSummary] = []

        for artifact in eligibleArtifacts {
            let input = AudioReview.ClipInput(
                clipID: reviewClipID(for: artifact),
                mode: artifact.mode,
                phase: artifact.phase,
                runIndex: artifact.runIndex,
                expectedText: artifact.text,
                audioURL: URL(fileURLWithPath: artifact.outputPath),
                deliveryInstruction: artifact.deliveryInstruction,
                strictness: reviewConfiguration.strictness,
                language: reviewConfiguration.language
            )
            let report = try await pipeline.review(input: input)
            clipSummaries.append(
                try AudioReviewArtifactWriter.writeClipArtifacts(
                    report: report,
                    reviewRoot: reviewRoot
                )
            )
            AudioReview.trimMLXCacheForReview()
        }

        let manifest = try AudioReviewArtifactWriter.writeRunManifest(
            reviewRoot: reviewRoot,
            configuration: reviewConfiguration,
            clips: clipSummaries,
            memoryGuard: memoryGuard
        )
        XCTAssertTrue(
            manifest.passed,
            "Audio review failed. See \(reviewRoot.appendingPathComponent("audio-review.md").path)"
        )
        return manifest
    }

    private func reviewClipID(for artifact: AuditArtifact) -> String {
        let mode = artifact.mode
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return "\(artifact.phase)-\(mode)-run-\(String(format: "%03d", artifact.runIndex))-iter-\(String(format: "%03d", artifact.iteration))"
    }

    private func runRepeatAudit(
        configuration: LiveAuditConfiguration,
        modes: [AuditMode],
        modelsRoot: URL,
        appSupportRoot: URL,
        generatedRoot: URL
    ) async throws -> [AuditArtifact] {
        let initialized = try await makeInitializedClient(
            modes: modes,
            modelsRoot: modelsRoot,
            appSupportRoot: appSupportRoot
        )
        let client = initialized.client
        defer {
            Task {
                await client.debugInvalidateConnectionForTesting()
            }
        }

        var artifacts: [AuditArtifact] = []
        var pendingInitializationTimings = initialized.timingsMS
        for iteration in 1...configuration.repeatCount {
            for mode in modes {
                artifacts.append(
                    try await generateArtifact(
                        client: client,
                        mode: mode,
                        iteration: iteration,
                        phase: .standard,
                        runIndex: iteration,
                        measured: true,
                        qcEligible: true,
                        appSupportRoot: appSupportRoot,
                        generatedRoot: generatedRoot,
                        configuration: configuration,
                        extraTimingsMS: pendingInitializationTimings
                    )
                )
                pendingInitializationTimings = [:]
            }
        }
        return artifacts
    }

    private func runColdWarmBenchmark(
        configuration: LiveAuditConfiguration,
        modes: [AuditMode],
        modelsRoot: URL,
        appSupportBase: URL,
        generatedRoot: URL
    ) async throws -> [AuditArtifact] {
        var artifacts: [AuditArtifact] = []

        for mode in modes {
            let coldAppSupportRoot = appSupportBase
                .appendingPathComponent("cold", isDirectory: true)
                .appendingPathComponent(mode.rawValue, isDirectory: true)
            for runIndex in 1...configuration.coldRuns {
                let initialized = try await makeInitializedClient(
                    modes: [mode],
                    modelsRoot: modelsRoot,
                    appSupportRoot: coldAppSupportRoot
                )
                let client = initialized.client
                do {
                    artifacts.append(
                        try await generateArtifact(
                            client: client,
                            mode: mode,
                            iteration: runIndex,
                            phase: .cold,
                            runIndex: runIndex,
                            measured: true,
                            qcEligible: true,
                            appSupportRoot: coldAppSupportRoot,
                            generatedRoot: generatedRoot,
                            configuration: configuration,
                            extraTimingsMS: initialized.timingsMS
                        )
                    )
                    await shutdownBenchmarkClient(client)
                } catch {
                    await shutdownBenchmarkClient(client)
                    throw error
                }
            }

            let warmAppSupportRoot = appSupportBase
                .appendingPathComponent("warm", isDirectory: true)
                .appendingPathComponent(mode.rawValue, isDirectory: true)
            let warmClient = try await makeInitializedClient(
                modes: [mode],
                modelsRoot: modelsRoot,
                appSupportRoot: warmAppSupportRoot
            )
            let warmXPCClient = warmClient.client
            do {
                artifacts.append(
                    try await generateArtifact(
                        client: warmXPCClient,
                        mode: mode,
                        iteration: 0,
                        phase: .primer,
                        runIndex: 0,
                        measured: false,
                        qcEligible: false,
                        appSupportRoot: warmAppSupportRoot,
                        generatedRoot: generatedRoot,
                        configuration: configuration,
                        extraTimingsMS: warmClient.timingsMS
                    )
                )
                for runIndex in 1...configuration.warmRuns {
                    artifacts.append(
                        try await generateArtifact(
                            client: warmXPCClient,
                            mode: mode,
                            iteration: runIndex,
                            phase: .warm,
                            runIndex: runIndex,
                            measured: true,
                            qcEligible: true,
                            appSupportRoot: warmAppSupportRoot,
                            generatedRoot: generatedRoot,
                            configuration: configuration
                        )
                    )
                }
                await shutdownBenchmarkClient(warmXPCClient)
            } catch {
                await shutdownBenchmarkClient(warmXPCClient)
                throw error
            }
        }

        return artifacts
    }

    private func runCustomUIColdBenchmark(
        configuration: LiveAuditConfiguration,
        modes: [AuditMode],
        modelsRoot: URL,
        appSupportBase: URL,
        generatedRoot: URL
    ) async throws -> [AuditArtifact] {
        guard modes == [.customVoice] else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "custom-ui-cold benchmark supports CustomVoice only."]
            )
        }

        let mode = AuditMode.customVoice
        var artifacts: [AuditArtifact] = []

        for runIndex in 1...configuration.coldRuns {
            let coldAppSupportRoot = appSupportBase
                .appendingPathComponent("custom-ui-cold", isDirectory: true)
                .appendingPathComponent("cold", isDirectory: true)
                .appendingPathComponent(String(format: "run_%03d", runIndex), isDirectory: true)
            let initialized = try await makeInitializedClient(
                modes: [mode],
                modelsRoot: modelsRoot,
                appSupportRoot: coldAppSupportRoot
            )
            let client = initialized.client
            do {
                let prewarmTimings = try await prewarmSelectedCustomVoiceReadiness(
                    client: client,
                    mode: mode,
                    iteration: runIndex,
                    phase: .cold,
                    runIndex: runIndex,
                    appSupportRoot: coldAppSupportRoot,
                    generatedRoot: generatedRoot,
                    configuration: configuration
                )
                artifacts.append(
                    try await generateArtifact(
                        client: client,
                        mode: mode,
                        iteration: runIndex,
                        phase: .cold,
                        runIndex: runIndex,
                        measured: true,
                        qcEligible: true,
                        appSupportRoot: coldAppSupportRoot,
                        generatedRoot: generatedRoot,
                        configuration: configuration,
                        extraTimingsMS: initialized.timingsMS
                            .merging(prewarmTimings.timingsMS) { _, rhs in rhs },
                        extraBooleanFlags: prewarmTimings.booleanFlags
                    )
                )
                await shutdownBenchmarkClient(client)
            } catch {
                await shutdownBenchmarkClient(client)
                throw error
            }
        }

        let warmAppSupportRoot = appSupportBase
            .appendingPathComponent("custom-ui-cold", isDirectory: true)
            .appendingPathComponent("warm", isDirectory: true)
        let warmClient = try await makeInitializedClient(
            modes: [mode],
            modelsRoot: modelsRoot,
            appSupportRoot: warmAppSupportRoot
        )
        let client = warmClient.client
        do {
            let prewarmTimings = try await prewarmSelectedCustomVoiceReadiness(
                client: client,
                mode: mode,
                iteration: 0,
                phase: .primer,
                runIndex: 0,
                appSupportRoot: warmAppSupportRoot,
                generatedRoot: generatedRoot,
                configuration: configuration
            )
            artifacts.append(
                try await generateArtifact(
                    client: client,
                    mode: mode,
                    iteration: 0,
                    phase: .primer,
                    runIndex: 0,
                    measured: false,
                    qcEligible: false,
                    appSupportRoot: warmAppSupportRoot,
                    generatedRoot: generatedRoot,
                    configuration: configuration,
                    extraTimingsMS: warmClient.timingsMS
                        .merging(prewarmTimings.timingsMS) { _, rhs in rhs },
                    extraBooleanFlags: prewarmTimings.booleanFlags
                )
            )
            for runIndex in 1...configuration.warmRuns {
                let warmReadinessTimings = try await prewarmSelectedCustomVoiceReadiness(
                    client: client,
                    mode: mode,
                    iteration: runIndex,
                    phase: .warm,
                    runIndex: runIndex,
                    appSupportRoot: warmAppSupportRoot,
                    generatedRoot: generatedRoot,
                    configuration: configuration
                )
                artifacts.append(
                    try await generateArtifact(
                        client: client,
                        mode: mode,
                        iteration: runIndex,
                        phase: .warm,
                        runIndex: runIndex,
                        measured: true,
                        qcEligible: true,
                        appSupportRoot: warmAppSupportRoot,
                        generatedRoot: generatedRoot,
                        configuration: configuration,
                        extraTimingsMS: warmReadinessTimings.timingsMS,
                        extraBooleanFlags: warmReadinessTimings.booleanFlags
                    )
                )
            }
            await shutdownBenchmarkClient(client)
            return artifacts
        } catch {
            await shutdownBenchmarkClient(client)
            throw error
        }
    }

    private func runWarmFocusBenchmark(
        configuration: LiveAuditConfiguration,
        modes: [AuditMode],
        modelsRoot: URL,
        appSupportBase: URL,
        generatedRoot: URL
    ) async throws -> [AuditArtifact] {
        guard modes == [.voiceDesign] else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "warm-focus benchmark supports VoiceDesign only."]
            )
        }

        let mode = AuditMode.voiceDesign
        let warmAppSupportRoot = appSupportBase
            .appendingPathComponent("warm-focus", isDirectory: true)
            .appendingPathComponent(mode.rawValue, isDirectory: true)
        let warmClient = try await makeInitializedClient(
            modes: [mode],
            modelsRoot: modelsRoot,
            appSupportRoot: warmAppSupportRoot
        )
        let warmXPCClient = warmClient.client
        do {
            var artifacts: [AuditArtifact] = [
                try await generateArtifact(
                    client: warmXPCClient,
                    mode: mode,
                    iteration: 0,
                    phase: .primer,
                    runIndex: 0,
                    measured: false,
                    qcEligible: false,
                    appSupportRoot: warmAppSupportRoot,
                    generatedRoot: generatedRoot,
                    configuration: configuration,
                    extraTimingsMS: warmClient.timingsMS
                )
            ]
            for runIndex in 1...configuration.warmRuns {
                artifacts.append(
                    try await generateArtifact(
                        client: warmXPCClient,
                        mode: mode,
                        iteration: runIndex,
                        phase: .warm,
                        runIndex: runIndex,
                        measured: true,
                        qcEligible: true,
                        appSupportRoot: warmAppSupportRoot,
                        generatedRoot: generatedRoot,
                        configuration: configuration
                    )
                )
            }
            await shutdownBenchmarkClient(warmXPCClient)
            return artifacts
        } catch {
            await shutdownBenchmarkClient(warmXPCClient)
            throw error
        }
    }

    private func runExhaustiveBenchmark(
        configuration: LiveAuditConfiguration,
        modes: [AuditMode],
        modelsRoot: URL,
        appSupportBase: URL,
        generatedRoot: URL
    ) async throws -> AuditRunResult {
        var artifacts = try await runColdWarmBenchmark(
            configuration: configuration,
            modes: modes,
            modelsRoot: modelsRoot,
            appSupportBase: appSupportBase,
            generatedRoot: generatedRoot
        )
        artifacts.append(contentsOf: try await runWarmEnduranceBenchmark(
            configuration: configuration,
            modes: modes,
            modelsRoot: modelsRoot,
            appSupportBase: appSupportBase,
            generatedRoot: generatedRoot
        ))

        var longText = LongTextManifest()
        let directResult = try await runDirectLongTextBenchmark(
            configuration: configuration,
            modes: modes,
            modelsRoot: modelsRoot,
            appSupportBase: appSupportBase,
            generatedRoot: generatedRoot
        )
        artifacts.append(contentsOf: directResult.artifacts)
        longText.directCases.append(contentsOf: directResult.directCases)
        longText.boundedFailures.append(contentsOf: directResult.boundedFailures)

        let batchResult = try await runLongFormBatchBenchmark(
            configuration: configuration,
            modes: modes,
            modelsRoot: modelsRoot,
            appSupportBase: appSupportBase,
            generatedRoot: generatedRoot
        )
        artifacts.append(contentsOf: batchResult.artifacts)
        longText.batchCases.append(contentsOf: batchResult.batchCases)

        return AuditRunResult(artifacts: artifacts, longText: longText)
    }

    private func runWarmEnduranceBenchmark(
        configuration: LiveAuditConfiguration,
        modes: [AuditMode],
        modelsRoot: URL,
        appSupportBase: URL,
        generatedRoot: URL
    ) async throws -> [AuditArtifact] {
        var artifacts: [AuditArtifact] = []
        for mode in modes {
            let enduranceAppSupportRoot = appSupportBase
                .appendingPathComponent("endurance", isDirectory: true)
                .appendingPathComponent(mode.rawValue, isDirectory: true)
            let warmClient = try await makeInitializedClient(
                modes: [mode],
                modelsRoot: modelsRoot,
                appSupportRoot: enduranceAppSupportRoot
            )
            let client = warmClient.client
            do {
                artifacts.append(
                    try await generateArtifact(
                        client: client,
                        mode: mode,
                        iteration: 0,
                        phase: .primer,
                        runIndex: 0,
                        measured: false,
                        qcEligible: false,
                        appSupportRoot: enduranceAppSupportRoot,
                        generatedRoot: generatedRoot,
                        configuration: configuration,
                        extraTimingsMS: warmClient.timingsMS
                    )
                )
                for runIndex in 1...10 {
                    artifacts.append(
                        try await generateArtifact(
                            client: client,
                            mode: mode,
                            iteration: runIndex,
                            phase: .endurance,
                            runIndex: runIndex,
                            measured: true,
                            qcEligible: true,
                            appSupportRoot: enduranceAppSupportRoot,
                            generatedRoot: generatedRoot,
                            configuration: configuration
                        )
                    )
                }
                await shutdownBenchmarkClient(client)
            } catch {
                await shutdownBenchmarkClient(client)
                throw error
            }
        }
        return artifacts
    }

    private struct DirectLongTextResult {
        var artifacts: [AuditArtifact] = []
        var directCases: [LongTextManifest.DirectCase] = []
        var boundedFailures: [LongTextManifest.BoundedFailure] = []
    }

    private func runDirectLongTextBenchmark(
        configuration: LiveAuditConfiguration,
        modes: [AuditMode],
        modelsRoot: URL,
        appSupportBase: URL,
        generatedRoot: URL
    ) async throws -> DirectLongTextResult {
        var result = DirectLongTextResult()
        for mode in modes {
            let directAppSupportRoot = appSupportBase
                .appendingPathComponent("direct-long-text", isDirectory: true)
                .appendingPathComponent(mode.rawValue, isDirectory: true)
            let initialized = try await makeInitializedClient(
                modes: [mode],
                modelsRoot: modelsRoot,
                appSupportRoot: directAppSupportRoot
            )
            let client = initialized.client
            var pendingTimings = initialized.timingsMS
            do {
                for (phase, characterCount) in [(AuditPhase.direct900, 900), (.direct2700, 2_700)] {
                    let text = Self.longText(characterCount: characterCount, mode: mode)
                    do {
                        let artifact = try await generateArtifact(
                            client: client,
                            mode: mode,
                            iteration: 1,
                            phase: phase,
                            runIndex: 1,
                            measured: true,
                            qcEligible: true,
                            appSupportRoot: directAppSupportRoot,
                            generatedRoot: generatedRoot,
                            configuration: configuration,
                            extraTimingsMS: pendingTimings,
                            textOverride: text
                        )
                        pendingTimings = [:]
                        result.artifacts.append(artifact)
                        result.directCases.append(LongTextManifest.DirectCase(
                            mode: mode.rawValue,
                            phase: phase.rawValue,
                            characterCount: text.count,
                            wordCount: Self.wordCount(text),
                            outputPath: artifact.outputPath,
                            error: nil
                        ))
                    } catch {
                        let boundedFailure = LongTextManifest.BoundedFailure(
                            mode: mode.rawValue,
                            phase: phase.rawValue,
                            characterCount: text.count,
                            wordCount: Self.wordCount(text),
                            error: String(describing: error)
                        )
                        guard phase == .direct2700 else {
                            throw error
                        }
                        result.boundedFailures.append(boundedFailure)
                        result.directCases.append(LongTextManifest.DirectCase(
                            mode: mode.rawValue,
                            phase: phase.rawValue,
                            characterCount: text.count,
                            wordCount: Self.wordCount(text),
                            outputPath: nil,
                            error: boundedFailure.error
                        ))
                    }
                }
                await shutdownBenchmarkClient(client)
            } catch {
                await shutdownBenchmarkClient(client)
                throw error
            }
        }
        return result
    }

    private struct LongFormBatchResult {
        var artifacts: [AuditArtifact] = []
        var batchCases: [LongTextManifest.BatchCase] = []
    }

    private func runLongFormBatchBenchmark(
        configuration: LiveAuditConfiguration,
        modes: [AuditMode],
        modelsRoot: URL,
        appSupportBase: URL,
        generatedRoot: URL
    ) async throws -> LongFormBatchResult {
        var batchResult = LongFormBatchResult()
        for mode in modes {
            let batchText = Self.longText(characterCount: 9_000, mode: mode)
            let segments = LongFormBatchSegmenter.segments(from: batchText)
            XCTAssertFalse(segments.isEmpty, "Long-form batch text should create at least one segment.")
            XCTAssertTrue(
                segments.allSatisfy { $0.count <= LongFormBatchSegmenter.defaultMaxCharacters },
                "Long-form segments must respect the 900-character product budget."
            )

            let batchAppSupportRoot = appSupportBase
                .appendingPathComponent("batch-long-form", isDirectory: true)
                .appendingPathComponent(mode.rawValue, isDirectory: true)
            let initialized = try await makeInitializedClient(
                modes: [mode],
                modelsRoot: modelsRoot,
                appSupportRoot: batchAppSupportRoot
            )
            let client = initialized.client
            do {
                let requests = try segments.enumerated().map { index, segment in
                    let segmentRoot = generatedRoot
                        .appendingPathComponent(AuditPhase.batchLongForm.rawValue, isDirectory: true)
                        .appendingPathComponent(mode.rawValue, isDirectory: true)
                        .appendingPathComponent(String(format: "segment_%03d", index + 1), isDirectory: true)
                    let outputURL = segmentRoot.appendingPathComponent("\(mode.fileStem).wav")
                    return try makeRequest(
                        mode: mode,
                        iteration: index + 1,
                        phase: .batchLongForm,
                        runIndex: index + 1,
                        outputRoot: generatedRoot,
                        configuration: configuration,
                        textOverride: segment,
                        outputURLOverride: outputURL,
                        batchIndex: index + 1,
                        batchTotal: segments.count
                    )
                }
                let started = DispatchTime.now().uptimeNanoseconds
                let results = try await client.generateBatch(requests, progressHandler: nil)
                let batchWallClockMS = elapsedMilliseconds(since: started)
                XCTAssertEqual(results.count, requests.count, "Batch result count should match request count.")

                var segmentArtifacts: [AuditArtifact] = []
                for (index, result) in results.enumerated() {
                    let request = requests[index]
                    let artifact = try makeArtifact(
                        mode: mode,
                        request: request,
                        result: result,
                        iteration: index + 1,
                        phase: .batchLongForm,
                        runIndex: index + 1,
                        measured: true,
                        qcEligible: true,
                        appSupportRoot: batchAppSupportRoot,
                        wallClockMS: batchWallClockMS,
                        extraTimingsMS: initialized.timingsMS.merging(["batch_wall_ms": batchWallClockMS]) { current, _ in current },
                        segmentCount: segments.count,
                        segmentIndex: index + 1,
                        batchTotal: segments.count
                    )
                    segmentArtifacts.append(artifact)
                }
                batchResult.artifacts.append(contentsOf: segmentArtifacts)
                batchResult.batchCases.append(LongTextManifest.BatchCase(
                    mode: mode.rawValue,
                    characterCount: batchText.count,
                    wordCount: Self.wordCount(batchText),
                    segmentCount: segments.count,
                    generated: segmentArtifacts.count,
                    failed: max(0, segments.count - segmentArtifacts.count),
                    totalAudioDurationSeconds: segmentArtifacts.map(\.durationSeconds).reduce(0, +),
                    segmentOutputPaths: requests.enumerated().map { index, _ in
                        index < segmentArtifacts.count ? segmentArtifacts[index].outputPath : nil
                    }
                ))
                await shutdownBenchmarkClient(client)
            } catch {
                await shutdownBenchmarkClient(client)
                throw error
            }
        }
        return batchResult
    }

    private func runDeliveryMatrixAudit(
        configuration: LiveAuditConfiguration,
        modes: [AuditMode],
        modelsRoot: URL,
        appSupportBase: URL,
        generatedRoot: URL
    ) async throws -> AuditRunResult {
        var artifacts: [AuditArtifact] = []
        var skippedRows: [DeliveryAuditManifest.SkippedRow] = []

        for mode in modes {
            let cases = deliveryAuditCases(for: mode, configuration: configuration)
            if mode == .clones,
               configuration.cloneReference?.nonEmpty == nil,
               configuration.cloneReferences.isEmpty {
                skippedRows.append(contentsOf: cases.map {
                    DeliveryAuditManifest.SkippedRow(
                        mode: mode.rawValue,
                        variant: "all",
                        caseID: $0.id,
                        reason: "Voice Cloning delivery audit requires QWENVOICE_AUDIO_QC_CLONE_REFERENCE."
                    )
                })
                continue
            }

            for variant in configuration.deliveryAuditVariants {
                let variantCases = deliveryAuditCases(
                    cases,
                    for: variant,
                    scope: configuration.deliveryAuditScope
                )
                guard !variantCases.isEmpty else {
                    continue
                }

                guard let model = auditModel(mode: mode, variant: variant) else {
                    skippedRows.append(contentsOf: variantCases.map {
                        DeliveryAuditManifest.SkippedRow(
                            mode: mode.rawValue,
                            variant: variant.rawValue,
                            caseID: $0.id,
                            reason: "No \(variant.displayName) model descriptor exists for \(mode.rawValue)."
                        )
                    })
                    continue
                }

                do {
                    let entry = try resolvedAuditModelEntry(id: model.id)
                    try validateInstalledModel(
                        entry,
                        at: modelsRoot.appendingPathComponent(model.folder, isDirectory: true)
                    )
                } catch {
                    skippedRows.append(contentsOf: variantCases.map {
                        DeliveryAuditManifest.SkippedRow(
                            mode: mode.rawValue,
                            variant: variant.rawValue,
                            caseID: $0.id,
                            reason: String(describing: error)
                        )
                    })
                    continue
                }

                let appSupportRoot = appSupportBase
                    .appendingPathComponent("delivery-matrix", isDirectory: true)
                    .appendingPathComponent(mode.rawValue, isDirectory: true)
                    .appendingPathComponent(variant.rawValue, isDirectory: true)
                let initialized = try await makeInitializedClient(
                    modelIDs: [model.id],
                    modelsRoot: modelsRoot,
                    appSupportRoot: appSupportRoot
                )
                let client = initialized.client
                var pendingTimings = initialized.timingsMS
                do {
                    for (index, auditCase) in variantCases.enumerated() {
                        let request = try makeDeliveryAuditRequest(
                            mode: mode,
                            model: model,
                            variant: variant,
                            auditCase: auditCase,
                            index: index + 1,
                            generatedRoot: generatedRoot,
                            configuration: configuration
                        )
                        let started = DispatchTime.now().uptimeNanoseconds
                        let result = try await client.generate(request)
                        let artifact = try makeArtifact(
                            mode: mode,
                            request: request,
                            result: result,
                            iteration: index + 1,
                            phase: .deliveryMatrix,
                            runIndex: index + 1,
                            measured: true,
                            qcEligible: true,
                            appSupportRoot: appSupportRoot,
                            wallClockMS: elapsedMilliseconds(since: started),
                            extraTimingsMS: pendingTimings,
                            deliveryAuditCase: auditCase
                        )
                        pendingTimings = [:]
                        artifacts.append(artifact)
                    }
                    await shutdownBenchmarkClient(client)
                } catch {
                    await shutdownBenchmarkClient(client)
                    throw error
                }
            }
        }

        let deliveryMatrix = DeliveryAuditManifest(
            schemaVersion: 1,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            variants: configuration.deliveryAuditVariants.map(\.rawValue),
            scope: configuration.deliveryAuditScope.rawValue,
            artifacts: artifacts.map(\.outputPath),
            skippedRows: skippedRows
        )
        return AuditRunResult(
            artifacts: artifacts,
            longText: nil,
            deliveryMatrix: deliveryMatrix
        )
    }

    private func auditModel(mode: AuditMode, variant: AuditVariant) -> TTSModel? {
        TTSModel.all.first {
            $0.mode.rawValue == mode.generationMode.rawValue && $0.variantKind?.rawValue == variant.rawValue
        }
    }

    private func makeInitializedClient(
        modes: [AuditMode],
        modelsRoot: URL,
        appSupportRoot: URL
    ) async throws -> InitializedAuditClient {
        let modelMirrorMS = try mirrorRequiredModels(for: modes, from: modelsRoot, into: appSupportRoot)
        return try await makeInitializedClient(
            modelMirrorMS: modelMirrorMS,
            appSupportRoot: appSupportRoot
        )
    }

    private func makeInitializedClient(
        modelIDs: [String],
        modelsRoot: URL,
        appSupportRoot: URL
    ) async throws -> InitializedAuditClient {
        let modelMirrorMS = try mirrorRequiredModels(forModelIDs: modelIDs, from: modelsRoot, into: appSupportRoot)
        return try await makeInitializedClient(
            modelMirrorMS: modelMirrorMS,
            appSupportRoot: appSupportRoot
        )
    }

    private func makeInitializedClient(
        modelMirrorMS: Int,
        appSupportRoot: URL
    ) async throws -> InitializedAuditClient {
        let chunkRecorder = LiveChunkArtifactRecorder()
        let client = XPCNativeEngineClient(onChunk: { event in
            chunkRecorder.record(event)
        })
        let initializeStarted = DispatchTime.now().uptimeNanoseconds
        try await client.initialize(appSupportDirectory: appSupportRoot)
        let clientInitializeMS = elapsedMilliseconds(since: initializeStarted)
        return InitializedAuditClient(
            client: client,
            timingsMS: [
                "model_mirror_ms": modelMirrorMS,
                "client_initialize_ms": clientInitializeMS,
            ]
        )
    }

    private func shutdownBenchmarkClient(_ client: XPCNativeEngineClient) async {
        do {
            try await client.unloadModel()
        } catch {
            // Best-effort cleanup between benchmark samples.
        }
        await client.debugInvalidateConnectionForTesting()
        terminateEngineServiceIfRunning()
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    private func terminateEngineServiceIfRunning() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["QwenVoiceEngineService"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // No helper process was running, or killall was unavailable.
        }
    }

    private func prewarmSelectedCustomVoiceReadiness(
        client: XPCNativeEngineClient,
        mode: AuditMode,
        iteration: Int,
        phase: AuditPhase,
        runIndex: Int,
        appSupportRoot: URL,
        generatedRoot: URL,
        configuration: LiveAuditConfiguration
    ) async throws -> SelectedPrefetchDiagnostics {
        precondition(mode == .customVoice)
        let request = try makeRequest(
            mode: mode,
            iteration: iteration,
            phase: phase,
            runIndex: runIndex,
            outputRoot: generatedRoot,
            configuration: configuration
        )
        let started = DispatchTime.now().uptimeNanoseconds
        let maxAttempts = 2
        for attempt in 1...maxAttempts {
            let diagnostics = await client.prefetchInteractiveReadinessIfNeeded(
                for: request,
                customPrewarmDepth: configuration.customPrewarmDepth?.nonEmpty
            )
            let outcome = try await waitForLoadedModel(
                client,
                modelID: request.modelID,
                timeoutSeconds: 180
            )
            switch outcome {
            case .loaded:
                let elapsedMS = elapsedMilliseconds(since: started)
                let baselineTimings = [
                    "custom_ui_selected_prewarm_ms": elapsedMS,
                    "custom_ui_ready_ms": elapsedMS,
                    "custom_ui_selected_prewarm_attempts": attempt,
                ]
                return SelectedPrefetchDiagnostics(
                    timingsMS: (diagnostics?.timingsMS ?? [:])
                        .merging(baselineTimings) { current, _ in current },
                    booleanFlags: diagnostics?.booleanFlags ?? [:]
                )
            case .needsRetry:
                guard attempt < maxAttempts else {
                    throw NSError(
                        domain: "GenerationQualityAuditLiveTests",
                        code: 14,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Custom Voice selected-mode prewarm recovered to idle but did not become loaded."
                        ]
                    )
                }
            }
        }

        throw NSError(
            domain: "GenerationQualityAuditLiveTests",
            code: 15,
            userInfo: [NSLocalizedDescriptionKey: "Custom Voice selected-mode prewarm did not complete."]
        )
    }

    private enum LoadedModelWaitOutcome {
        case loaded
        case needsRetry
    }

    private func waitForLoadedModel(
        _ client: XPCNativeEngineClient,
        modelID: String,
        timeoutSeconds: TimeInterval
    ) async throws -> LoadedModelWaitOutcome {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var sawInProgressState = false
        while Date() < deadline {
            switch client.snapshot.loadState {
            case .loaded(let loadedModelID) where loadedModelID == modelID:
                return .loaded
            case .failed(let message):
                throw NSError(
                    domain: "GenerationQualityAuditLiveTests",
                    code: 12,
                    userInfo: [NSLocalizedDescriptionKey: "Selected-mode Custom Voice prewarm failed: \(message)"]
                )
            case .starting, .running:
                sawInProgressState = true
            case .idle where sawInProgressState && client.snapshot.isReady:
                return .needsRetry
            default:
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(
            domain: "GenerationQualityAuditLiveTests",
            code: 13,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for Custom Voice selected-mode prewarm."]
        )
    }

    private func generateArtifact(
        client: XPCNativeEngineClient,
        mode: AuditMode,
        iteration: Int,
        phase: AuditPhase,
        runIndex: Int,
        measured: Bool,
        qcEligible: Bool,
        appSupportRoot: URL,
        generatedRoot: URL,
        configuration: LiveAuditConfiguration,
        extraTimingsMS: [String: Int] = [:],
        extraBooleanFlags: [String: Bool] = [:],
        textOverride: String? = nil
    ) async throws -> AuditArtifact {
        let request = try makeRequest(
            mode: mode,
            iteration: iteration,
            phase: phase,
            runIndex: runIndex,
            outputRoot: generatedRoot,
            configuration: configuration,
            textOverride: textOverride
        )
        let started = DispatchTime.now().uptimeNanoseconds
        let result = try await client.generate(request)
        let wallClockMS = elapsedMilliseconds(since: started)

        return try makeArtifact(
            mode: mode,
            request: request,
            result: result,
            iteration: iteration,
            phase: phase,
            runIndex: runIndex,
            measured: measured,
            qcEligible: qcEligible,
            appSupportRoot: appSupportRoot,
            wallClockMS: wallClockMS,
            extraTimingsMS: extraTimingsMS,
            extraBooleanFlags: extraBooleanFlags
        )
    }

    private func makeArtifact(
        mode: AuditMode,
        request: GenerationRequest,
        result: GenerationResult,
        iteration: Int,
        phase: AuditPhase,
        runIndex: Int,
        measured: Bool,
        qcEligible: Bool,
        appSupportRoot: URL,
        wallClockMS: Int,
        extraTimingsMS: [String: Int] = [:],
        extraBooleanFlags: [String: Bool] = [:],
        segmentCount: Int? = nil,
        segmentIndex: Int? = nil,
        batchTotal: Int? = nil,
        deliveryAuditCase: DeliveryAuditCase? = nil
    ) throws -> AuditArtifact {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.audioPath),
            "Expected generated audio at \(result.audioPath)."
        )
        XCTAssertGreaterThan(result.durationSeconds, 0)
        if let sessionDirectory = result.streamSessionDirectory {
            try ensureSessionHasFinalWAV(
                sessionDirectory: URL(fileURLWithPath: sessionDirectory, isDirectory: true),
                finalAudioPath: result.audioPath
            )
        }

        let realTimeFactor = result.durationSeconds > 0
            ? (Double(wallClockMS) / 1_000.0) / result.durationSeconds
            : nil

        return AuditArtifact(
            iteration: iteration,
            phase: phase.rawValue,
            runIndex: runIndex,
            measured: measured,
            qcEligible: qcEligible,
            mode: mode.rawValue,
            modelID: request.modelID,
            text: request.text,
            textCharacterCount: request.text.count,
            textWordCount: Self.wordCount(request.text),
            segmentCount: segmentCount,
            segmentIndex: segmentIndex,
            batchTotal: batchTotal ?? request.batchTotal,
            speakerID: speakerID(from: request.payload),
            deliveryInstruction: deliveryInstruction(from: request.payload),
            resolvedQwenInstruction: resolvedQwenInstruction(for: request),
            deliveryAuditCaseID: deliveryAuditCase?.id,
            deliveryPresetID: deliveryAuditCase?.presetID,
            deliveryIntensity: deliveryAuditCase?.intensity,
            deliveryVoiceDescription: deliveryAuditCase?.voiceDescription,
            deliveryReferenceToneLabel: deliveryAuditCase?.referenceToneLabel,
            modelVariantKind: TTSModel.model(id: request.modelID)?.variantKind?.rawValue,
            modelBitDepth: TTSModel.model(id: request.modelID)?.variantKind?.bitDepthLabel,
            appSupportDirectory: appSupportRoot.path,
            outputPath: result.audioPath,
            streamSessionDirectory: result.streamSessionDirectory,
            durationSeconds: result.durationSeconds,
            audioFeatures: audioFeatures(for: result.audioPath, expectedText: request.text),
            wallClockMS: wallClockMS,
            realTimeFactor: realTimeFactor,
            streamingUsed: result.benchmarkSample?.streamingUsed ?? request.shouldStream,
            timingsMS: (result.benchmarkSample?.timingsMS ?? [:])
                .merging(extraTimingsMS) { current, _ in current }
                .merging(["request_wall_ms": wallClockMS]) { current, _ in current },
            booleanFlags: (result.benchmarkSample?.booleanFlags ?? [:])
                .merging(extraBooleanFlags) { current, _ in current },
            stringFlags: result.benchmarkSample?.stringFlags ?? [:]
        )
    }

    private func speakerID(from payload: GenerationRequest.Payload) -> String? {
        switch payload {
        case .custom(let speakerID, _):
            return speakerID
        case .design, .clone:
            return nil
        }
    }

    private func deliveryInstruction(from payload: GenerationRequest.Payload) -> String? {
        switch payload {
        case .custom(_, let deliveryStyle):
            return deliveryStyle?.nonEmpty
        case .design(let voiceDescription, let deliveryStyle):
            return [voiceDescription.nonEmpty, deliveryStyle?.nonEmpty]
                .compactMap { $0 }
                .joined(separator: " ")
                .nonEmpty
        case .clone:
            return nil
        }
    }

    private func resolvedQwenInstruction(for request: GenerationRequest) -> String? {
        switch request.payload {
        case .custom:
            return GenerationSemantics.customInstruction(for: request)
        case .design:
            return GenerationSemantics.voiceDesignInstruction(for: request)
        case .clone:
            return nil
        }
    }

    private func audioFeatures(
        for path: String,
        expectedText: String
    ) -> AudioFeatureSummary? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
            return nil
        }
        let durationSeconds = Double(file.length) / file.processingFormat.sampleRate
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            return AudioFeatureSummary(
                durationSeconds: durationSeconds,
                rmsAmplitude: nil,
                peakAmplitude: nil,
                clippingSampleCount: 0,
                estimatedWordsPerMinute: wordsPerMinute(text: expectedText, durationSeconds: durationSeconds)
            )
        }
        do {
            try file.read(into: buffer)
        } catch {
            return AudioFeatureSummary(
                durationSeconds: durationSeconds,
                rmsAmplitude: nil,
                peakAmplitude: nil,
                clippingSampleCount: 0,
                estimatedWordsPerMinute: wordsPerMinute(text: expectedText, durationSeconds: durationSeconds)
            )
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            return AudioFeatureSummary(
                durationSeconds: durationSeconds,
                rmsAmplitude: 0,
                peakAmplitude: 0,
                clippingSampleCount: 0,
                estimatedWordsPerMinute: wordsPerMinute(text: expectedText, durationSeconds: durationSeconds)
            )
        }

        var sumSquares = 0.0
        var peak = 0.0
        var clippingCount = 0
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<frameCount {
                let value = Double(channel[index])
                let magnitude = Swift.abs(value)
                sumSquares += value * value
                peak = Swift.max(peak, magnitude)
                if magnitude >= 0.999 {
                    clippingCount += 1
                }
            }
        } else if let channel = buffer.int16ChannelData?[0] {
            for index in 0..<frameCount {
                let value = Double(channel[index]) / Double(Int16.max)
                let magnitude = Swift.abs(value)
                sumSquares += value * value
                peak = Swift.max(peak, magnitude)
                if magnitude >= 0.999 {
                    clippingCount += 1
                }
            }
        }

        return AudioFeatureSummary(
            durationSeconds: durationSeconds,
            rmsAmplitude: sqrt(sumSquares / Double(frameCount)),
            peakAmplitude: peak,
            clippingSampleCount: clippingCount,
            estimatedWordsPerMinute: wordsPerMinute(text: expectedText, durationSeconds: durationSeconds)
        )
    }

    private func wordsPerMinute(text: String, durationSeconds: Double) -> Double? {
        guard durationSeconds > 0 else { return nil }
        return Double(Self.wordCount(text)) / durationSeconds * 60.0
    }

    private func loadLiveAuditConfiguration(environment: [String: String]) throws -> LiveAuditConfiguration {
        if environment["QWENVOICE_AUDIO_QC_LIVE"] == "1" {
            try XCTSkipUnless(
                environment["QWENVOICE_AUDIO_QC_ALLOW_MODEL_LOAD"] == "1",
                "Live audio QC generation requires QWENVOICE_AUDIO_QC_ALLOW_MODEL_LOAD=1."
            )
            let outputRoot = try requireURL(
                environment["QWENVOICE_AUDIO_QC_OUTPUT_DIR"],
                name: "QWENVOICE_AUDIO_QC_OUTPUT_DIR"
            )
            let modelsRoot = URL(
                fileURLWithPath: environment["QWENVOICE_AUDIO_QC_MODELS_ROOT"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty ?? defaultModelsRoot().path,
                isDirectory: true
            )
            let benchmarkProfile = try parseBenchmarkProfile(environment["QWENVOICE_AUDIO_QC_BENCHMARK_PROFILE"])
            let cloneReferences = parseCloneReferences(
                environment["QWENVOICE_AUDIO_QC_CLONE_REFERENCES"],
                fallbackReference: environment["QWENVOICE_AUDIO_QC_CLONE_REFERENCE"]?.nonEmpty,
                fallbackTranscript: environment["QWENVOICE_AUDIO_QC_CLONE_TRANSCRIPT"]?.nonEmpty,
                fallbackLabel: environment["QWENVOICE_AUDIO_QC_CLONE_TONE_LABEL"]?.nonEmpty
            )
            return LiveAuditConfiguration(
                outputRoot: outputRoot,
                modelsRoot: modelsRoot,
                modes: try parseModes(environment["QWENVOICE_AUDIO_QC_MODES"]),
                cloneReference: environment["QWENVOICE_AUDIO_QC_CLONE_REFERENCE"]?.nonEmpty,
                cloneTranscript: environment["QWENVOICE_AUDIO_QC_CLONE_TRANSCRIPT"]?.nonEmpty,
                repeatCount: try parseRepeatCount(environment["QWENVOICE_AUDIO_QC_REPEAT_COUNT"]),
                benchmarkProfile: benchmarkProfile,
                coldRuns: try parseBenchmarkRunCount(
                    environment["QWENVOICE_AUDIO_QC_COLD_RUNS"],
                    name: "cold"
                ),
                warmRuns: try parseBenchmarkRunCount(
                    environment["QWENVOICE_AUDIO_QC_WARM_RUNS"],
                    name: "warm"
                ),
                streamingIntervalOverride: try parseStreamingIntervalOverride(
                    environment["QWENVOICE_AUDIO_QC_STREAMING_INTERVAL"]
                ),
                customPrewarmDepth: environment["QWENVOICE_AUDIO_QC_CUSTOM_PREWARM_DEPTH"]?.nonEmpty,
                customVoiceProfile: environment["QWENVOICE_QWEN3_CUSTOM_VOICE_PROFILE"]?.nonEmpty,
                streamStepEvalPolicy: environment["QWENVOICE_QWEN3_STREAM_STEP_EVAL_POLICY"]?.nonEmpty,
                generationSpeedProfile: environment["QWENVOICE_QWEN3_GENERATION_SPEED_PROFILE"]?.nonEmpty,
                memoryClearCadence: environment["QWENVOICE_QWEN3_MEMORY_CLEAR_CADENCE"].flatMap(Int.init),
                postRequestCachePolicy: environment["QWENVOICE_QWEN3_POST_REQUEST_CACHE_POLICY"]?.nonEmpty,
                deliveryAuditVariants: try parseAuditVariants(
                    environment["QWENVOICE_AUDIO_QC_VARIANTS"],
                    benchmarkProfile: benchmarkProfile
                ),
                deliveryAuditScope: try parseDeliveryAuditScope(environment["QWENVOICE_AUDIO_QC_DELIVERY_SCOPE"]),
                cloneReferences: cloneReferences,
                cloneToneLabel: environment["QWENVOICE_AUDIO_QC_CLONE_TONE_LABEL"]?.nonEmpty,
                audioReview: try parseAudioReviewConfiguration(
                    enabledRawValue: environment["QWENVOICE_AUDIO_REVIEW_ENABLED"],
                    modelsRootRawValue: environment["QWENVOICE_AUDIO_REVIEW_MODELS_ROOT"],
                    strictnessRawValue: environment["QWENVOICE_AUDIO_REVIEW_STRICTNESS"],
                    minimumAvailableGBRawValue: environment["QWENVOICE_AUDIO_REVIEW_MIN_AVAILABLE_GB"],
                    memorySettleSecondsRawValue: environment["QWENVOICE_AUDIO_REVIEW_MEMORY_SETTLE_SECONDS"]
                )
            )
        }

        let requestURL = repositoryRoot()
            .appendingPathComponent("build/audio-qc/live-request.json")
        guard FileManager.default.fileExists(atPath: requestURL.path) else {
            throw XCTSkip("Set QWENVOICE_AUDIO_QC_LIVE=1 plus the audio-QC env and run `./scripts/qa.sh test --layer perf` to drive live audio QC generation.")
        }
        let request = try JSONDecoder().decode(LiveAuditRequest.self, from: Data(contentsOf: requestURL))
        guard request.live else {
            throw XCTSkip("Live audio QC request file is not marked live.")
        }
        guard request.allowModelLoad else {
            throw XCTSkip("Live audio QC request file does not allow model loading.")
        }
        guard let expiresAt = request.expiresAt,
              let expiry = ISO8601DateFormatter().date(from: expiresAt),
              expiry >= Date() else {
            throw XCTSkip("Live audio QC request file expired or was written by an older perf harness.")
        }
        let benchmarkProfile = try parseBenchmarkProfile(request.benchmarkProfile)
        let cloneReferences = parseCloneReferences(
            request.cloneReferences?.joined(separator: "|"),
            fallbackReference: request.cloneReference?.nonEmpty,
            fallbackTranscript: request.cloneTranscript?.nonEmpty,
            fallbackLabel: request.cloneToneLabel?.nonEmpty
        )
        return LiveAuditConfiguration(
            outputRoot: URL(fileURLWithPath: request.outputDirectory, isDirectory: true),
            modelsRoot: URL(fileURLWithPath: request.modelsRoot, isDirectory: true),
            modes: try parseModes(request.modes.joined(separator: ",")),
            cloneReference: request.cloneReference?.nonEmpty,
            cloneTranscript: request.cloneTranscript?.nonEmpty,
            repeatCount: try parseRepeatCount(request.repeatCount.map { String($0) }),
            benchmarkProfile: benchmarkProfile,
            coldRuns: try parseBenchmarkRunCount(request.coldRuns.map { String($0) }, name: "cold"),
            warmRuns: try parseBenchmarkRunCount(request.warmRuns.map { String($0) }, name: "warm"),
            streamingIntervalOverride: try parseStreamingIntervalOverride(
                request.streamingIntervalOverride.map { String($0) }
            ),
            customPrewarmDepth: request.customPrewarmDepth?.nonEmpty,
            customVoiceProfile: request.customVoiceProfile?.nonEmpty,
            streamStepEvalPolicy: request.streamStepEvalPolicy?.nonEmpty,
            generationSpeedProfile: request.generationSpeedProfile?.nonEmpty,
            memoryClearCadence: request.memoryClearCadence,
            postRequestCachePolicy: request.postRequestCachePolicy?.nonEmpty,
            deliveryAuditVariants: try parseAuditVariants(
                request.deliveryAuditVariants?.joined(separator: ","),
                benchmarkProfile: benchmarkProfile
            ),
            deliveryAuditScope: try parseDeliveryAuditScope(request.deliveryAuditScope),
            cloneReferences: cloneReferences,
            cloneToneLabel: request.cloneToneLabel?.nonEmpty,
            audioReview: try parseAudioReviewConfiguration(
                enabledRawValue: request.audioReviewEnabled.map { $0 ? "1" : "0" },
                modelsRootRawValue: request.audioReviewModelsRoot,
                strictnessRawValue: request.audioReviewStrictness,
                minimumAvailableGBRawValue: request.audioReviewMinimumAvailableGB.map { String($0) },
                memorySettleSecondsRawValue: request.audioReviewMemorySettleSeconds.map { String($0) }
            )
        )
    }

    private func parseAudioReviewConfiguration(
        enabledRawValue: String?,
        modelsRootRawValue: String?,
        strictnessRawValue: String?,
        minimumAvailableGBRawValue: String?,
        memorySettleSecondsRawValue: String?
    ) throws -> AudioReview.RunConfiguration? {
        let enabled = ["1", "true", "yes", "on"].contains(
            enabledRawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        )
        guard enabled else { return nil }
        let root = URL(
            fileURLWithPath: modelsRootRawValue?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? defaultAudioReviewModelsRoot().path,
            isDirectory: true
        )
        return AudioReview.RunConfiguration(
            enabled: true,
            modelsRoot: root,
            strictness: try AudioReview.parseStrictness(strictnessRawValue),
            minimumAvailableMemoryBytes: try parseAudioReviewMinimumAvailableMemoryBytes(
                minimumAvailableGBRawValue
            ),
            memorySettleSeconds: try parseAudioReviewMemorySettleSeconds(memorySettleSecondsRawValue)
        )
    }

    private func parseAudioReviewMinimumAvailableMemoryBytes(_ rawValue: String?) throws -> UInt64 {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return AudioReview.defaultMinimumAvailableMemoryBytes
        }
        guard let value = Double(trimmed), (0.5...128).contains(value) else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 16,
                userInfo: [NSLocalizedDescriptionKey: "Audio review minimum available memory must be between 0.5 and 128 GB."]
            )
        }
        return UInt64(value * 1_073_741_824)
    }

    private func parseAudioReviewMemorySettleSeconds(_ rawValue: String?) throws -> Double {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return AudioReview.defaultMemorySettleSeconds
        }
        guard let value = Double(trimmed), (0...30).contains(value) else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 17,
                userInfo: [NSLocalizedDescriptionKey: "Audio review memory settle seconds must be between 0 and 30."]
            )
        }
        return value
    }

    private func requireURL(_ rawValue: String?, name: String) throws -> URL {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing \(name)."]
            )
        }
        return URL(fileURLWithPath: rawValue, isDirectory: true)
            .standardizedFileURL
    }

    private func parseModes(_ rawValue: String?) throws -> [AuditMode] {
        let requested = rawValue?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let modeNames = requested.isEmpty ? ["CustomVoice", "VoiceDesign"] : requested
        let modes = try modeNames.map { name in
            guard let mode = AuditMode.parse(name) else {
                throw NSError(
                    domain: "GenerationQualityAuditLiveTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported audio QC mode '\(name)'."]
                )
            }
            return mode
        }
        var seen = Set<AuditMode>()
        return modes.filter { seen.insert($0).inserted }
    }

    private func parseRepeatCount(_ rawValue: String?) throws -> Int {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = trimmed.isEmpty ? 1 : Int(trimmed)
        guard let repeatCount = value, (1...10).contains(repeatCount) else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Audio QC repeat count must be between 1 and 10."]
            )
        }
        return repeatCount
    }

    private func parseBenchmarkProfile(_ rawValue: String?) throws -> BenchmarkProfile {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return .standard }
        guard let profile = BenchmarkProfile(rawValue: trimmed) else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported benchmark profile '\(trimmed)'."]
            )
        }
        return profile
    }

    private func parseAuditVariants(
        _ rawValue: String?,
        benchmarkProfile: BenchmarkProfile
    ) throws -> [AuditVariant] {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return benchmarkProfile == .deliveryMatrix ? AuditVariant.allCases : [.speed, .quality]
        }
        let requested = trimmed
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let variants = try requested.map { rawVariant in
            guard let variant = AuditVariant(rawValue: rawVariant) else {
                throw NSError(
                    domain: "GenerationQualityAuditLiveTests",
                    code: 18,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported audio QC variant '\(rawVariant)'."]
                )
            }
            return variant
        }
        var seen = Set<AuditVariant>()
        return variants.filter { seen.insert($0).inserted }
    }

    private func parseDeliveryAuditScope(_ rawValue: String?) throws -> DeliveryAuditScope {
        let trimmed = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !trimmed.isEmpty else { return .standard }
        guard let scope = DeliveryAuditScope(rawValue: trimmed) else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 19,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported delivery audit scope '\(trimmed)'."]
            )
        }
        return scope
    }

    private func parseCloneReferences(
        _ rawValue: String?,
        fallbackReference: String?,
        fallbackTranscript: String?,
        fallbackLabel: String?
    ) -> [CloneAuditReference] {
        let references = rawValue?
            .split(separator: "|")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let rawReferences = references.isEmpty ? fallbackReference.map { [$0] } ?? [] : references
        return rawReferences.map { path in
            CloneAuditReference(
                path: path,
                transcript: transcriptForCloneReference(path, fallbackTranscript: rawReferences.count == 1 ? fallbackTranscript : nil),
                label: labelForCloneReference(path, fallbackLabel: rawReferences.count == 1 ? fallbackLabel : nil)
            )
        }
    }

    private func transcriptForCloneReference(_ path: String, fallbackTranscript: String?) -> String? {
        if let fallbackTranscript = fallbackTranscript?.nonEmpty {
            return fallbackTranscript
        }
        let url = URL(fileURLWithPath: path)
        let sidecar = url.deletingPathExtension().appendingPathExtension("txt")
        guard let rawTranscript = try? String(contentsOf: sidecar, encoding: .utf8) else {
            return nil
        }
        let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            return nil
        }
        return transcript
    }

    private func labelForCloneReference(_ path: String, fallbackLabel: String?) -> String {
        if let fallbackLabel = fallbackLabel?.nonEmpty {
            return fallbackLabel
        }
        return URL(fileURLWithPath: path)
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
    }

    private func parseBenchmarkRunCount(_ rawValue: String?, name: String) throws -> Int {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let defaultValue = name == "cold" ? 2 : 3
        let value = trimmed.isEmpty ? defaultValue : Int(trimmed)
        guard let runCount = value, (1...10).contains(runCount) else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Audio QC \(name) run count must be between 1 and 10."]
            )
        }
        return runCount
    }

    private func parseStreamingIntervalOverride(_ rawValue: String?) throws -> Double? {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        guard let value = Double(trimmed), (0.1...1.5).contains(value) else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "Audio QC streaming interval override must be between 0.1 and 1.5 seconds."]
            )
        }
        return value
    }

    private func mirrorRequiredModels(
        for modes: [AuditMode],
        from modelsRoot: URL,
        into appSupportRoot: URL
    ) throws -> Int {
        try mirrorRequiredModels(
            forModelIDs: modes.map(\.modelID),
            from: modelsRoot,
            into: appSupportRoot
        )
    }

    private func mirrorRequiredModels(
        forModelIDs modelIDs: [String],
        from modelsRoot: URL,
        into appSupportRoot: URL
    ) throws -> Int {
        let started = DispatchTime.now().uptimeNanoseconds
        let destinationRoot = appSupportRoot.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        for modelID in modelIDs {
            let model = try resolvedAuditModelEntry(id: modelID)
            let source = modelsRoot.appendingPathComponent(model.folder, isDirectory: true)
            try validateInstalledModel(model, at: source)

            let destination = destinationRoot.appendingPathComponent(model.folder, isDirectory: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                do {
                    try validateInstalledModel(model, at: destination)
                    continue
                } catch {
                    try FileManager.default.removeItem(at: destination)
                }
            }
            try mirrorModelDirectory(from: source, to: destination)
        }
        return elapsedMilliseconds(since: started)
    }

    private func resolvedAuditModelEntry(id: String) throws -> NativeRuntimeTestSupport.ModelEntry {
        guard let model = TTSModel.model(id: id) else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing resolved app model entry for \(id)."]
            )
        }

        return NativeRuntimeTestSupport.ModelEntry(
            id: model.id,
            name: model.name,
            folder: model.folder,
            mode: model.mode.rawValue,
            requiredRelativePaths: model.requiredRelativePaths
        )
    }

    private func mirrorModelDirectory(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )

        let sourceContents = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )

        for sourceItem in sourceContents {
            if sourceItem.lastPathComponent.contains(".tmp.") {
                continue
            }
            let isDirectory = try sourceItem.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory ?? false
            let destinationItem = destination.appendingPathComponent(
                sourceItem.lastPathComponent,
                isDirectory: isDirectory
            )

            if isDirectory {
                try mirrorModelDirectory(from: sourceItem, to: destinationItem)
            } else {
                do {
                    try FileManager.default.linkItem(at: sourceItem, to: destinationItem)
                } catch {
                    try FileManager.default.copyItem(at: sourceItem, to: destinationItem)
                }
            }
        }
    }

    private func validateInstalledModel(
        _ model: NativeRuntimeTestSupport.ModelEntry,
        at source: URL
    ) throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Installed model '\(model.id)' is missing at \(source.path)."]
            )
        }
        for relativePath in model.requiredRelativePaths {
            let requiredURL = source.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: requiredURL.path) else {
                throw NSError(
                    domain: "GenerationQualityAuditLiveTests",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Installed model '\(model.id)' is incomplete; missing \(requiredURL.path)."]
                )
            }
        }
    }

    private func deliveryAuditCases(
        for mode: AuditMode,
        configuration: LiveAuditConfiguration? = nil,
        cloneToneLabel: String? = nil
    ) -> [DeliveryAuditCase] {
        if configuration?.deliveryAuditScope == .knownRisk {
            return knownRiskDeliveryAuditCases(for: mode)
        }
        if configuration?.deliveryAuditScope == .whisperRisk {
            return whisperRiskDeliveryAuditCases(for: mode)
        }

        if mode == .clones {
            let references = configuration?.cloneReferences ?? []
            guard !references.isEmpty else {
                return [
                    DeliveryAuditCase(
                        id: "reference-tone-transfer",
                        presetID: nil,
                        intensity: nil,
                        customText: nil,
                        deliveryInstruction: nil,
                        voiceDescription: nil,
                        speakerID: nil,
                        cloneReferencePath: nil,
                        cloneTranscript: nil,
                        text: "This cloned voice audit checks whether the reference tone carries through clearly.",
                        referenceToneLabel: cloneToneLabel?.nonEmpty ?? "reference"
                    ),
                ]
            }
            return references.map { reference in
                DeliveryAuditCase(
                    id: "reference-tone-transfer-\(slug(reference.label))",
                    presetID: nil,
                    intensity: nil,
                    customText: nil,
                    deliveryInstruction: nil,
                    voiceDescription: nil,
                    speakerID: nil,
                    cloneReferencePath: reference.path,
                    cloneTranscript: reference.transcript,
                    text: "This cloned voice audit checks whether the reference tone carries through clearly.",
                    referenceToneLabel: reference.label
                )
            }
        }

        let deliveryCases = deliveryControlCases(scope: configuration?.deliveryAuditScope ?? .standard)
        switch mode {
        case .customVoice:
            let speakers = configuration?.deliveryAuditScope == .full
                ? ["aiden", "ryan", "vivian", "serena"]
                : ["aiden"]
            return speakers.flatMap { speakerID in
                deliveryCases.map { base in
                    DeliveryAuditCase(
                        id: "speaker-\(speakerID)-\(base.id)",
                        presetID: base.presetID,
                        intensity: base.intensity,
                        customText: base.customText,
                        deliveryInstruction: base.deliveryInstruction,
                        voiceDescription: nil,
                        speakerID: speakerID,
                        cloneReferencePath: nil,
                        cloneTranscript: nil,
                        text: base.text,
                        referenceToneLabel: nil
                    )
                }
            }
        case .voiceDesign:
            let voiceBriefs: [(String, String)] = configuration?.deliveryAuditScope == .full
                ? [
                    ("studio-narrator", "A flexible English narrator with clean diction and a natural studio sound."),
                    ("warm-british", "A warm, deep narrator with a subtle British accent and polished audiobook delivery."),
                    ("bright-storyteller", "A bright, expressive storyteller with youthful energy and crisp pronunciation."),
                ]
                : [("studio-narrator", "A flexible English narrator with clean diction and a natural studio sound.")]
            return voiceBriefs.flatMap { briefID, voiceDescription in
                deliveryCases.map { base in
                    DeliveryAuditCase(
                        id: "brief-\(briefID)-\(base.id)",
                        presetID: base.presetID,
                        intensity: base.intensity,
                        customText: base.customText,
                        deliveryInstruction: base.deliveryInstruction,
                        voiceDescription: voiceDescription,
                        speakerID: nil,
                        cloneReferencePath: nil,
                        cloneTranscript: nil,
                        text: base.text,
                        referenceToneLabel: nil
                    )
                }
            }
        case .clones:
            return []
        }
    }

    private func knownRiskDeliveryAuditCases(for mode: AuditMode) -> [DeliveryAuditCase] {
        guard mode == .customVoice else { return [] }

        let neutral = DeliveryProfile.neutralInstruction
        let excitedStrong = EmotionPreset.preset(id: "excited")!.instruction(for: .strong)
        let text = "The delivery audit sentence is short, complete, and easy to compare across emotional styles."
        return [
            DeliveryAuditCase(
                id: "speaker-ryan-neutral-normal",
                presetID: "neutral",
                intensity: EmotionIntensity.normal.rpcValue,
                customText: nil,
                deliveryInstruction: neutral,
                voiceDescription: nil,
                speakerID: "ryan",
                cloneReferencePath: nil,
                cloneTranscript: nil,
                text: text,
                referenceToneLabel: nil
            ),
            DeliveryAuditCase(
                id: "speaker-ryan-excited-strong",
                presetID: "excited",
                intensity: EmotionIntensity.strong.rpcValue,
                customText: nil,
                deliveryInstruction: excitedStrong,
                voiceDescription: nil,
                speakerID: "ryan",
                cloneReferencePath: nil,
                cloneTranscript: nil,
                text: text,
                referenceToneLabel: nil
            ),
            DeliveryAuditCase(
                id: "speaker-aiden-excited-strong",
                presetID: "excited",
                intensity: EmotionIntensity.strong.rpcValue,
                customText: nil,
                deliveryInstruction: excitedStrong,
                voiceDescription: nil,
                speakerID: "aiden",
                cloneReferencePath: nil,
                cloneTranscript: nil,
                text: text,
                referenceToneLabel: nil
            ),
        ]
    }

    private func whisperRiskDeliveryAuditCases(for mode: AuditMode) -> [DeliveryAuditCase] {
        guard mode == .customVoice else { return [] }

        let whisperSubtle = EmotionPreset.preset(id: "whisper")!.instruction(for: .subtle)
        let whisperNormal = EmotionPreset.preset(id: "whisper")!.instruction(for: .normal)
        let whisperStrong = EmotionPreset.preset(id: "whisper")!.instruction(for: .strong)
        let text = "The delivery audit sentence is short, complete, and easy to compare across emotional styles."
        return [
            DeliveryAuditCase(
                id: "speaker-vivian-whisper-subtle",
                presetID: "whisper",
                intensity: EmotionIntensity.subtle.rpcValue,
                customText: nil,
                deliveryInstruction: whisperSubtle,
                voiceDescription: nil,
                speakerID: "vivian",
                cloneReferencePath: nil,
                cloneTranscript: nil,
                text: text,
                referenceToneLabel: nil
            ),
            DeliveryAuditCase(
                id: "speaker-vivian-whisper-normal",
                presetID: "whisper",
                intensity: EmotionIntensity.normal.rpcValue,
                customText: nil,
                deliveryInstruction: whisperNormal,
                voiceDescription: nil,
                speakerID: "vivian",
                cloneReferencePath: nil,
                cloneTranscript: nil,
                text: text,
                referenceToneLabel: nil
            ),
            DeliveryAuditCase(
                id: "speaker-vivian-whisper-strong",
                presetID: "whisper",
                intensity: EmotionIntensity.strong.rpcValue,
                customText: nil,
                deliveryInstruction: whisperStrong,
                voiceDescription: nil,
                speakerID: "vivian",
                cloneReferencePath: nil,
                cloneTranscript: nil,
                text: text,
                referenceToneLabel: nil
            ),
            DeliveryAuditCase(
                id: "speaker-ryan-whisper-subtle",
                presetID: "whisper",
                intensity: EmotionIntensity.subtle.rpcValue,
                customText: nil,
                deliveryInstruction: whisperSubtle,
                voiceDescription: nil,
                speakerID: "ryan",
                cloneReferencePath: nil,
                cloneTranscript: nil,
                text: text,
                referenceToneLabel: nil
            ),
            DeliveryAuditCase(
                id: "speaker-aiden-whisper-subtle",
                presetID: "whisper",
                intensity: EmotionIntensity.subtle.rpcValue,
                customText: nil,
                deliveryInstruction: whisperSubtle,
                voiceDescription: nil,
                speakerID: "aiden",
                cloneReferencePath: nil,
                cloneTranscript: nil,
                text: text,
                referenceToneLabel: nil
            ),
        ]
    }

    private func deliveryAuditCases(
        _ cases: [DeliveryAuditCase],
        for variant: AuditVariant,
        scope: DeliveryAuditScope
    ) -> [DeliveryAuditCase] {
        switch scope {
        case .standard, .full:
            return cases
        case .knownRisk:
            return cases.filter { auditCase in
                switch (auditCase.speakerID, auditCase.presetID, auditCase.intensity, variant) {
                case ("ryan", "neutral", EmotionIntensity.normal.rpcValue, .speed),
                     ("ryan", "excited", EmotionIntensity.strong.rpcValue, .speed),
                     ("ryan", "excited", EmotionIntensity.strong.rpcValue, .quality),
                     ("aiden", "excited", EmotionIntensity.strong.rpcValue, .speed):
                    true
                default:
                    false
                }
            }
        case .whisperRisk:
            return cases.filter { auditCase in
                switch (auditCase.speakerID, auditCase.presetID, auditCase.intensity, variant) {
                case ("vivian", "whisper", EmotionIntensity.subtle.rpcValue, .speed),
                     ("vivian", "whisper", EmotionIntensity.normal.rpcValue, .speed),
                     ("vivian", "whisper", EmotionIntensity.strong.rpcValue, .speed),
                     ("ryan", "whisper", EmotionIntensity.subtle.rpcValue, .speed),
                     ("aiden", "whisper", EmotionIntensity.subtle.rpcValue, .speed),
                     ("vivian", "whisper", EmotionIntensity.subtle.rpcValue, .quality):
                    true
                default:
                    false
                }
            }
        }
    }

    private func deliveryControlCases(scope: DeliveryAuditScope) -> [DeliveryAuditCase] {
        let presets: [(String, [EmotionIntensity])] = scope == .full
            ? EmotionPreset.all.map { preset in
                preset.id == "neutral" ? (preset.id, [.normal]) : (preset.id, EmotionIntensity.allCases)
            }
            : [
                ("neutral", [.normal]),
                ("happy", [.normal]),
                ("sad", [.normal]),
                ("angry", [.normal]),
                ("calm", [.normal]),
                ("whisper", [.normal]),
                ("dramatic", [.normal]),
                ("excited", [.normal]),
            ]

        let presetCases = presets.flatMap { presetID, intensities in
            intensities.compactMap { intensity -> DeliveryAuditCase? in
                guard let preset = EmotionPreset.preset(id: presetID) else { return nil }
                return DeliveryAuditCase(
                    id: "\(presetID)-\(intensity.rpcValue)",
                    presetID: presetID,
                    intensity: intensity.rpcValue,
                    customText: nil,
                    deliveryInstruction: preset.instruction(for: intensity),
                    voiceDescription: nil,
                    speakerID: nil,
                    cloneReferencePath: nil,
                    cloneTranscript: nil,
                    text: "The delivery audit sentence is short, complete, and easy to compare across emotional styles.",
                    referenceToneLabel: nil
                )
            }
        }

        let customCases = [
            DeliveryAuditCase(
                id: "custom-controlled-urgency",
                presetID: nil,
                intensity: EmotionIntensity.normal.rpcValue,
                customText: "Controlled urgency with quick pacing, focused stress, and clear pronunciation.",
                deliveryInstruction: "Controlled urgency with quick pacing, focused stress, and clear pronunciation.",
                voiceDescription: nil,
                speakerID: nil,
                cloneReferencePath: nil,
                cloneTranscript: nil,
                text: "The delivery audit sentence is short, complete, and easy to compare across emotional styles.",
                referenceToneLabel: nil
            ),
            DeliveryAuditCase(
                id: "custom-playful-conspiratorial",
                presetID: nil,
                intensity: EmotionIntensity.normal.rpcValue,
                customText: "Playful and conspiratorial, with a quiet smile, lively timing, and clear articulation.",
                deliveryInstruction: "Playful and conspiratorial, with a quiet smile, lively timing, and clear articulation.",
                voiceDescription: nil,
                speakerID: nil,
                cloneReferencePath: nil,
                cloneTranscript: nil,
                text: "The delivery audit sentence is short, complete, and easy to compare across emotional styles.",
                referenceToneLabel: nil
            ),
            DeliveryAuditCase(
                id: "custom-formal-authoritative",
                presetID: nil,
                intensity: EmotionIntensity.normal.rpcValue,
                customText: "Formal and authoritative, steady and precise, with confident emphasis and no melodrama.",
                deliveryInstruction: "Formal and authoritative, steady and precise, with confident emphasis and no melodrama.",
                voiceDescription: nil,
                speakerID: nil,
                cloneReferencePath: nil,
                cloneTranscript: nil,
                text: "The delivery audit sentence is short, complete, and easy to compare across emotional styles.",
                referenceToneLabel: nil
            ),
        ]
        return scope == .full ? presetCases + customCases : presetCases + [customCases[0]]
    }

    private func slug(_ value: String) -> String {
        let lowercased = value.lowercased()
        let parts = lowercased.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }
        return parts.joined()
            .split(separator: "-")
            .joined(separator: "-")
            .nonEmpty ?? "reference"
    }

    private func makeDeliveryAuditRequest(
        mode: AuditMode,
        model: TTSModel,
        variant: AuditVariant,
        auditCase: DeliveryAuditCase,
        index: Int,
        generatedRoot: URL,
        configuration: LiveAuditConfiguration
    ) throws -> GenerationRequest {
        let runRoot = generatedRoot
            .appendingPathComponent(AuditPhase.deliveryMatrix.rawValue, isDirectory: true)
            .appendingPathComponent(mode.rawValue, isDirectory: true)
            .appendingPathComponent(variant.rawValue, isDirectory: true)
            .appendingPathComponent(auditCase.id, isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        let outputURL = runRoot.appendingPathComponent("\(mode.fileStem)-\(String(format: "%03d", index)).wav")
        let streamingInterval = configuration.streamingIntervalOverride
            ?? GenerationSemantics.appStreamingInterval

        switch mode {
        case .customVoice:
            return GenerationRequest(
                modelID: model.id,
                text: auditCase.text,
                outputPath: outputURL.path,
                shouldStream: false,
                streamingInterval: streamingInterval,
                streamingTitle: "Delivery Audit Custom Voice",
                benchmarkOptions: benchmarkOptions(for: mode, configuration: configuration),
                payload: .custom(
                    speakerID: auditCase.speakerID ?? "aiden",
                    deliveryStyle: auditCase.deliveryInstruction
                )
            )
        case .voiceDesign:
            return GenerationRequest(
                modelID: model.id,
                text: auditCase.text,
                outputPath: outputURL.path,
                shouldStream: false,
                streamingInterval: streamingInterval,
                streamingTitle: "Delivery Audit Voice Design",
                benchmarkOptions: benchmarkOptions(for: mode, configuration: configuration),
                payload: .design(
                    voiceDescription: auditCase.voiceDescription ?? "",
                    deliveryStyle: auditCase.deliveryInstruction
                )
            )
        case .clones:
            let referencePath: String
            if let cloneReferencePath = auditCase.cloneReferencePath {
                referencePath = cloneReferencePath
            } else {
                referencePath = try requireCloneReference(configuration)
            }
            return GenerationRequest(
                modelID: model.id,
                text: auditCase.text,
                outputPath: outputURL.path,
                shouldStream: false,
                streamingInterval: streamingInterval,
                streamingTitle: "Delivery Audit Voice Clone",
                benchmarkOptions: benchmarkOptions(for: mode, configuration: configuration),
                payload: .clone(
                    reference: CloneReference(
                        audioPath: referencePath,
                        transcript: auditCase.cloneTranscript ?? configuration.cloneTranscript,
                        preparedVoiceID: nil
                    )
                )
            )
        }
    }

    private func makeRequest(
        mode: AuditMode,
        iteration: Int,
        phase: AuditPhase,
        runIndex: Int,
        outputRoot: URL,
        configuration: LiveAuditConfiguration,
        textOverride: String? = nil,
        outputURLOverride: URL? = nil,
        batchIndex: Int? = nil,
        batchTotal: Int? = nil
    ) throws -> GenerationRequest {
        let runRoot = outputRootForRun(
            mode: mode,
            iteration: iteration,
            phase: phase,
            runIndex: runIndex,
            outputRoot: outputRoot,
            configuration: configuration
        )
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        let outputURL = outputURLOverride ?? runRoot.appendingPathComponent("\(mode.fileStem).wav")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        switch mode {
        case .customVoice:
            let text = textOverride ?? "Hello from the Vocello audio quality audit with a clear complete short phrase for smooth playback"
            let streamingInterval = configuration.streamingIntervalOverride
                ?? GenerationSemantics.appStreamingInterval
            return GenerationRequest(
                modelID: mode.modelID,
                text: text,
                outputPath: outputURL.path,
                shouldStream: false,
                streamingInterval: streamingInterval,
                batchIndex: batchIndex,
                batchTotal: batchTotal,
                streamingTitle: "Audio QC Custom Voice",
                benchmarkOptions: benchmarkOptions(for: .customVoice, configuration: configuration),
                payload: .custom(
                    speakerID: "aiden",
                    deliveryStyle: "Conversational"
                )
            )
        case .voiceDesign:
            let text = textOverride ?? "Welcome to the Vocello generation quality audit with steady continuous speech and smooth playback throughout"
            let streamingInterval = configuration.streamingIntervalOverride
                ?? GenerationSemantics.appStreamingInterval
            return GenerationRequest(
                modelID: mode.modelID,
                text: text,
                outputPath: outputURL.path,
                shouldStream: false,
                streamingInterval: streamingInterval,
                batchIndex: batchIndex,
                batchTotal: batchTotal,
                streamingTitle: "Audio QC Voice Design",
                benchmarkOptions: benchmarkOptions(for: .voiceDesign, configuration: configuration),
                payload: .design(
                    voiceDescription: "A warm, steady narrator with clear pronunciation and calm pacing.",
                    deliveryStyle: "Neutral"
                )
            )
        case .clones:
            let referencePath = try requireCloneReference(configuration)
            let text = textOverride ?? "This is a short cloned voice quality audit for smooth playback and complete final audio."
            let streamingInterval = configuration.streamingIntervalOverride
                ?? GenerationSemantics.appStreamingInterval
            return GenerationRequest(
                modelID: mode.modelID,
                text: text,
                outputPath: outputURL.path,
                shouldStream: false,
                streamingInterval: streamingInterval,
                batchIndex: batchIndex,
                batchTotal: batchTotal,
                streamingTitle: "Audio QC Voice Clone",
                benchmarkOptions: benchmarkOptions(for: .clones, configuration: configuration),
                payload: .clone(
                    reference: CloneReference(
                        audioPath: referencePath,
                        transcript: configuration.cloneTranscript,
                        preparedVoiceID: nil
                    )
                )
            )
        }
    }

    private func benchmarkOptions(
        for mode: AuditMode,
        configuration: LiveAuditConfiguration
    ) -> GenerationRequest.BenchmarkOptions? {
        let streamStepEvalPolicy = configuration.streamStepEvalPolicy?.nonEmpty
        let generationSpeedProfile = configuration.generationSpeedProfile?.nonEmpty
        let memoryClearCadence = configuration.memoryClearCadence
        let postRequestCachePolicy = configuration.postRequestCachePolicy?.nonEmpty
        func makeOptions(
            customVoiceProfile: String? = nil,
            temperature: Double? = nil,
            topP: Double? = nil
        ) -> GenerationRequest.BenchmarkOptions {
            GenerationRequest.BenchmarkOptions(
                customVoiceProfile: customVoiceProfile,
                streamStepEvalPolicy: streamStepEvalPolicy,
                generationSpeedProfile: generationSpeedProfile,
                memoryClearCadence: memoryClearCadence,
                postRequestCachePolicy: postRequestCachePolicy,
                temperature: temperature,
                topP: topP
            )
        }

        if mode != .customVoice,
           streamStepEvalPolicy != nil || generationSpeedProfile != nil || memoryClearCadence != nil || postRequestCachePolicy != nil {
            return makeOptions()
        }

        guard let profile = configuration.customVoiceProfile?.nonEmpty else {
            if streamStepEvalPolicy != nil || generationSpeedProfile != nil || memoryClearCadence != nil || postRequestCachePolicy != nil {
                return makeOptions()
            }
            return nil
        }
        switch profile {
        case "balanced-short":
            return makeOptions(customVoiceProfile: profile, temperature: 0.7, topP: 0.9)
        case "conservative-short":
            return makeOptions(customVoiceProfile: profile, temperature: 0.65, topP: 0.88)
        case "fast-short":
            return makeOptions(customVoiceProfile: profile, temperature: 0.6, topP: 0.85)
        default:
            return makeOptions(customVoiceProfile: profile)
        }
    }

    private func outputRootForRun(
        mode: AuditMode,
        iteration: Int,
        phase: AuditPhase,
        runIndex: Int,
        outputRoot: URL,
        configuration: LiveAuditConfiguration
    ) -> URL {
        switch configuration.benchmarkProfile {
        case .standard:
            let runRoot = configuration.repeatCount > 1
                ? outputRoot.appendingPathComponent(String(format: "run_%03d", iteration), isDirectory: true)
                : outputRoot
            return runRoot.appendingPathComponent(mode.rawValue, isDirectory: true)
        case .coldWarm, .customUICold, .warmFocus, .exhaustive, .deliveryMatrix:
            return outputRoot
                .appendingPathComponent(phase.rawValue, isDirectory: true)
                .appendingPathComponent(mode.rawValue, isDirectory: true)
                .appendingPathComponent(String(format: "run_%03d", runIndex), isDirectory: true)
        }
    }

    private func requireCloneReference(_ configuration: LiveAuditConfiguration) throws -> String {
        guard let referencePath = configuration.cloneReference?.nonEmpty else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Clones mode requires QWENVOICE_AUDIO_QC_CLONE_REFERENCE."]
            )
        }
        guard FileManager.default.fileExists(atPath: referencePath) else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Clone reference does not exist at \(referencePath)."]
            )
        }
        return referencePath
    }

    private func ensureSessionHasFinalWAV(sessionDirectory: URL, finalAudioPath: String) throws {
        let finalURL = sessionDirectory.appendingPathComponent("final.wav")
        guard !FileManager.default.fileExists(atPath: finalURL.path) else { return }
        guard FileManager.default.fileExists(atPath: finalAudioPath) else { return }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: finalAudioPath), to: finalURL)
    }

    private func defaultModelsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QwenVoice/models", isDirectory: true)
    }

    private func defaultAudioReviewModelsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QwenVoice/audio-review-models", isDirectory: true)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func elapsedMilliseconds(since started: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
    }

    private static func longText(characterCount: Int, mode: AuditMode) -> String {
        precondition(characterCount > 0)
        let sentence: String
        switch mode {
        case .customVoice:
            sentence = "Aiden narrates a practical product update with calm pacing, clear consonants, and a steady rhythm for a long local synthesis benchmark."
        case .voiceDesign:
            sentence = "The designed narrator remains warm, precise, and unhurried while carrying a longer paragraph through several connected ideas for audio quality review."
        case .clones:
            sentence = "The cloned voice benchmark reads neutral operational prose with consistent cadence, moderate energy, and natural pauses across a longer passage."
        }

        var text = sentence
        while text.count < characterCount {
            text += " " + sentence
        }
        text = String(text.prefix(characterCount))
        if text.last?.isWhitespace == true {
            text.removeLast()
            text.append(".")
        }
        return text
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

private final class LiveChunkArtifactRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var nextChunkIndexBySession: [String: Int] = [:]

    func record(_ event: GenerationEvent) {
        guard case .chunk(let chunk) = event,
              let sessionDirectory = chunk.streamSessionDirectory?.nonEmpty,
              let previewAudio = chunk.previewAudio,
              !previewAudio.isFinal,
              !previewAudio.pcm16LE.isEmpty else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        do {
            let sessionURL = URL(fileURLWithPath: sessionDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
            let index = nextChunkIndexBySession[sessionDirectory, default: 0]
            nextChunkIndexBySession[sessionDirectory] = index + 1
            let chunkURL = sessionURL.appendingPathComponent(String(format: "chunk_%04d.wav", index))
            try Self.writePCM16MonoWAV(
                pcm16LE: previewAudio.pcm16LE,
                sampleRate: previewAudio.sampleRate,
                to: chunkURL
            )
        } catch {
            XCTFail("Failed to retain live preview chunk artifact: \(error)")
        }
    }

    private static func writePCM16MonoWAV(pcm16LE: Data, sampleRate: Int, to url: URL) throws {
        var data = Data()
        let byteRate = UInt32(sampleRate * 2)
        let blockAlign = UInt16(2)
        let dataSize = UInt32(pcm16LE.count)
        let fileSize = UInt32(36 + pcm16LE.count)

        data.appendASCII("RIFF")
        data.appendLittleEndian(fileSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(dataSize)
        data.append(pcm16LE)

        try data.write(to: url, options: .atomic)
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

private extension JSONEncoder {
    static var audioQCEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
