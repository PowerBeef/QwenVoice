import SwiftUI

struct TextInputView: View {
    @Binding var text: String

    var isGenerating: Bool
    var placeholder: String = "What should I say?"
    var buttonColor: Color = AppTheme.customVoice
    var batchAction: (() -> Void)? = nil
    var batchDisabled: Bool = true
    var generateDisabled: Bool = false
    var isEmbedded: Bool = false
    var usesFlexibleEmbeddedHeight: Bool = false
    var onGenerate: () -> Void

    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: isEmbedded ? LayoutConstants.composerEmbeddedSpacing : 12) {
            editor
            actionRow
        }
        .frame(maxHeight: usesFlexibleEmbeddedHeight ? .infinity : nil, alignment: .topLeading)
        .background(shortcutBridge)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($isEditorFocused)
                .padding(isEmbedded ? LayoutConstants.composerEmbeddedEditorInset : 8)
                .frame(
                    maxWidth: .infinity,
                    minHeight: isEmbedded ? LayoutConstants.composerEmbeddedMinHeight : 160,
                    maxHeight: usesFlexibleEmbeddedHeight && isEmbedded ? .infinity : LayoutConstants.textEditorMaxHeight,
                    alignment: .topLeading
                )
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isEditorFocused ? buttonColor.opacity(0.45) : AppTheme.cardStroke.opacity(0.45), lineWidth: 1)
                )
                .accessibilityIdentifier("textInput_textEditor")

            if text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, isEmbedded ? LayoutConstants.composerEmbeddedPlaceholderHorizontalPadding : 14)
                    .padding(.vertical, isEmbedded ? LayoutConstants.composerEmbeddedPlaceholderVerticalPadding : 16)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxHeight: usesFlexibleEmbeddedHeight ? .infinity : nil, alignment: .topLeading)
    }

    private var actionRow: some View {
        HStack(alignment: .center, spacing: isEmbedded ? 10 : 12) {
            ControlGroup {
                if let batchAction {
                    Button("Batch") {
                        batchAction()
                    }
                    .buttonStyle(.bordered)
                    .disabled(batchDisabled)
                    .accessibilityIdentifier("textInput_batchButton")
                }

                Button {
                    onGenerate()
                } label: {
                    if isGenerating {
                        ProgressView()
                            .controlSize(.small)
                            .frame(minWidth: 88)
                    } else {
                        Label("Generate", systemImage: "sparkles")
                            .frame(minWidth: 88)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(buttonColor)
                .disabled(text.isEmpty || isGenerating || generateDisabled)
                .accessibilityIdentifier("textInput_generateButton")
            }

            Spacer(minLength: 0)

            Text("\(text.count) characters")
                .font(.callout)
                .foregroundStyle(text.count > 500 ? .orange : .secondary)
                .accessibilityIdentifier("textInput_charCount")
        }
    }

    private var shortcutBridge: some View {
        Button("", action: onGenerate)
            .keyboardShortcut(.return, modifiers: .command)
            .opacity(0.001)
            .disabled(text.isEmpty || isGenerating || generateDisabled)
            .accessibilityHidden(true)
    }
}
