import SwiftUI

/// Shared text entry area with generate button, used across all generate views.
struct TextInputView: View {
    @Binding var text: String
    var isGenerating: Bool
    var placeholder: String = "Enter text to synthesize..."
    var buttonColor: Color = AppTheme.customVoice
    var onGenerate: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(alignment: .bottom, spacing: 12) {
                // Recessed text field
                TextField("", text: $text, prompt: Text(placeholder)
                    .foregroundColor(.secondary.opacity(0.5)), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(2...8)
                    .padding(12)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .accessibilityIdentifier("textInput_textEditor")

                // Circular generate button
                Button(action: onGenerate) {
                    Group {
                        if isGenerating {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "sparkles")
                        }
                    }
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(CompactGenerateButtonStyle(baseColor: buttonColor))
                .disabled(text.isEmpty || isGenerating)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("textInput_generateButton")
            }

            // Character count
            Text("\(text.count) characters")
                .font(.caption.weight(.medium))
                .foregroundColor(text.count > 500 ? .orange : .secondary.opacity(0.6))
                .accessibilityIdentifier("textInput_charCount")
        }
    }
}
