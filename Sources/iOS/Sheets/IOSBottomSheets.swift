import SwiftUI
import QwenVoiceCore

// Bottom-sheet bundle from design_references/Vocello iOS/sheets.jsx. Each
// sheet wraps `IOSBottomSheet` (the shared chrome) and presents a focused
// picker / confirmation surface. Sheets are independent — call sites
// present them via `.sheet(isPresented:)` and bind the relevant state.

// MARK: - Delivery picker

/// 9-cell preset grid + intensity row. Drives a `DeliveryInputState`-shaped
/// binding (selected preset id + intensity).
struct IOSDeliveryPickerSheet: View {
    @Binding var selectedPresetID: String
    @Binding var intensity: EmotionIntensity
    let tint: Color
    /// Optional escape hatch: when set, a small "Use custom tone…" link sits
    /// below the intensity row. Tapping it dismisses the sheet and calls the
    /// closure (callers typically switch their `delivery.mode` to `.custom`
    /// so the inline custom-text editor activates).
    var onUseCustomTone: (() -> Void)?
    var onDismiss: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    }

    private var canChooseIntensity: Bool {
        selectedPresetID != "neutral"
    }

    var body: some View {
        IOSBottomSheet(title: "Delivery", tint: tint, onDismiss: onDismiss) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(EmotionPreset.all) { preset in
                            cell(for: preset)
                        }
                    }

                    if canChooseIntensity {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Intensity")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(IOSAppTheme.textPrimary)
                            HStack(spacing: 8) {
                                ForEach(EmotionIntensity.allCases) { level in
                                    intensityButton(level)
                                }
                            }
                        }
                    }

                    if let onUseCustomTone {
                        Button {
                            onUseCustomTone()
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Use a custom tone instead")
                                    .font(.subheadline.weight(.medium))
                            }
                            .foregroundStyle(tint)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background {
                                Capsule(style: .continuous)
                                    .fill(IOSAppTheme.accentWash(tint).opacity(0.6))
                            }
                            .overlay {
                                Capsule(style: .continuous)
                                    .stroke(tint.opacity(0.30), lineWidth: 0.9)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("deliveryPickerSheet_customTone")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }

    private func cell(for preset: EmotionPreset) -> some View {
        let isSelected = preset.id == selectedPresetID
        return Button {
            selectedPresetID = preset.id
            IOSHaptics.selection()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: preset.sfSymbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? tint : IOSAppTheme.textSecondary)
                Text(preset.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 80)
            .background {
                RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                    .fill(isSelected ? IOSAppTheme.accentWash(tint) : IOSAppTheme.glassSurfaceFillMuted.opacity(0.55))
            }
            .overlay {
                RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                    .stroke(isSelected ? tint.opacity(0.34) : Color.white.opacity(0.08), lineWidth: 0.9)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func intensityButton(_ level: EmotionIntensity) -> some View {
        let isSelected = level == intensity
        return Button {
            intensity = level
            IOSHaptics.selection()
        } label: {
            Text(level.label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isSelected ? IOSAppTheme.textPrimary : IOSAppTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background {
                    Capsule(style: .continuous)
                        .fill(isSelected ? IOSAppTheme.accentWash(tint) : IOSAppTheme.glassSurfaceFillMuted.opacity(0.55))
                }
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(isSelected ? tint.opacity(0.32) : Color.white.opacity(0.10), lineWidth: 0.8)
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Voice picker

/// Speaker picker for Custom mode. Caller passes the available speaker
/// catalog (id + display name + optional language tag) and a selection
/// binding. Optional recent-voices carousel sits above the alphabetical
/// list.
struct IOSVoicePickerSheet: View {
    let speakers: [IOSVoicePickerOption]
    let recents: [IOSVoicePickerOption]
    @Binding var selectedID: String
    let tint: Color
    var onDismiss: (() -> Void)?

    @State private var search: String = ""

    private var filtered: [IOSVoicePickerOption] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return speakers }
        return speakers.filter { option in
            option.name.lowercased().contains(q)
                || (option.subtitle ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        IOSBottomSheet(title: "Voice", tint: tint, onDismiss: onDismiss) {
            VStack(alignment: .leading, spacing: 14) {
                IOSSearchField(text: $search, placeholder: "Search voices")
                    .padding(.horizontal, 20)

                if !recents.isEmpty && search.isEmpty {
                    recentsCarousel
                }

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(filtered) { option in
                            row(for: option)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private var recentsCarousel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(IOSAppTheme.textTertiary)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(recents) { option in
                        Button {
                            selectedID = option.id
                            IOSHaptics.selection()
                        } label: {
                            VStack(spacing: 6) {
                                IOSVoiceAvatar(seed: option.id, initials: option.initials, diameter: 48)
                                Text(option.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(IOSAppTheme.textSecondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 72)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func row(for option: IOSVoicePickerOption) -> some View {
        let isSelected = option.id == selectedID
        return Button {
            selectedID = option.id
            IOSHaptics.selection()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                IOSVoiceAvatar(seed: option.id, initials: option.initials, diameter: 40)

                VStack(alignment: .leading, spacing: 1) {
                    Text(option.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IOSAppTheme.textPrimary)
                    if let subtitle = option.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(IOSAppTheme.textSecondary)
                    }
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                    .fill(isSelected ? IOSAppTheme.accentWash(tint) : Color.clear)
            }
        }
        .buttonStyle(.plain)
    }
}

struct IOSVoicePickerOption: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String?

    var initials: String {
        let words = name.split(separator: " ")
        if words.count >= 2 {
            return "\(words[0].prefix(1))\(words[1].prefix(1))"
        }
        return String(name.prefix(2))
    }
}

// MARK: - Reference clip picker

/// Three sources for a clone reference clip: saved voices, an imported
/// clip from Files, or a freshly recorded clip via IOSRecordingOverlay.
struct IOSReferenceClipSheet: View {
    let savedVoices: [IOSVoicePickerOption]
    @Binding var selectedSavedVoiceID: String?
    var onImportFromFiles: () -> Void
    var onRecorded: (URL) -> Void
    var onDismiss: (() -> Void)?

    @State private var isPresentingRecorder: Bool = false

    var body: some View {
        IOSBottomSheet(title: "Reference clip", tint: IOSBrandTheme.clone, onDismiss: onDismiss) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    sourcePicker

                    if !savedVoices.isEmpty {
                        Text("Saved voices")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.7)
                            .foregroundStyle(IOSAppTheme.textTertiary)
                            .padding(.top, 6)

                        ForEach(savedVoices) { option in
                            row(for: option)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .fullScreenCover(isPresented: $isPresentingRecorder) {
            IOSRecordingOverlay(
                onComplete: { url in
                    isPresentingRecorder = false
                    onRecorded(url)
                },
                onCancel: {
                    isPresentingRecorder = false
                }
            )
        }
    }

    private var sourcePicker: some View {
        VStack(spacing: 10) {
            sourceRow(
                symbol: "mic.fill",
                title: "Record new clip",
                detail: "Capture a 10-20 second sample on this iPhone.",
                action: { isPresentingRecorder = true }
            )
            sourceRow(
                symbol: "doc.fill",
                title: "Import from Files",
                detail: "Pick a WAV, M4A, or MP3 file you own.",
                action: onImportFromFiles
            )
        }
    }

    private func sourceRow(
        symbol: String,
        title: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(IOSBrandTheme.clone.opacity(0.2))
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(IOSBrandTheme.clone)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IOSAppTheme.textPrimary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(IOSAppTheme.textSecondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                    .fill(IOSAppTheme.glassSurfaceFillMuted.opacity(0.6))
            }
            .overlay {
                RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    private func row(for option: IOSVoicePickerOption) -> some View {
        let isSelected = option.id == selectedSavedVoiceID
        return Button {
            selectedSavedVoiceID = option.id
            IOSHaptics.selection()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                IOSVoiceAvatar(seed: option.id, initials: option.initials, diameter: 36)

                VStack(alignment: .leading, spacing: 1) {
                    Text(option.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IOSAppTheme.textPrimary)
                    if let subtitle = option.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(IOSAppTheme.textSecondary)
                    }
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(IOSBrandTheme.clone)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                    .fill(isSelected ? IOSAppTheme.accentWash(IOSBrandTheme.clone) : Color.clear)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Model install sheet

/// Per-model download UI used from Settings + Studio "no model installed"
/// state. Caller hands in a `IOSModelInstallSheetItem` describing the
/// model + a progress value + an install action. Wiring through
/// `IOSModelInstallerViewModel` happens at the call site.
struct IOSModelInstallSheet: View {
    let item: IOSModelInstallSheetItem
    @Binding var isInstalling: Bool
    @Binding var progress: Double
    var onInstall: () -> Void
    var onCancel: () -> Void
    var onDismiss: (() -> Void)?

    var body: some View {
        IOSBottomSheet(title: "Install model", tint: item.tint, onDismiss: onDismiss) {
            VStack(alignment: .leading, spacing: 20) {
                header
                description
                progressView
                Spacer(minLength: 0)
                cta
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(item.tint.opacity(0.2))
                Image(systemName: item.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(item.tint)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                Text(item.sizeLabel)
                    .font(.subheadline)
                    .foregroundStyle(IOSAppTheme.textSecondary)
            }
            Spacer()
        }
    }

    private var description: some View {
        Text(item.description)
            .font(.subheadline)
            .foregroundStyle(IOSAppTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var progressView: some View {
        if isInstalling {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(item.tint)
                Text("Downloading \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(IOSAppTheme.textSecondary)
            }
        }
    }

    private var cta: some View {
        Group {
            if isInstalling {
                Button("Cancel") { onCancel() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IOSAppTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background {
                        Capsule(style: .continuous)
                            .fill(IOSAppTheme.glassSurfaceFillMuted)
                    }
                    .buttonStyle(.plain)
            } else {
                IOSPrimaryCTAButton(
                    title: "Install",
                    symbol: "arrow.down.circle.fill",
                    tint: item.tint,
                    isEnabled: true,
                    action: onInstall
                )
            }
        }
    }
}

struct IOSModelInstallSheetItem: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String
    let sizeLabel: String
    let description: String
    let tint: Color

    static func == (lhs: IOSModelInstallSheetItem, rhs: IOSModelInstallSheetItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Delete model sheet

/// Destructive-confirmation sheet for removing an installed model. Two
/// stacked buttons; the destructive button takes the orange "Heavy"
/// status color per the design system.
struct IOSDeleteModelSheet: View {
    let modelName: String
    let sizeLabel: String
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        IOSBottomSheet(title: "Delete model?", tint: IOSBrandTheme.memoryGuarded, onDismiss: onCancel) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Deleting \(modelName) frees \(sizeLabel). You can re-install it from Settings whenever you want.")
                    .font(.subheadline)
                    .foregroundStyle(IOSAppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    Button {
                        IOSHaptics.warning()
                        onConfirm()
                    } label: {
                        Text("Delete \(modelName)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background {
                                Capsule(style: .continuous)
                                    .fill(Color.red.opacity(0.88))
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("deleteModelSheet_confirm")

                    Button("Keep model") { onCancel() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IOSAppTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background {
                            Capsule(style: .continuous)
                                .fill(IOSAppTheme.glassSurfaceFillMuted)
                        }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }
}
