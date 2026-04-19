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

    static let unsupportedMessage =
        "Generation is unavailable in the iOS Simulator. Use a real iPhone for MLX generation, playback, and performance testing."
}

@MainActor
final class IOSSimulatorTTSEngine: TTSEngine {
    @Published private(set) var loadState: EngineLoadState = .idle
    @Published private(set) var clonePreparationState: ClonePreparationState = .idle
    @Published private(set) var latestEvent: GenerationEvent?

    let modelRegistry: any ModelRegistry

    var isReady: Bool { isInitialized }
    private(set) var visibleErrorMessage: String?

    private let documentIO: any DocumentIO
    private let audioPreparationService: any AudioPreparationService
    private var isInitialized = false
    private var preparedVoices: [PreparedVoice] = []

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
        self.visibleErrorMessage = IOSSimulatorRuntimeSupport.unsupportedMessage
    }

    func supportDecision(for request: GenerationRequest) -> GenerationSupportDecision {
        .unsupported(reason: IOSSimulatorRuntimeSupport.unsupportedMessage)
    }

    func start() {}

    func stop() {
        isInitialized = false
        loadState = .idle
        clonePreparationState = .idle
        latestEvent = nil
        visibleErrorMessage = IOSSimulatorRuntimeSupport.unsupportedMessage
    }

    func initialize(appSupportDirectory: URL) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: AppPaths.preparedAudioDir,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: AppPaths.importedReferenceAudioDir,
            withIntermediateDirectories: true
        )
        isInitialized = true
        loadState = .idle
        visibleErrorMessage = IOSSimulatorRuntimeSupport.unsupportedMessage
    }

    func ping() async throws -> Bool {
        true
    }

    func loadModel(id: String) async throws {
        guard modelRegistry.model(id: id) != nil else {
            throw MLXTTSEngineError.unknownModel(id)
        }
        loadState = .idle
    }

    func unloadModel() async throws {
        loadState = .idle
        latestEvent = nil
    }

    func prepareAudio(_ request: AudioPreparationRequest) async throws -> AudioNormalizationResult {
        try await audioPreparationService.normalizeAudio(request)
    }

    func ensureModelLoadedIfNeeded(id: String) async {}

    func prewarmModelIfNeeded(for request: GenerationRequest) async {}

    func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {}

    func cancelClonePreparationIfNeeded() async {
        clonePreparationState = .idle
    }

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        let message = IOSSimulatorRuntimeSupport.unsupportedMessage
        latestEvent = .failed(message)
        visibleErrorMessage = message
        throw MLXTTSEngineError.unsupportedRequest(message)
    }

    func listPreparedVoices() async throws -> [PreparedVoice] {
        preparedVoices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func enrollPreparedVoice(name: String, audioPath: String, transcript: String?) async throws -> PreparedVoice {
        let voice = PreparedVoice(
            id: UUID().uuidString,
            name: name,
            audioPath: audioPath,
            hasTranscript: !(transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        )
        preparedVoices.removeAll { $0.id == voice.id }
        preparedVoices.append(voice)
        return voice
    }

    func deletePreparedVoice(id: String) async throws {
        preparedVoices.removeAll { $0.id == id }
    }

    func importReferenceAudio(from sourceURL: URL) throws -> ImportedReferenceAudio {
        try documentIO.importReferenceAudio(from: sourceURL)
    }

    func exportGeneratedAudio(from sourceURL: URL, to destinationURL: URL) throws -> ExportedDocument {
        try documentIO.exportGeneratedAudio(from: sourceURL, to: destinationURL)
    }

    func clearGenerationActivity() {
        latestEvent = nil
        loadState = .idle
    }

    func clearVisibleError() {
        visibleErrorMessage = nil
    }
}
