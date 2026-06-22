import QwenVoiceCore
import SwiftUI

struct EmotionPickerView: View {
    @Binding var emotion: String
    var deliveryProfile: Binding<DeliveryProfile?>? = nil
    var title: String = "Tone"
    var accentColor: Color = AppTheme.accent
    var accessibilityPrefix: String = "delivery"
    var showsLabel: Bool = true
    /// Column layout for the merged configuration line: the tone picker gets a
    /// caption label above it (`ConfigurationColumn`), and `leadingColumns`
    /// (e.g. the Language column) joins the same row.
    var usesColumnLabels: Bool = false
    var leadingColumns: AnyView? = nil

    @State private var selectedPreset: EmotionPreset?
    @State private var isCustomMode = false
    @State private var customText = ""

    private var currentToneLabel: String {
        if isCustomMode {
            return "Custom"
        }

        guard let selectedPreset else {
            return DeliveryProfile.neutralInstruction
        }

        return selectedPreset.label
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
            tonePickerOptions
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .focusEffectDisabled()
        .frame(
            minWidth: usesColumnLabels ? 110 : LayoutConstants.configurationControlMinWidth,
            maxWidth: 240,
            alignment: .leading
        )
        .accessibilityIdentifier("\(accessibilityPrefix)_tonePicker")
    }

    @ViewBuilder
    private var tonePickerOptions: some View {
        if let neutralPreset = EmotionPreset.preset(id: "neutral") {
            Text(neutralPreset.label)
                .tag(neutralPreset.id)
        }

        let nonNeutralCategories = DeliveryPresetCategory.allCases.filter { $0 != .neutral }
        ForEach(nonNeutralCategories, id: \.self) { category in
            Section(category.displayName ?? "") {
                let presets = EmotionPreset.all.filter { $0.category == category }
                ForEach(presets) { preset in
                    Text(preset.label)
                        .tag(preset.id)
                }
            }
        }

        Text("Custom")
            .tag("custom")
    }

    @ViewBuilder
    private var toneControlRow: some View {
        if usesColumnLabels {
            columnToneRow
        } else {
            inlineToneRow
        }
    }

    private var inlineToneRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                tonePicker
            }

            VStack(alignment: .leading, spacing: 8) {
                tonePicker
            }
        }
    }

    /// Merged configuration line: leading columns (e.g. Language) + Delivery
    /// share one row, each with a caption label above its control. The stacked
    /// variant is a safety net for extreme cases (large accessibility type) —
    /// the single line fits at every legal window/sidebar combination.
    private var columnToneRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                deliveryColumns
            }

            VStack(alignment: .leading, spacing: 8) {
                if let leadingColumns {
                    leadingColumns
                }

                HStack(alignment: .top, spacing: 12) {
                    ConfigurationColumn(label: "Delivery") { tonePicker }
                }
            }
        }
    }

    @ViewBuilder
    private var deliveryColumns: some View {
        if let leadingColumns {
            leadingColumns
        }

        ConfigurationColumn(label: "Delivery") { tonePicker }
    }

    private let customToneCharacterLimit = 500

    private var customToneField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Custom tone")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isCustomMode ? .secondary : .tertiary)

            TextField("e.g. whispered, close-mic and breathy", text: $customText)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(minWidth: LayoutConstants.configurationControlMinWidth, maxWidth: .infinity, alignment: .leading)
                .glassTextField(radius: 8)
                .opacity(isCustomMode ? 1 : 0.6)
                .disabled(!isCustomMode)
                .accessibilityIdentifier("\(accessibilityPrefix)_toneField")
                .onChange(of: customText) { _, newValue in
                    if newValue.count > customToneCharacterLimit {
                        customText = String(newValue.prefix(customToneCharacterLimit))
                    }
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
        let trimmedEmotion = emotion.trimmingCharacters(in: .whitespacesAndNewlines)

        for preset in EmotionPreset.all {
            if preset.instruction.caseInsensitiveCompare(trimmedEmotion) == .orderedSame {
                selectedPreset = preset
                isCustomMode = false
                customText = ""
                applyCurrentSelection()
                return
            }
        }

        if !DeliveryProfile.isNeutralInstruction(trimmedEmotion) {
            isCustomMode = true
            customText = trimmedEmotion
            selectedPreset = nil
            applyCurrentSelection()
        } else {
            selectedPreset = EmotionPreset.all.first
            isCustomMode = false
            customText = ""
            applyCurrentSelection()
        }
    }

    private func applyCurrentSelection() {
        let profile: DeliveryProfile

        if isCustomMode {
            profile = .custom(customText)
        } else if let selectedPreset {
            profile = .preset(selectedPreset)
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
