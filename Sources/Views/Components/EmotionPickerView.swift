import SwiftUI

struct EmotionPickerView: View {
    @Binding var emotion: String
    var deliveryProfile: Binding<DeliveryProfile?>? = nil
    var title: String = "Tone"
    var accentColor: Color = AppTheme.accent
    var accessibilityPrefix: String = "delivery"
    var showsLabel: Bool = true

    @State private var selectedPreset: EmotionPreset?
    @State private var intensity: EmotionIntensity = .normal
    @State private var isCustomMode = false
    @State private var customText = ""

    private var showsIntensityPicker: Bool {
        !isCustomMode && selectedPreset != nil && !isNeutralSelected
    }

    private var reservesIntensitySlot: Bool {
        true
    }

    private var isNeutralSelected: Bool {
        selectedPreset?.id == "neutral"
    }

    private var currentToneLabel: String {
        if isCustomMode {
            return "Custom"
        }

        guard let selectedPreset else {
            return "Normal tone"
        }

        return selectedPreset.id == "neutral" ? "Normal tone" : selectedPreset.label
    }

    private var selectedOptionID: Binding<String> {
        Binding(
            get: {
                if isCustomMode {
                    return "custom"
                }
                return selectedPreset?.id ?? "neutral"
            },
            set: { newValue in
                if newValue == "custom" {
                    enterCustomMode()
                } else if let preset = EmotionPreset.all.first(where: { $0.id == newValue }) {
                    selectPreset(preset)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsLabel {
                LabeledContent(title) {
                    toneControlRow
                }
            } else {
                toneControlRow
            }

            customToneField
        }
        .overlay(alignment: .topLeading) {
            emotionValueAnchor
        }
        .onAppear {
            syncSelectionFromText()
        }
    }

    private var tonePicker: some View {
        Picker(title, selection: selectedOptionID) {
            ForEach(EmotionPreset.all) { preset in
                Text(preset.id == "neutral" ? "Normal tone" : preset.label)
                    .tag(preset.id)
            }

            Text("Custom")
                .tag("custom")
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .transaction { $0.animation = nil }
        .frame(minWidth: LayoutConstants.configurationControlMinWidth, maxWidth: 240, alignment: .leading)
        .accessibilityIdentifier("\(accessibilityPrefix)_tonePicker")
    }

    private var toneControlRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                tonePicker

                if reservesIntensitySlot {
                    intensityInlineSlot
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                tonePicker

                if reservesIntensitySlot {
                    intensityInlineSlot
                }
            }
        }
    }

    private var intensityInlineSlot: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Intensity")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(showsIntensityPicker ? .secondary : .tertiary)

            intensityPicker
        }
    }

    private var intensityPicker: some View {
        Picker("Intensity", selection: $intensity) {
            ForEach(EmotionIntensity.allCases) { level in
                Text(level.label).tag(level)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .transaction { $0.animation = nil }
        .frame(minWidth: 112, maxWidth: 152, alignment: .leading)
        .tint(showsIntensityPicker ? AppTheme.emotionColor(for: selectedPreset?.id ?? "neutral") : .secondary)
        .opacity(showsIntensityPicker ? 1 : 0.6)
        .disabled(!showsIntensityPicker)
        .accessibilityIdentifier("\(accessibilityPrefix)_intensityPicker")
        .onChange(of: intensity) { _, _ in
            if let selectedPreset {
                applyCurrentSelection()
            }
        }
    }

    private var customToneField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Custom tone")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isCustomMode ? .secondary : .tertiary)

            TextField("Describe the delivery in your own words", text: $customText)
                .textFieldStyle(.roundedBorder)
                .focusEffectDisabled()
                .frame(minWidth: LayoutConstants.configurationControlMinWidth, maxWidth: .infinity, alignment: .leading)
                .opacity(isCustomMode ? 1 : 0.6)
                .disabled(!isCustomMode)
                .accessibilityIdentifier("\(accessibilityPrefix)_toneField")
                .onChange(of: customText) { _, newValue in
                    if isCustomMode {
                        applyCurrentSelection()
                    }
                }
        }
    }

    private func selectPreset(_ preset: EmotionPreset) {
        selectedPreset = preset
        isCustomMode = false
        customText = ""
        applyCurrentSelection()
    }

    private func enterCustomMode() {
        selectedPreset = nil
        isCustomMode = true
        applyCurrentSelection()
    }

    private func syncSelectionFromText() {
        for preset in EmotionPreset.all {
            for level in EmotionIntensity.allCases {
                if preset.instruction(for: level) == emotion {
                    selectedPreset = preset
                    intensity = level
                    isCustomMode = false
                    customText = ""
                    applyCurrentSelection()
                    return
                }
            }
        }

        if !emotion.isEmpty && emotion != "Normal tone" {
            isCustomMode = true
            customText = emotion
            selectedPreset = nil
            applyCurrentSelection()
        } else {
            selectedPreset = EmotionPreset.all.first
            isCustomMode = false
            customText = ""
            intensity = .normal
            applyCurrentSelection()
        }
    }

    private func applyCurrentSelection() {
        let profile: DeliveryProfile

        if isCustomMode {
            profile = .custom(customText)
        } else if let selectedPreset {
            profile = .preset(selectedPreset, intensity: intensity)
        } else {
            profile = .neutral
        }

        emotion = profile.finalInstruction
        deliveryProfile?.wrappedValue = profile
    }

    private var emotionValueAnchor: some View {
        Text(emotion.isEmpty ? " " : emotion)
            .font(.caption2)
            .foregroundStyle(.clear)
            .opacity(0.01)
            .frame(width: 1, height: 1, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityLabel(emotion)
            .accessibilityValue(emotion)
            .accessibilityIdentifier("\(accessibilityPrefix)_emotionValue")
    }
}
