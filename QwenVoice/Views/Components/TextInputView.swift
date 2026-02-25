import SwiftUI

/// Shared text entry area with generate button, used across all generate views.
struct TextInputView: View {
    @Binding var text: String
    var isGenerating: Bool
    var placeholder: String = "Enter text to synthesize..."
    var buttonColor: Color = AppTheme.customVoice
    var onGenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PROMPT").sectionHeader(color: buttonColor)

            ZStack(alignment: .bottomTrailing) {
                TextEditor(text: $text)
                    .font(.title3)
                    .frame(minHeight: 120, maxHeight: LayoutConstants.textEditorMaxHeight)
                    .padding(12)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .accessibilityIdentifier("textInput_textEditor")

                if text.isEmpty {
                    Text(placeholder)
                        .font(.title3)
                        .foregroundColor(.secondary.opacity(0.5))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 20)
                        .allowsHitTesting(false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                Button(action: onGenerate) {
                    HStack(spacing: 8) {
                        if isGenerating {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(isGenerating ? "Generating..." : "Generate")
                    }
                }
                .buttonStyle(GlowingGradientButtonStyle(baseColor: buttonColor))
                .disabled(text.isEmpty || isGenerating)
                .padding(12)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("textInput_generateButton")
            }
            .glassCard()

            HStack {
                Spacer()
                Text("\(text.count) characters")
                    .font(.caption.weight(.medium))
                    .foregroundColor(text.count > 500 ? .orange : .secondary.opacity(0.6))
                    .accessibilityIdentifier("textInput_charCount")
            }
        }
    }
}
