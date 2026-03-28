import AppKit
import SwiftUI

@MainActor
enum ReadmeScreenshotRenderer {
    static let canvasSize = CGSize(width: 1280, height: 820)

    static func shouldRender(name: String) -> Bool {
        name.hasPrefix("readme_")
    }

    static func render(name: String, snapshot: [String: Any], to destinationURL: URL) -> Bool {
        guard let scenario = ReadmeScreenshotScenario(name: name, snapshot: snapshot) else {
            return false
        }

        let content = ReadmeScreenshotRoot(scenario: scenario)
            .frame(width: canvasSize.width, height: canvasSize.height)
            .preferredColorScheme(.dark)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }

        do {
            try pngData.write(to: destinationURL)
            return true
        } catch {
            return false
        }
    }
}

private struct ReadmeScreenshotScenario {
    struct ToneSummary {
        let presetLabel: String?
        let intensityLabel: String?
        let customText: String?
    }

    let name: String
    let selectedItem: SidebarItem
    let accentColor: Color
    let configurationTitle: String
    let configurationDetail: String
    let scriptPlaceholder: String
    let scriptText: String
    let readinessDetail: String
    let speakerName: String?
    let voiceDescription: String?
    let referenceClipName: String?
    let referenceTranscript: String?
    let toneSummary: ToneSummary?

    init?(name: String, snapshot: [String: Any]) {
        let scriptText = (snapshot["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch name {
        case "readme_custom_voice":
            let rawSpeaker = (snapshot["selectedSpeaker"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let emotion = (snapshot["emotion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.name = name
            selectedItem = .customVoice
            accentColor = AppTheme.customVoice
            configurationTitle = "Configuration"
            configurationDetail = "Pick a built-in speaker, then shape the delivery before you generate."
            scriptPlaceholder = "What should I say?"
            self.scriptText = scriptText
            readinessDetail = "Everything is in place for a live preview and a saved generation."
            speakerName = Self.humanizedSpeakerName(rawSpeaker)
            voiceDescription = nil
            referenceClipName = nil
            referenceTranscript = nil
            toneSummary = Self.toneSummary(for: emotion)
        case "readme_voice_design":
            let voiceDescription = (snapshot["voiceDescription"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let emotion = (snapshot["emotion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.name = name
            selectedItem = .voiceDesign
            accentColor = AppTheme.voiceDesign
            configurationTitle = "Configuration"
            configurationDetail = "Describe the voice, set the delivery, then keep the script front and center."
            scriptPlaceholder = "What should I say?"
            self.scriptText = scriptText
            readinessDetail = "Everything is in place for a designed voice, a live preview, and a saved generation."
            speakerName = nil
            self.voiceDescription = voiceDescription
            referenceClipName = nil
            referenceTranscript = nil
            toneSummary = Self.toneSummary(for: emotion)
        case "readme_voice_cloning":
            let referenceAudioPath = (snapshot["referenceAudioPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let transcript = (snapshot["referenceTranscript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.name = name
            selectedItem = .voiceCloning
            accentColor = AppTheme.voiceCloning
            configurationTitle = "Configuration"
            configurationDetail = "Choose a saved voice or import a reference clip, then add an optional transcript."
            scriptPlaceholder = "What should the cloned voice say?"
            self.scriptText = scriptText
            readinessDetail = "Everything is in place for a live preview and a saved clone."
            speakerName = nil
            voiceDescription = nil
            referenceClipName = Self.referenceClipName(for: referenceAudioPath)
            referenceTranscript = transcript
            toneSummary = nil
        default:
            return nil
        }
    }

    private static func humanizedSpeakerName(_ rawSpeaker: String?) -> String? {
        guard let rawSpeaker, !rawSpeaker.isEmpty else { return nil }
        return rawSpeaker
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private static func referenceClipName(for path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func toneSummary(for emotion: String?) -> ToneSummary? {
        guard let emotion, !emotion.isEmpty else { return nil }

        for preset in EmotionPreset.all {
            for intensity in EmotionIntensity.allCases {
                if preset.instruction(for: intensity) == emotion {
                    return ToneSummary(
                        presetLabel: preset.id == "neutral" ? "Normal tone" : preset.label,
                        intensityLabel: preset.id == "neutral" ? nil : intensity.label,
                        customText: nil
                    )
                }
            }
        }

        if emotion.caseInsensitiveCompare("Normal tone") == .orderedSame {
            return ToneSummary(presetLabel: "Normal tone", intensityLabel: nil, customText: nil)
        }

        return ToneSummary(presetLabel: nil, intensityLabel: nil, customText: emotion)
    }
}

private struct ReadmeScreenshotRoot: View {
    let scenario: ReadmeScreenshotScenario

    var body: some View {
        ZStack {
            AuroraBackground()

            HStack(spacing: 0) {
                ReadmeSidebar(selectedItem: scenario.selectedItem)
                    .frame(width: 276)

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)

                ReadmeDetailArea(scenario: scenario)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(18)
        }
    }
}

private struct ReadmeSidebar: View {
    let selectedItem: SidebarItem

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("QwenVoice")
                    .font(.title3.weight(.semibold))
                Text("Offline Qwen3-TTS for macOS")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            ForEach(SidebarItem.Section.allCases, id: \.self) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.rawValue.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)

                    ForEach(section.items) { item in
                        ReadmeSidebarRow(item: item, isSelected: item == selectedItem)
                    }
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("Ready")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Bundled runtime active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(red: 0.12, green: 0.13, blue: 0.15))
        )
    }
}

private struct ReadmeSidebarRow: View {
    let item: SidebarItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(isSelected ? AppTheme.sidebarColor(for: item) : .clear)
                .frame(width: 3, height: 18)

            Image(systemName: item.iconName)
                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                .frame(width: 22, alignment: .center)

            Text(item.rawValue)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))

            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? AppTheme.sidebarColor(for: item) : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.06) : .clear)
        )
        .padding(.horizontal, 8)
    }
}

private struct ReadmeDetailArea: View {
    let scenario: ReadmeScreenshotScenario

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            configurationPanel
            scriptPanel
                .layoutPriority(1)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(red: 0.09, green: 0.10, blue: 0.12))
        )
    }

    private var configurationPanel: some View {
        ReadmePanel(
            title: scenario.configurationTitle,
            detail: scenario.configurationDetail,
            iconName: "slider.horizontal.3",
            accentColor: scenario.accentColor
        ) {
            VStack(alignment: .leading, spacing: 0) {
                switch scenario.selectedItem {
                case .customVoice:
                    ReadmeConfigurationRow(label: "Speaker") {
                        ReadmeValueField(
                            leadingSystemImage: "person.wave.2",
                            title: scenario.speakerName ?? "Serena"
                        )
                    }

                    Divider().overlay(Color.white.opacity(0.08))

                    ReadmeConfigurationRow(label: "Delivery") {
                        ReadmeToneSummaryView(summary: scenario.toneSummary)
                    }
                case .voiceDesign:
                    ReadmeConfigurationRow(label: "Voice brief") {
                        ReadmeValueField(
                            leadingSystemImage: "text.bubble",
                            title: scenario.voiceDescription ?? "Warm documentary narrator"
                        )
                    }

                    Divider().overlay(Color.white.opacity(0.08))

                    ReadmeConfigurationRow(label: "Delivery") {
                        ReadmeToneSummaryView(summary: scenario.toneSummary)
                    }
                case .voiceCloning:
                    ReadmeConfigurationRow(label: "Reference") {
                        ReadmeValueField(
                            leadingSystemImage: "waveform.badge.plus",
                            title: scenario.referenceClipName ?? "reference.wav",
                            subtitle: "Imported clip"
                        )
                    }

                    Divider().overlay(Color.white.opacity(0.08))

                    ReadmeConfigurationRow(label: "Transcript") {
                        ReadmeValueField(
                            leadingSystemImage: "quote.bubble",
                            title: scenario.referenceTranscript ?? "Optional transcript"
                        )
                    }
                case .history, .voices, .models:
                    EmptyView()
                }
            }
        }
    }

    private var scriptPanel: some View {
        ReadmePanel(
            title: "Script",
            iconName: "text.alignleft",
            accentColor: scenario.accentColor,
            trailingText: "Ready",
            fillsAvailableHeight: true
        ) {
            VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
                ReadmeScriptEditor(
                    placeholder: scenario.scriptPlaceholder,
                    text: scenario.scriptText,
                    accentColor: scenario.accentColor
                )

                ReadmeReadinessNote(
                    title: "Ready to generate",
                    detail: scenario.readinessDetail,
                    accentColor: scenario.accentColor
                )
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ReadmePanel<Content: View>: View {
    let title: String
    var detail: String? = nil
    var iconName: String? = nil
    var accentColor: Color = AppTheme.accent
    var trailingText: String? = nil
    var fillsAvailableHeight: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                if let iconName {
                    Image(systemName: iconName)
                        .foregroundStyle(accentColor)
                }

                Text(title)
                    .font(.headline.weight(.semibold))

                Spacer(minLength: 0)

                if let trailingText {
                    Text(trailingText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
                .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil, alignment: .topLeading)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.18, green: 0.19, blue: 0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct ReadmeConfigurationRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)

            content()
        }
        .padding(.vertical, 12)
    }
}

private struct ReadmeValueField: View {
    let leadingSystemImage: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: leadingSystemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.22, green: 0.23, blue: 0.26))
        )
    }
}

private struct ReadmeToneSummaryView: View {
    let summary: ReadmeScreenshotScenario.ToneSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let presetLabel = summary?.presetLabel {
                HStack(spacing: 8) {
                    ReadmeTonePill(text: presetLabel, isPrimary: true)

                    if let intensityLabel = summary?.intensityLabel {
                        ReadmeTonePill(text: intensityLabel, isPrimary: false)
                    }
                }
            }

            if let customText = summary?.customText {
                Text(customText)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReadmeTonePill: View {
    let text: String
    let isPrimary: Bool

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(isPrimary ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isPrimary ? Color.accentColor.opacity(0.75) : Color.white.opacity(0.06))
            )
    }
}

private struct ReadmeScriptEditor: View {
    let placeholder: String
    let text: String
    let accentColor: Color

    private var characterCountLabel: String {
        "\(text.count) characters"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.23, green: 0.24, blue: 0.27))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )

                Text(text.isEmpty ? placeholder : text)
                    .font(.body)
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .padding(22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)

            HStack(alignment: .center, spacing: 12) {
                Text(characterCountLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Text("Generate")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accentColor.opacity(0.92))
                    )
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ReadmeReadinessNote: View {
    let title: String
    let detail: String
    let accentColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }
}
