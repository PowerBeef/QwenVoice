import SwiftUI

struct CustomVoiceView: View {
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel

    @State private var selectedSpeaker = "vivian"
    @State private var emotion = "Normal tone"
    @State private var speed: Double = 1.0
    @State private var text = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var selectedTier: ModelTier = .pro
    @State private var showingBatch = false

    private var isModelDownloaded: Bool {
        guard let model = TTSModel.model(for: .custom, tier: selectedTier) else { return false }
        let modelDir = QwenVoiceApp.modelsDir.appendingPathComponent(model.folder)
        return FileManager.default.fileExists(atPath: modelDir.path)
    }

    private var modelDisplayName: String {
        TTSModel.model(for: .custom, tier: selectedTier)?.displayName ?? "Unknown"
    }

    private let speeds: [(String, Double)] = [
        ("Slow (0.8x)", 0.8),
        ("Normal (1.0x)", 1.0),
        ("Fast (1.3x)", 1.3),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header with model picker and batch button
                HStack {
                    Text("Custom Voice")
                        .font(.title2.bold())
                        .accessibilityIdentifier("customVoice_title")
                    Spacer()

                    Button {
                        showingBatch = true
                    } label: {
                        Label("Batch", systemImage: "list.bullet.rectangle")
                    }
                    .disabled(!pythonBridge.isReady || !isModelDownloaded)
                    .accessibilityIdentifier("customVoice_batchButton")

                    Picker("Model", selection: $selectedTier) {
                        ForEach(ModelTier.allCases, id: \.self) { tier in
                            Text(tier.displayName).tag(tier)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .accessibilityIdentifier("customVoice_tierPicker")
                }

                if !isModelDownloaded {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Model \"\(modelDisplayName)\" is not downloaded.")
                            .font(.callout)
                        Spacer()
                        Button("Go to Models") {
                            NotificationCenter.default.post(name: .navigateToModels, object: nil)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("customVoice_goToModels")
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.orange.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
                    .accessibilityIdentifier("customVoice_modelBanner")
                }

                // Speaker picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speaker").font(.headline)
                    FlowLayout(spacing: 8) {
                        ForEach(TTSModel.allSpeakers, id: \.self) { speaker in
                            Button {
                                selectedSpeaker = speaker
                            } label: {
                                Text(speaker)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(selectedSpeaker == speaker ? Color.accentColor : Color.gray.opacity(0.15))
                                    )
                                    .foregroundColor(selectedSpeaker == speaker ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("customVoice_speaker_\(speaker)")
                        }
                    }
                }

                // Emotion
                VStack(alignment: .leading, spacing: 8) {
                    Text("Emotion / Instruction").font(.headline)
                    TextField("e.g. Excited and happy, speaking very fast", text: $emotion)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("customVoice_emotionField")
                }

                // Speed
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speed").font(.headline)
                    Picker("Speed", selection: $speed) {
                        ForEach(speeds, id: \.1) { label, value in
                            Text(label).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 350)
                    .accessibilityIdentifier("customVoice_speedPicker")
                }

                // Text input + Generate
                TextInputView(
                    text: $text,
                    isGenerating: isGenerating,
                    onGenerate: generate
                )
                .disabled(!pythonBridge.isReady || !isModelDownloaded)

                // Error display
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                        .font(.callout)
                }

                // Progress
                if isGenerating {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(pythonBridge.progressMessage.isEmpty ? "Generating..." : pythonBridge.progressMessage)
                            .foregroundColor(.secondary)
                    }
                }

                if !pythonBridge.isReady {
                    Label("Waiting for backend to start...", systemImage: "hourglass")
                        .foregroundColor(.orange)
                        .font(.callout)
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showingBatch) {
            BatchGenerationSheet(
                mode: .custom,
                tier: selectedTier,
                voice: selectedSpeaker,
                emotion: emotion,
                speed: speed
            )
            .environmentObject(pythonBridge)
            .environmentObject(audioPlayer)
        }
    }

    private func generate() {
        guard !text.isEmpty, pythonBridge.isReady else { return }

        // Check if model folder exists
        if let model = TTSModel.model(for: .custom, tier: selectedTier) {
            let modelDir = QwenVoiceApp.modelsDir.appendingPathComponent(model.folder)
            if !FileManager.default.fileExists(atPath: modelDir.path) {
                errorMessage = "Model '\(model.displayName)' is not downloaded. Go to Settings > Models to download it."
                return
            }
        }

        isGenerating = true
        errorMessage = nil

        Task {
            do {
                guard let model = TTSModel.model(for: .custom, tier: selectedTier) else {
                    errorMessage = "Model configuration not found"
                    isGenerating = false
                    return
                }

                try await pythonBridge.loadModel(id: model.id)

                let outputPath = makeOutputPath(subfolder: "CustomVoice", text: text)
                let result = try await pythonBridge.generateCustom(
                    text: text,
                    voice: selectedSpeaker,
                    emotion: emotion,
                    speed: speed,
                    outputPath: outputPath
                )

                // Save to history
                var gen = Generation(
                    text: text,
                    mode: "custom",
                    modelTier: selectedTier.rawValue,
                    voice: selectedSpeaker,
                    emotion: emotion,
                    speed: speed,
                    audioPath: result.audioPath,
                    duration: result.durationSeconds,
                    createdAt: Date()
                )
                try? DatabaseService.shared.saveGeneration(&gen)

                audioPlayer.playFile(result.audioPath, title: String(text.prefix(40)))
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }
}

/// Simple flow layout for wrapping speaker buttons.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}
