import SwiftUI

struct EmotionPickerView: View {
    @Binding var emotion: String

    @State private var selectedPreset: EmotionPreset?
    @State private var intensity: EmotionIntensity = .normal
    @State private var isCustomMode = false
    @State private var customText = ""

    private var isNeutralSelected: Bool {
        selectedPreset?.id == "neutral"
    }

    private var selectedEmotionColor: Color {
        guard let preset = selectedPreset else { return AppTheme.customVoice }
        return AppTheme.emotionColor(for: preset.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Emotion").sectionHeader(color: AppTheme.customVoice)

            // Chip grid: presets + Custom
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 12)], spacing: 12) {
                ForEach(EmotionPreset.all) { preset in
                    let chipColor = AppTheme.emotionColor(for: preset.id)
                    let isSelected = !isCustomMode && selectedPreset?.id == preset.id
                    Button {
                        selectPreset(preset)
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: preset.sfSymbol)
                                .font(.title3)
                            Text(preset.label)
                                .font(.caption.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(isSelected ? chipColor : Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(isSelected ? Color.white.opacity(0.3) : Color.primary.opacity(0.08), lineWidth: 1)
                        )
                        .foregroundColor(isSelected ? .white : .primary.opacity(0.8))
                        .shadow(color: isSelected ? chipColor.opacity(0.4) : .clear, radius: 8, y: 4)
                        .scaleEffect(isSelected ? 1.05 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("customVoice_emotion_\(preset.id)")
                }

                // Custom chip
                Button {
                    enterCustomMode()
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "pencil.line")
                            .font(.title3)
                        Text("Custom")
                            .font(.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(isCustomMode ? AppTheme.customVoice : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isCustomMode ? Color.white.opacity(0.3) : Color.secondary.opacity(0.3),
                                style: StrokeStyle(lineWidth: 1, dash: isCustomMode ? [] : [4, 4])
                            )
                    )
                    .foregroundColor(isCustomMode ? .white : .secondary)
                    .shadow(color: isCustomMode ? AppTheme.customVoice.opacity(0.4) : .clear, radius: 8, y: 4)
                    .contentShape(Rectangle())
                    .scaleEffect(isCustomMode ? 1.05 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isCustomMode)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("customVoice_emotion_custom")
            }

            // Intensity selector (visible for non-neutral presets)
            if !isCustomMode && selectedPreset != nil && !isNeutralSelected {
                Picker("Intensity", selection: $intensity) {
                    ForEach(EmotionIntensity.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .tint(selectedEmotionColor)
                .accessibilityIdentifier("customVoice_intensityPicker")
                .onChange(of: intensity) { _, _ in
                    if let preset = selectedPreset {
                        emotion = preset.instruction(for: intensity)
                    }
                }
            }

            // Custom text field (only in custom mode)
            if isCustomMode {
                TextField("e.g. Excited and happy, speaking very fast", text: $customText)
                    .textFieldStyle(.plain)
                    .padding(16)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .accessibilityIdentifier("customVoice_emotionField")
                    .onChange(of: customText) { _, newValue in
                        emotion = newValue
                    }
            }
        }
        .onAppear {
            syncSelectionFromText()
        }
    }

    private func selectPreset(_ preset: EmotionPreset) {
        withAnimation(.easeInOut(duration: 0.2)) {
            isCustomMode = false
            selectedPreset = preset
        }
        emotion = preset.instruction(for: intensity)
    }

    private func enterCustomMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedPreset = nil
            isCustomMode = true
        }
        customText = ""
        emotion = ""
    }

    private func syncSelectionFromText() {
        for preset in EmotionPreset.all {
            for level in EmotionIntensity.allCases {
                if preset.instruction(for: level) == emotion {
                    selectedPreset = preset
                    intensity = level
                    isCustomMode = false
                    return
                }
            }
        }
        // No preset match — enter custom mode if non-empty
        if !emotion.isEmpty && emotion != "Normal tone" {
            isCustomMode = true
            customText = emotion
        } else if emotion.isEmpty || emotion == "Normal tone" {
            // Default to Neutral selected
            selectedPreset = EmotionPreset.all.first
            isCustomMode = false
        }
    }
}
