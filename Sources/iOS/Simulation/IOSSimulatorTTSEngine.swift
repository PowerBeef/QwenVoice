import Foundation
import QwenVoiceCore

enum IOSSimulatorRuntimeSupport {
    static var isSimulator: Bool {
#if targetEnvironment(simulator)
        true
#else
        false
#endif
    }

    /// When set on the simulator, overrides clone-capable UI gating for review (`0`/`false` = off).
    static var simCloneCapableOverride: Bool? {
        guard isSimulator else { return nil }
        let raw = ProcessInfo.processInfo.environment["QVOICE_SIM_CLONE_CAPABLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "0", "false", "no", "off":
            return false
        case "1", "true", "yes", "on":
            return true
        default:
            return nil
        }
    }

    static let unsupportedMessage =
        "Generation is unavailable in this runtime."
}

@MainActor
final class IOSSimulatorTTSEngine: TTSEngine, TTSEngineRuntimeControlling, ActiveGenerationCancellable, NativeMemoryReporting {
    @Published private(set) var loadState: EngineLoadState = .idle
    @Published private(set) var clonePreparationState: ClonePreparationState = .idle
    @Published private(set) var latestEvent: GenerationEvent?

    let modelRegistry: any ModelRegistry

    var isReady: Bool { isInitialized }
    private(set) var visibleErrorMessage: String?

    private static let supportedSavedVoiceAudioExtensions: Set<String> = ["wav", "mp3", "aiff", "m4a"]

    private let documentIO: any DocumentIO
    private let audioPreparationService: any AudioPreparationService
    private var isInitialized = false
    private var loadedModelID: String?
    private var cancelRequested = false
    private var allowsProactiveWarmOperations = true

    init(
        modelRegistry: any ModelRegistry,
        documentIO: any DocumentIO,
        audioPreparationService: any AudioPreparationService = NativeAudioPreparationService(
            preparedAudioDirectory: AppPaths.preparedAudioDir
        )
    ) {
        self.modelRegistry = modelRegistry
        self.documentIO = documentIO
        self.audioPreparationService = audioPreparationService
    }

    func supportDecision(for request: GenerationRequest) -> GenerationSupportDecision {
        guard modelRegistry.model(id: request.modelID) != nil else {
            return .unsupported(reason: "Unknown simulator model: \(request.modelID)")
        }
        return .supported(.nativeMLX)
    }

    func start() {
        if isInitialized {
            loadState = loadedModelID.map { .loaded(modelID: $0) } ?? .idle
        }
    }

    func stop() {
        isInitialized = false
        loadedModelID = nil
        loadState = .idle
        clonePreparationState = .idle
        latestEvent = nil
        visibleErrorMessage = nil
        cancelRequested = false
    }

    func initialize(appSupportDirectory: URL) async throws {
        let fileManager = FileManager.default
        for directory in [
            AppPaths.outputsDir,
            AppPaths.voicesDir,
            AppPaths.preparedAudioDir,
            AppPaths.importedReferenceAudioDir,
            AppPaths.normalizedCloneReferenceDir,
            AppPaths.streamSessionsDir,
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        isInitialized = true
        visibleErrorMessage = nil
        loadState = loadedModelID.map { .loaded(modelID: $0) } ?? .idle
        try await seedDataIfRequested()
    }

    func ping() async throws -> Bool {
        true
    }

    func loadModel(id: String) async throws {
        try ensureKnownModel(id)
        loadedModelID = id
        visibleErrorMessage = nil
        loadState = .loaded(modelID: id)
    }

    func unloadModel() async throws {
        loadedModelID = nil
        loadState = .idle
        latestEvent = nil
    }

    func prepareAudio(_ request: AudioPreparationRequest) async throws -> AudioNormalizationResult {
        try await audioPreparationService.normalizeAudio(request)
    }

    func ensureModelLoadedIfNeeded(id: String) async {
        guard modelRegistry.model(id: id) != nil else { return }
        loadedModelID = id
        loadState = .loaded(modelID: id)
    }

    func prewarmModelIfNeeded(for request: GenerationRequest) async {
        guard allowsProactiveWarmOperations,
              modelRegistry.model(id: request.modelID) != nil else { return }
        loadedModelID = request.modelID
        loadState = .loaded(modelID: request.modelID)
    }

    func prefetchInteractiveReadinessIfNeeded(
        for request: GenerationRequest
    ) async -> InteractivePrefetchDiagnostics? {
        await prewarmModelIfNeeded(for: request)
        return nil
    }

    func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {
        try ensureKnownModel(modelID)
        guard !reference.audioPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MLXTTSEngineError.generationFailed("Reference audio file not found.")
        }

        let key = GenerationSemantics.cloneReferenceIdentityKey(
            modelID: modelID,
            refAudio: reference.audioPath,
            refText: reference.transcript
        )
        clonePreparationState = .preparing(key: key)
        try await Task.sleep(nanoseconds: 220_000_000)
        try Task.checkCancellation()
        clonePreparationState = .primed(key: key)
        loadedModelID = modelID
        loadState = .loaded(modelID: modelID)
    }

    func cancelClonePreparationIfNeeded() async {
        clonePreparationState = .idle
    }

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        try ensureInitialized()
        let model = try ensureKnownModel(request.modelID)
        try validate(request)

        cancelRequested = false
        loadedModelID = request.modelID
        visibleErrorMessage = nil

        let scenario = IOSSimulatorBackendScenario.current
        let delay = scenario.delay
        let steps: [(Double, String)] = [
            (0.12, "Preparing request"),
            (0.38, "Rendering audio"),
            (0.72, "Shaping waveform"),
            (0.94, "Finalizing file"),
        ]
        let stepDelay = delay / UInt64(steps.count)
        var chunkSequence: UInt64 = 0

        do {
            for (fraction, message) in steps {
                try checkCancelled()
                loadState = .running(modelID: request.modelID, label: request.engineActivityLabel, fraction: fraction)
                latestEvent = .progress(GenerationProgress(percent: Int(fraction * 100), message: message))

                if fraction >= 0.38 {
                    chunkSequence += 1
                    let chunkDuration = max(0.15, resultDurationEstimate(for: request.text) * Double(fraction))
                    latestEvent = .chunk(
                        GenerationChunk(
                            mode: request.mode.rawValue,
                            title: request.text.prefix(48).description,
                            chunkPath: nil,
                            isFinal: false,
                            chunkDurationSeconds: chunkDuration * 0.4,
                            cumulativeDurationSeconds: chunkDuration * 0.4,
                            streamSessionDirectory: nil,
                            chunkSequence: chunkSequence
                        )
                    )
                }

                try await Task.sleep(nanoseconds: stepDelay)
            }

            try checkCancelled()

            if scenario.kind == .fail {
                let message = "Simulator fake backend failure for \(request.mode.displayName)."
                visibleErrorMessage = message
                latestEvent = .failed(message)
                loadState = .failed(message: message)
                throw MLXTTSEngineError.generationFailed(message)
            }

            let result = try IOSSimulatorPreviewAudioFactory.makeResult(
                mode: request.mode,
                text: request.text,
                outputPath: request.outputPath
            )
            chunkSequence += 1
            latestEvent = .chunk(
                GenerationChunk(
                    mode: request.mode.rawValue,
                    title: request.text.prefix(48).description,
                    chunkPath: result.audioPath,
                    isFinal: true,
                    chunkDurationSeconds: result.durationSeconds,
                    cumulativeDurationSeconds: result.durationSeconds,
                    streamSessionDirectory: nil,
                    chunkSequence: chunkSequence
                )
            )
            latestEvent = .completed(result)
            loadState = .loaded(modelID: model.id)
            visibleErrorMessage = nil
            return result
        } catch is CancellationError {
            cancelRequested = false
            latestEvent = nil
            loadState = .loaded(modelID: model.id)
            throw CancellationError()
        }
    }

    func cancelActiveGeneration() async throws {
        cancelRequested = true
        latestEvent = nil
        loadState = loadedModelID.map { .loaded(modelID: $0) } ?? .idle
    }

    func listPreparedVoices() async throws -> [PreparedVoice] {
        try ensureInitialized()
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: AppPaths.voicesDir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let files = (enumerator.allObjects as? [URL]) ?? []
        return files.compactMap { fileURL -> PreparedVoice? in
            guard Self.supportedSavedVoiceAudioExtensions.contains(fileURL.pathExtension.lowercased()) else {
                return nil
            }
            let voiceID = fileURL.deletingPathExtension().lastPathComponent
            let transcriptURL = fileURL.deletingPathExtension().appendingPathExtension("txt")
            return PreparedVoice(
                id: voiceID,
                name: voiceID,
                audioPath: fileURL.path,
                hasTranscript: fileManager.fileExists(atPath: transcriptURL.path)
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func enrollPreparedVoice(name: String, audioPath: String, transcript: String?) async throws -> PreparedVoice {
        try ensureInitialized()
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: audioPath)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw MLXTTSEngineError.generationFailed("Reference audio file not found.")
        }

        let safeName = Self.normalizedSavedVoiceName(name)
        guard !safeName.isEmpty else {
            throw MLXTTSEngineError.generationFailed("Invalid saved voice name.")
        }

        try fileManager.createDirectory(at: AppPaths.voicesDir, withIntermediateDirectories: true)
        let sourceExtension = sourceURL.pathExtension.lowercased()
        let destinationExtension = Self.supportedSavedVoiceAudioExtensions.contains(sourceExtension)
            ? sourceExtension
            : "wav"
        let audioDestinationURL = AppPaths.voicesDir.appendingPathComponent("\(safeName).\(destinationExtension)")
        let transcriptDestinationURL = AppPaths.voicesDir.appendingPathComponent("\(safeName).txt")

        let nameConflictExists = Self.supportedSavedVoiceAudioExtensions.contains { ext in
            fileManager.fileExists(atPath: AppPaths.voicesDir.appendingPathComponent("\(safeName).\(ext)").path)
        } || fileManager.fileExists(atPath: transcriptDestinationURL.path)
        if nameConflictExists {
            throw MLXTTSEngineError.generationFailed(
                "A saved voice named \"\(safeName)\" already exists. Choose a different name."
            )
        }

        try fileManager.copyItem(at: sourceURL, to: audioDestinationURL)
        let normalizedTranscript = transcript?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        if let normalizedTranscript {
            try normalizedTranscript.write(to: transcriptDestinationURL, atomically: true, encoding: .utf8)
        }

        return PreparedVoice(
            id: safeName,
            name: safeName,
            audioPath: audioDestinationURL.path,
            hasTranscript: normalizedTranscript != nil
        )
    }

    func deletePreparedVoice(id: String) async throws {
        try ensureInitialized()
        let fileManager = FileManager.default
        let audioURLs = Self.supportedSavedVoiceAudioExtensions
            .map { AppPaths.voicesDir.appendingPathComponent("\(id).\($0)") }
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard !audioURLs.isEmpty else {
            throw MLXTTSEngineError.generationFailed("Voice '\(id)' does not exist.")
        }
        for url in audioURLs {
            try fileManager.removeItem(at: url)
        }

        let transcriptURL = AppPaths.voicesDir.appendingPathComponent("\(id).txt")
        if fileManager.fileExists(atPath: transcriptURL.path) {
            try? fileManager.removeItem(at: transcriptURL)
        }
        let clonePromptURL = AppPaths.voicesDir.appendingPathComponent("\(id).clone_prompt", isDirectory: true)
        if fileManager.fileExists(atPath: clonePromptURL.path) {
            try? fileManager.removeItem(at: clonePromptURL)
        }
    }

    func importReferenceAudio(from sourceURL: URL) throws -> ImportedReferenceAudio {
        try documentIO.importReferenceAudio(from: sourceURL)
    }

    func exportGeneratedAudio(from sourceURL: URL, to destinationURL: URL) throws -> ExportedDocument {
        try documentIO.exportGeneratedAudio(from: sourceURL, to: destinationURL)
    }

    func clearGenerationActivity() {
        latestEvent = nil
        loadState = loadedModelID.map { .loaded(modelID: $0) } ?? .idle
    }

    func clearVisibleError() {
        visibleErrorMessage = nil
        if case .failed = loadState {
            loadState = loadedModelID.map { .loaded(modelID: $0) } ?? .idle
        }
    }

    func setVisibleError(_ message: String?) {
        visibleErrorMessage = message
        if let message {
            loadState = .failed(message: message)
        }
    }

    func setAllowsProactiveWarmOperations(_ allow: Bool) {
        allowsProactiveWarmOperations = allow
    }

    func captureMemorySnapshot(role: IOSMemoryProcessRole) async -> IOSMemorySnapshot? {
        IOSMemorySnapshot.capture(role: role)
    }

    func trimMemory(level: NativeMemoryTrimLevel, reason: String) async {
        switch level {
        case .softTrim:
            break
        case .hardTrim, .fullUnload:
            loadedModelID = nil
            loadState = .idle
        }
    }

    private func validate(_ request: GenerationRequest) throws {
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MLXTTSEngineError.generationFailed("Enter a script to generate audio.")
        }
        switch request.payload {
        case .custom:
            break
        case .design(let voiceDescription, _):
            guard !voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MLXTTSEngineError.generationFailed("Describe the voice before generating.")
            }
        case .clone(let reference):
            if IOSSimulatorBackendScenario.current.kind == .cloneMissingRef {
                throw MLXTTSEngineError.generationFailed("Choose a reference voice before generating.")
            }
            guard !reference.audioPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MLXTTSEngineError.generationFailed("Choose a reference voice before generating.")
            }
        }
    }

    private func resultDurationEstimate(for text: String) -> Double {
        max(0.8, Double(text.count) * 0.04)
    }

    private func checkCancelled() throws {
        if cancelRequested || Task.isCancelled {
            cancelRequested = false
            latestEvent = nil
            loadState = loadedModelID.map { .loaded(modelID: $0) } ?? .idle
            throw CancellationError()
        }
    }

    private func ensureInitialized() throws {
        guard isInitialized else {
            throw MLXTTSEngineError.notInitialized
        }
    }

    @discardableResult
    private func ensureKnownModel(_ id: String) throws -> ModelDescriptor {
        guard let model = modelRegistry.model(id: id) else {
            throw MLXTTSEngineError.unknownModel(id)
        }
        return model
    }

    private static func normalizedSavedVoiceName(_ rawName: String) -> String {
        rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"[\\/:*?"<>|\p{Cc}]"#,
                with: "",
                options: .regularExpression
            )
    }

    private func seedDataIfRequested() async throws {
        let tokens = ProcessInfo.processInfo.environment["QVOICE_SIM_SEED_DATA"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? []
        guard !tokens.isEmpty else { return }

        if tokens.contains("voices") {
            try seedSavedVoicesIfNeeded()
        }
        if tokens.contains("history") {
            try await seedHistoryIfNeeded()
        }
    }

    private func seedSavedVoicesIfNeeded() throws {
        let seedURL = AppPaths.voicesDir.appendingPathComponent("Simulator Narrator.wav")
        guard !FileManager.default.fileExists(atPath: seedURL.path) else { return }
        _ = try IOSSimulatorPreviewAudioFactory.makeResult(
            mode: .clone,
            text: "Simulator saved voice seed",
            outputPath: seedURL.path
        )
        try "A steady simulator reference voice for clone UI review.".write(
            to: AppPaths.voicesDir.appendingPathComponent("Simulator Narrator.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func seedHistoryIfNeeded() async throws {
        let outputURL = AppPaths.outputsDir
            .appendingPathComponent("simulator_seed", isDirectory: true)
            .appendingPathComponent("Simulator History.wav")
        let result = try IOSSimulatorPreviewAudioFactory.makeResult(
            mode: .custom,
            text: "Simulator history seed",
            outputPath: outputURL.path
        )
        let existing = (try? DatabaseService.shared.fetchAllGenerations()) ?? []
        guard !existing.contains(where: { $0.audioPath == result.audioPath }) else { return }
        let generation = Generation(
            text: "This simulator history item lets the player sheet and row menus be tested without running MLX.",
            mode: GenerationMode.custom.rawValue,
            modelTier: "Simulator",
            voice: "Simulator Narrator",
            emotion: nil,
            speed: nil,
            audioPath: result.audioPath,
            duration: result.durationSeconds,
            createdAt: Date()
        )
        _ = try await DatabaseService.shared.saveGenerationAsync(generation)
    }
}

private struct IOSSimulatorBackendScenario {
    enum Kind {
        case success
        case slow
        case fail
        case cancelMid
        case cloneMissingRef
    }

    let kind: Kind
    let delay: UInt64

    static var current: IOSSimulatorBackendScenario {
        let environment = ProcessInfo.processInfo.environment
        let kind: Kind
        switch environment["QVOICE_SIM_BACKEND_SCENARIO"]?.lowercased() {
        case "slow":
            kind = .slow
        case "fail", "failure", "error":
            kind = .fail
        case "cancel_mid", "cancel-mid":
            kind = .cancelMid
        case "clone_missing_ref", "clone-missing-ref":
            kind = .cloneMissingRef
        default:
            kind = .success
        }

        let defaultMilliseconds: Int
        switch kind {
        case .success:
            defaultMilliseconds = 900
        case .slow:
            defaultMilliseconds = 6_000
        case .fail:
            defaultMilliseconds = 900
        case .cancelMid:
            defaultMilliseconds = 12_000
        case .cloneMissingRef:
            defaultMilliseconds = 900
        }

        let requestedMilliseconds = environment["QVOICE_SIM_BACKEND_DELAY_MS"]
            .flatMap(Int.init)
            .map { min(max($0, 0), 30_000) }
            ?? defaultMilliseconds

        return IOSSimulatorBackendScenario(
            kind: kind,
            delay: UInt64(requestedMilliseconds) * 1_000_000
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
