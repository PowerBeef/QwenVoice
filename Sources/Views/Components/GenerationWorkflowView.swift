import SwiftUI

private extension View {
    @ViewBuilder
    func optionalAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

enum CustomVoiceWorkflowMode: String, CaseIterable, Identifiable {
    case presetSpeaker
    case voiceDesign

    var id: String { rawValue }

    var title: String {
        switch self {
        case .presetSpeaker: return "Preset Speaker"
        case .voiceDesign: return "Voice Design"
        }
    }

    var generationMode: GenerationMode {
        switch self {
        case .presetSpeaker: return .custom
        case .voiceDesign: return .design
        }
    }
}

struct GenerationHeaderView<Accessory: View>: View {
    let title: String
    let subtitle: String
    var titleAccessibilityIdentifier: String? = nil
    var subtitleAccessibilityIdentifier: String? = nil
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                titleBlock
                    .frame(maxWidth: 360, alignment: .leading)
                Spacer(minLength: 12)
                accessory()
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                accessory()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.9)
                .optionalAccessibilityIdentifier(titleAccessibilityIdentifier)

            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .optionalAccessibilityIdentifier(subtitleAccessibilityIdentifier)
        }
    }
}

extension GenerationHeaderView where Accessory == EmptyView {
    init(title: String, subtitle: String, titleAccessibilityIdentifier: String? = nil, subtitleAccessibilityIdentifier: String? = nil) {
        self.init(title: title, subtitle: subtitle, titleAccessibilityIdentifier: titleAccessibilityIdentifier, subtitleAccessibilityIdentifier: subtitleAccessibilityIdentifier) {
            EmptyView()
        }
    }
}

struct GenerationModeSwitch: View {
    @Binding var selection: CustomVoiceWorkflowMode

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CustomVoiceWorkflowMode.allCases) { mode in
                Button(action: { select(mode) }) {
                    segmentLabel(for: mode)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("customVoice_mode_\(mode == .presetSpeaker ? "preset" : "design")")
                .accessibilityValue(selection == mode ? "selected" : "not selected")
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("customVoice_modeSwitch")
    }

    private func select(_ mode: CustomVoiceWorkflowMode) {
        AppLaunchConfiguration.performAnimated(.spring(response: 0.24, dampingFraction: 0.82)) {
            selection = mode
        }
    }

    @ViewBuilder
    private func segmentLabel(for mode: CustomVoiceWorkflowMode) -> some View {
        let isSelected = selection == mode

        Text(mode.title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isSelected ? AppTheme.accent : .secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.92)
            .frame(minWidth: 112)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? AppTheme.accent.opacity(0.18) : Color.clear)
            )
    }
}

struct StudioSectionCard<Content: View>: View {
    let title: String
    var iconName: String? = nil
    var accentColor: Color = AppTheme.accent
    var trailingText: String? = nil
    var minHeight: CGFloat? = nil
    var contentAlignment: HorizontalAlignment = .leading
    var accessibilityIdentifier: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: contentAlignment, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                if let iconName {
                    Image(systemName: iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accentColor)
                }

                Text(title)
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if let trailingText {
                    Text(trailingText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accentColor)
                }
            }

            content()
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .studioCard()
        .accessibilityElement(children: .contain)
        .optionalAccessibilityIdentifier(accessibilityIdentifier)
    }
}

struct SpeedControlView: View {
    @Binding var speed: Double
    var color: Color = AppTheme.accent

    private var clampedSpeed: Double {
        min(max(speed, 0.5), 2.0)
    }

    private var displayValue: String {
        String(format: "%.1fx", clampedSpeed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Slider(value: $speed, in: 0.5 ... 2.0, step: 0.05)
                .tint(color)
                .accessibilityIdentifier("delivery_speedSlider")

            HStack {
                Text("0.5")
                Spacer()
                Text("2.0")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("delivery_speedPicker")
        .accessibilityValue(displayValue)
    }
}

struct DeliveryControlsView: View {
    @Binding var emotion: String
    @Binding var speed: Double
    var accentColor: Color = AppTheme.accent
    var accessibilityPrefix: String = "delivery"

    private var speedValueText: String {
        String(format: "%.1fx", min(max(speed, 0.5), 2.0))
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: LayoutConstants.compactGap) {
                toneCard
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)

                speedCard
                    .frame(width: 236)
            }

            VStack(alignment: .leading, spacing: LayoutConstants.compactGap) {
                toneCard
                speedCard
            }
        }
    }

    private var toneCard: some View {
        StudioSectionCard(
            title: "Tone",
            iconName: "face.smiling.fill",
            accentColor: accentColor,
            accessibilityIdentifier: "\(accessibilityPrefix)_toneCard"
        ) {
            EmotionPickerView(
                emotion: $emotion,
                title: "Tone",
                accentColor: accentColor,
                accessibilityPrefix: accessibilityPrefix
            )
        }
    }

    private var speedCard: some View {
        StudioSectionCard(
            title: "Speed",
            iconName: "scribble.variable",
            accentColor: accentColor,
            trailingText: speedValueText,
            accessibilityIdentifier: "\(accessibilityPrefix)_speedCard"
        ) {
            SpeedControlView(speed: $speed, color: accentColor)
        }
    }
}
