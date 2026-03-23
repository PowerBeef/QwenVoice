import SwiftUI
import AppKit

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

    @State private var isEditorFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: isEmbedded ? LayoutConstants.composerEmbeddedSpacing : 12) {
            editor
            actionRow
        }
        .frame(maxHeight: usesFlexibleEmbeddedHeight ? .infinity : nil, alignment: .topLeading)
        .background(shortcutBridge)
    }

    private var editor: some View {
        ScriptTextEditor(
            text: $text,
            placeholder: placeholder,
            font: .systemFont(ofSize: NSFont.systemFontSize),
            isFocused: $isEditorFocused
        )
        .padding(isEmbedded ? LayoutConstants.composerEmbeddedEditorInset : 8)
        .frame(
            maxWidth: .infinity,
            minHeight: isEmbedded ? LayoutConstants.composerEmbeddedMinHeight : 160,
            maxHeight: usesFlexibleEmbeddedHeight && isEmbedded ? .infinity : LayoutConstants.textEditorMaxHeight,
            alignment: .topLeading
        )
        #if QW_UI_LIQUID
        .background {
            if #available(macOS 26, *) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(white: 0.16))
                    .glassEffect(
                        .regular.tint(AppTheme.smokedGlassTint),
                        in: .rect(cornerRadius: 10)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isEditorFocused ? buttonColor.opacity(0.4) : .clear, lineWidth: 1)
                    )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isEditorFocused ? buttonColor.opacity(0.3) : AppTheme.cardStroke.opacity(0.15), lineWidth: 0.5)
                }
            }
        }
        #else
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isEditorFocused ? buttonColor.opacity(0.45) : AppTheme.cardStroke.opacity(0.45), lineWidth: 1)
        )
        #endif
        .accessibilityIdentifier("textInput_textEditor")
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

// MARK: - Native NSTextView wrapper

struct ScriptTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = PlaceholderTextView()

        textView.font = font
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 4
        textView.delegate = context.coordinator
        textView.string = text
        textView.placeholderString = placeholder
        textView.onFocusChange = { focused in
            DispatchQueue.main.async { isFocused = focused }
        }

        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PlaceholderTextView else { return }
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScriptTextEditor

        init(_ parent: ScriptTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

final class PlaceholderTextView: NSTextView {
    var placeholderString: String = ""
    var onFocusChange: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChange?(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocusChange?(false) }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if string.isEmpty, let font = self.font {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: font
            ]
            let inset = textContainerInset
            let padding = textContainer?.lineFragmentPadding ?? 0
            let rect = NSRect(
                x: inset.width + padding,
                y: inset.height,
                width: bounds.width - (inset.width + padding) * 2,
                height: bounds.height - inset.height * 2
            )
            placeholderString.draw(in: rect, withAttributes: attrs)
        }
    }
}
