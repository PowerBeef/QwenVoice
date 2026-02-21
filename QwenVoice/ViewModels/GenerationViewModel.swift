import Foundation

/// Manages generation state and coordinates between PythonBridge, audio player, and history.
@MainActor
final class GenerationViewModel: ObservableObject {
    @Published var isGenerating = false
    @Published var lastError: String?
    @Published var currentModelId: String?

    private let pythonBridge: PythonBridge

    init(pythonBridge: PythonBridge) {
        self.pythonBridge = pythonBridge
    }

    /// Ensure the correct model is loaded for the given mode and tier.
    func ensureModelLoaded(mode: GenerationMode, tier: ModelTier) async throws {
        guard let model = TTSModel.model(for: mode, tier: tier) else {
            throw GenerationError.modelNotFound
        }

        if currentModelId != model.id {
            try await pythonBridge.loadModel(id: model.id)
            currentModelId = model.id
        }
    }

    /// Generate with custom voice and save to history.
    func generateCustom(text: String, voice: String, emotion: String, speed: Double, tier: ModelTier) async throws -> GenerationResult {
        isGenerating = true
        lastError = nil
        defer { isGenerating = false }

        do {
            try await ensureModelLoaded(mode: .custom, tier: tier)
            let outputPath = makeOutputPath(subfolder: "CustomVoice", text: text)
            let result = try await pythonBridge.generateCustom(
                text: text, voice: voice, emotion: emotion, speed: speed, outputPath: outputPath
            )
            saveToHistory(text: text, mode: "custom", tier: tier, voice: voice, emotion: emotion, speed: speed, result: result)
            return result
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Generate with voice design and save to history.
    func generateDesign(text: String, voiceDescription: String, tier: ModelTier) async throws -> GenerationResult {
        isGenerating = true
        lastError = nil
        defer { isGenerating = false }

        do {
            try await ensureModelLoaded(mode: .design, tier: tier)
            let outputPath = makeOutputPath(subfolder: "VoiceDesign", text: text)
            let result = try await pythonBridge.generateDesign(
                text: text, voiceDescription: voiceDescription, outputPath: outputPath
            )
            saveToHistory(text: text, mode: "design", tier: tier, voice: voiceDescription, result: result)
            return result
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Generate with voice cloning and save to history.
    func generateClone(text: String, refAudio: String, refText: String?, tier: ModelTier) async throws -> GenerationResult {
        isGenerating = true
        lastError = nil
        defer { isGenerating = false }

        do {
            try await ensureModelLoaded(mode: .clone, tier: tier)
            let outputPath = makeOutputPath(subfolder: "Clones", text: text)
            let result = try await pythonBridge.generateClone(
                text: text, refAudio: refAudio, refText: refText, outputPath: outputPath
            )
            let voiceName = URL(fileURLWithPath: refAudio).deletingPathExtension().lastPathComponent
            saveToHistory(text: text, mode: "clone", tier: tier, voice: voiceName, result: result)
            return result
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    // MARK: - History

    private func saveToHistory(text: String, mode: String, tier: ModelTier, voice: String? = nil,
                                emotion: String? = nil, speed: Double? = nil, result: GenerationResult) {
        var gen = Generation(
            text: text,
            mode: mode,
            modelTier: tier.rawValue,
            voice: voice,
            emotion: emotion,
            speed: speed,
            audioPath: result.audioPath,
            duration: result.durationSeconds,
            createdAt: Date()
        )
        try? DatabaseService.shared.saveGeneration(&gen)
    }
}

enum GenerationError: LocalizedError {
    case modelNotFound

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Required model is not available. Download it from Settings > Models."
        }
    }
}
