import SwiftUI

/// Multi-line Voice Design brief editor — the macOS counterpart of the iOS
/// `IOSVoiceDesignBriefSheet`, inline instead of a sheet: a ~3–4 line
/// `TextEditor` with a live character counter (clamped to
/// `VoiceDesignBriefCatalog.descriptionLimit`) and, while the brief is empty,
/// one-click starting-point chips drawn from the shared catalog.
struct VoiceBriefEditor: View {
    @Binding var text: String
    var accentColor: Color = AppTheme.voiceDesign
    var accessibilityIdentifier: String = "voiceDesign_voiceDescriptionField"

    private var trimmedIsEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isAtLimit: Bool {
        text.count >= VoiceDesignBriefCatalog.descriptionLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.body)
                    .focusEffectDisabled()
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 72, maxHeight: 120)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .accessibilityIdentifier(accessibilityIdentifier)

                if trimmedIsEmpty {
                    Text(VoiceDesignBriefCatalog.placeholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 4)
            .glassTextField(radius: 10)
            .onChange(of: text) { _, newValue in
                // UX bound only — no model cap exists for the open-weights
                // VoiceDesign model (see VoiceDesignBriefCatalog).
                let limit = VoiceDesignBriefCatalog.descriptionLimit
                if newValue.count > limit {
                    text = String(newValue.prefix(limit))
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Combine character, age, accent, and texture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Text("\(text.count)/\(VoiceDesignBriefCatalog.descriptionLimit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isAtLimit ? accentColor : Color.secondary)
                    .accessibilityIdentifier("voiceDesign_briefCharCount")
            }

            if trimmedIsEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(VoiceDesignBriefCatalog.startingPoints.enumerated()), id: \.offset) { index, starter in
                        Button {
                            text = starter
                        } label: {
                            Text(starterChipLabel(for: starter))
                                .font(.caption)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .tint(accentColor)
                        .controlSize(.small)
                        .help(starter)
                        .accessibilityLabel("Starting point: \(starter)")
                        .accessibilityIdentifier("voiceDesign_briefStarter_\(index)")
                    }
                }
                .transition(.opacity)
            }
        }
        .appAnimation(.easeInOut(duration: 0.15), value: trimmedIsEmpty)
    }

    /// Chips show a compact head of each starter; the full sentence lives in
    /// the tooltip (`.help`) and fills on click.
    private func starterChipLabel(for starter: String) -> String {
        let words = starter.split(separator: " ").prefix(5)
        return words.joined(separator: " ") + "…"
    }
}
