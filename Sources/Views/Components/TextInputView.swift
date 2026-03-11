import SwiftUI

struct TextInputView: View {
    @Binding var text: String
    var isGenerating: Bool
    var placeholder: String = "What should I say?"
    var buttonColor: Color = AppTheme.customVoice
    var batchAction: (() -> Void)? = nil
    var batchDisabled: Bool = true
    var onGenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(.secondary.opacity(0.75)), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 19, weight: .medium))
                .lineLimit(7 ... 15)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, minHeight: 216, alignment: .topLeading)
                .accessibilityIdentifier("textInput_textEditor")

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Text("\(text.count) characters")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(text.count > 500 ? .orange : .secondary)
                    .accessibilityIdentifier("textInput_charCount")

                Spacer()

                if let batchAction {
                    Button {
                        batchAction()
                    } label: {
                        Label("Batch", systemImage: "square.grid.2x2.fill")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: LayoutConstants.cardBorderWidth)
                    )
                    .foregroundStyle(.primary)
                    .disabled(batchDisabled)
                    .accessibilityIdentifier("textInput_batchButton")
                }

                Text("\u{2318}\u{21A9}")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)

                Button(action: onGenerate) {
                    Group {
                        if isGenerating {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Label("Generate", systemImage: "sparkles")
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .frame(minWidth: 116)
                }
                .buttonStyle(GlowingGradientButtonStyle(baseColor: buttonColor))
                .disabled(text.isEmpty || isGenerating)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("textInput_generateButton")
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, minHeight: 292, alignment: .topLeading)
        .stageCard()
    }
}
