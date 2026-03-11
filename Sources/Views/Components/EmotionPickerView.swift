import SwiftUI

struct EmotionPickerView: View {
    @Binding var emotion: String
    var title: String = "Tone"
    var accentColor: Color = AppTheme.accent
    var accessibilityPrefix: String = "delivery"

    @State private var selectedPreset: EmotionPreset?
    @State private var intensity: EmotionIntensity = .normal
    @State private var isCustomMode = false
    @State private var customText = ""
    @State private var isPickerExpanded = false

    private var isNeutralSelected: Bool {
        selectedPreset?.id == "neutral"
    }

    private var selectedEmotionColor: Color {
        guard let preset = selectedPreset else { return accentColor }
        return AppTheme.emotionColor(for: preset.id)
    }

    private var currentToneLabel: String {
        if isCustomMode {
            return customText.isEmpty ? "Custom tone" : "Custom tone"
        }

        if let selectedPreset {
            return selectedPreset.id == "neutral" ? "Normal tone" : selectedPreset.label
        }

        return "Normal tone"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                AppLaunchConfiguration.performAnimated(.easeInOut(duration: 0.18)) {
                    isPickerExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Text(currentToneLabel)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 12)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: LayoutConstants.cardBorderWidth)
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(accessibilityPrefix)_tonePicker")
            .popover(isPresented: $isPickerExpanded, arrowEdge: .top) {
                VStack(spacing: 8) {
                    ForEach(EmotionPreset.all) { preset in
                        toneOptionButton(
                            label: preset.id == "neutral" ? "Normal tone" : preset.label,
                            icon: preset.sfSymbol,
                            isSelected: !isCustomMode && selectedPreset?.id == preset.id,
                            accessibilityIdentifier: "\(accessibilityPrefix)_tone_\(preset.id)"
                        ) {
                            selectPreset(preset)
                        }
                    }

                    toneOptionButton(
                        label: "Custom",
                        icon: "pencil.line",
                        isSelected: isCustomMode,
                        accessibilityIdentifier: "\(accessibilityPrefix)_tone_custom"
                    ) {
                        enterCustomMode()
                    }
                }
                .padding(8)
                .frame(width: 252)
                .background(AppTheme.canvasBase)
            }

            if !isCustomMode && selectedPreset != nil && !isNeutralSelected {
                Picker("Intensity", selection: $intensity) {
                    ForEach(EmotionIntensity.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .tint(selectedEmotionColor)
                .accessibilityIdentifier("\(accessibilityPrefix)_intensityPicker")
                .onChange(of: intensity) { _, _ in
                    if let preset = selectedPreset {
                        emotion = preset.instruction(for: intensity)
                    }
                }
            }

            if isCustomMode {
                TextField("Describe the delivery in your own words", text: $customText)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: LayoutConstants.cardBorderWidth)
                    )
                    .accessibilityIdentifier("\(accessibilityPrefix)_toneField")
                    .onChange(of: customText) { _, newValue in
                        emotion = newValue
                    }
            }
        }
        .onAppear {
            syncSelectionFromText()
        }
    }

    private func toneOptionButton(
        label: String,
        icon: String,
        isSelected: Bool,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? accentColor : .secondary)
                    .frame(width: 18)

                Text(label)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accentColor)
                }
            }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(isSelected ? accentColor.opacity(0.14) : Color.white.opacity(0.025))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isSelected ? accentColor.opacity(0.34) : Color.white.opacity(0.06), lineWidth: LayoutConstants.cardBorderWidth)
                    )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func selectPreset(_ preset: EmotionPreset) {
        AppLaunchConfiguration.performAnimated(.easeInOut(duration: 0.2)) {
            isCustomMode = false
            selectedPreset = preset
            isPickerExpanded = false
        }
        emotion = preset.instruction(for: intensity)
    }

    private func enterCustomMode() {
        AppLaunchConfiguration.performAnimated(.easeInOut(duration: 0.2)) {
            selectedPreset = nil
            isCustomMode = true
            isPickerExpanded = false
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

        if !emotion.isEmpty && emotion != "Normal tone" {
            isCustomMode = true
            customText = emotion
        } else {
            selectedPreset = EmotionPreset.all.first
            isCustomMode = false
        }
    }
}
