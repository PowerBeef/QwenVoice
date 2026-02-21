import SwiftUI

/// Shared text entry area with generate button, used across all generate views.
struct TextInputView: View {
    @Binding var text: String
    var isGenerating: Bool
    var placeholder: String = "Enter text to synthesize..."
    var onGenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text").font(.headline)

            ZStack(alignment: .bottomTrailing) {
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 100, maxHeight: 200)
                    .padding(4)
                    .accessibilityIdentifier("textInput_textEditor")
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(placeholder)
                                .foregroundColor(.gray.opacity(0.5))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }

                Button(action: onGenerate) {
                    HStack(spacing: 6) {
                        if isGenerating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(isGenerating ? "Generating..." : "Generate")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.isEmpty || isGenerating)
                .padding(8)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("textInput_generateButton")
            }

            Text("\(text.count) characters")
                .font(.caption2)
                .foregroundColor(.secondary)
                .accessibilityIdentifier("textInput_charCount")
        }
    }
}
