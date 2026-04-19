import SwiftUI
import UIKit

struct IOSDeliveryPicker: View {
    @Binding var delivery: DeliveryInputState
    let tint: Color
    let customAccessibilityIdentifier: String?

    @FocusState private var isCustomEditorFocused: Bool
    @ScaledMetric(relativeTo: .body) private var inlineEditorHeight = 76
    @ScaledMetric(relativeTo: .body) private var contentSpacing = 8

    init(
        delivery: Binding<DeliveryInputState>,
        tint: Color,
        customAccessibilityIdentifier: String? = nil
    ) {
        _delivery = delivery
        self.tint = tint
        self.customAccessibilityIdentifier = customAccessibilityIdentifier
    }

    private var selectionLabel: String {
        switch delivery.mode {
        case .preset:
            return delivery.selectedPresetLabel
        case .custom:
            return customSummaryText
        }
    }

    private var customSummaryText: String {
        let trimmed = delivery.customText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Custom delivery…" : trimmed
    }

    private var isCustomDeliveryEnabled: Bool {
        delivery.mode == .custom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            Menu {
                ForEach(EmotionPreset.all, id: \.id) { preset in
                    Button {
                        delivery.mode = .preset
                        delivery.selectedPresetID = preset.id
                    } label: {
                        Label(
                            preset.id == "neutral" ? "Normal tone" : preset.label,
                            systemImage: delivery.mode == .preset && delivery.selectedPresetID == preset.id
                                ? "checkmark"
                                : ""
                        )
                    }
                }

                Divider()

                Button {
                    delivery.mode = .custom
                } label: {
                    Label(
                        "Custom delivery…",
                        systemImage: delivery.mode == .custom ? "checkmark" : ""
                    )
                }
            } label: {
                HStack(spacing: 10) {
                    Text(selectionLabel)
                        .lineLimit(1)
                        .foregroundStyle(IOSAppTheme.textPrimary)

                    Spacer(minLength: 8)

                    Image(systemName: delivery.mode == .custom ? "slider.horizontal.3" : "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(delivery.mode == .custom ? tint : IOSAppTheme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .iosSelectionFieldChrome(tint: tint, isFocused: isCustomDeliveryEnabled)
            .accessibilityIdentifier(customAccessibilityIdentifier ?? "")

            ZStack(alignment: .topTrailing) {
                IOSMultilineTextView(
                    text: $delivery.customText,
                    placeholder: "Describe the delivery or emotion (optional)",
                    tint: tint,
                    isFocused: Binding(
                        get: { isCustomEditorFocused && isCustomDeliveryEnabled },
                        set: { isCustomEditorFocused = $0 }
                    ),
                    isEnabled: isCustomDeliveryEnabled,
                    accessibilityIdentifier: customEditorAccessibilityIdentifier
                )
                .frame(height: inlineEditorHeight)
                .clipped()
                .opacity(isCustomDeliveryEnabled ? 1 : 0.48)

                if !isCustomDeliveryEnabled {
                    IOSStatusBadge(text: "Custom only", tone: .muted)
                        .padding(.top, 10)
                        .padding(.trailing, 10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityHint(
                isCustomDeliveryEnabled
                    ? "Custom delivery input"
                    : "Select Custom delivery to edit this field"
            )
        }
        .onChange(of: delivery.mode) { _, newMode in
            if newMode == .custom {
                DispatchQueue.main.async {
                    isCustomEditorFocused = true
                }
            } else {
                isCustomEditorFocused = false
            }
        }
    }

    private var customEditorAccessibilityIdentifier: String? {
        guard let customAccessibilityIdentifier else { return nil }
        return "\(customAccessibilityIdentifier)_editor"
    }
}

struct IOSMultilineTextView: UIViewRepresentable {
    @Binding var text: String

    let placeholder: String
    let tint: Color
    @Binding var isFocused: Bool
    let isEnabled: Bool
    let isScrollEnabled: Bool
    let maxCharacterCount: Int?
    let accessibilityIdentifier: String?

    init(
        text: Binding<String>,
        placeholder: String,
        tint: Color = IOSBrandTheme.accent,
        isFocused: Binding<Bool> = .constant(false),
        isEnabled: Bool = true,
        isScrollEnabled: Bool = true,
        maxCharacterCount: Int? = nil,
        accessibilityIdentifier: String? = nil
    ) {
        _text = text
        self.placeholder = placeholder
        self.tint = tint
        _isFocused = isFocused
        self.isEnabled = isEnabled
        self.isScrollEnabled = isScrollEnabled
        self.maxCharacterCount = maxCharacterCount
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: $isFocused,
            placeholder: placeholder,
            tint: UIColor(tint),
            maxCharacterCount: maxCharacterCount
        )
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = IOSAppTheme.fieldFillUIColor
        textView.layer.cornerRadius = 18
        textView.layer.borderWidth = 1
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.isUserInteractionEnabled = isEnabled
        textView.isScrollEnabled = isScrollEnabled
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.delegate = context.coordinator
        textView.text = text.isEmpty ? placeholder : text
        textView.textColor = text.isEmpty ? IOSAppTheme.textPlaceholderUIColor : IOSAppTheme.textPrimaryUIColor
        textView.tintColor = UIColor(tint)
        textView.keyboardAppearance = textView.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        textView.accessibilityIdentifier = accessibilityIdentifier
        context.coordinator.applyChrome(to: textView, isFocused: false)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        guard !context.coordinator.isUpdating else { return }

        uiView.backgroundColor = IOSAppTheme.fieldFillUIColor
        uiView.tintColor = UIColor(tint)
        uiView.isScrollEnabled = isScrollEnabled
        uiView.isEditable = isEnabled
        uiView.isSelectable = isEnabled
        uiView.isUserInteractionEnabled = isEnabled
        uiView.alpha = isEnabled ? 1 : 0.88
        uiView.keyboardAppearance = uiView.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        uiView.accessibilityIdentifier = accessibilityIdentifier
        context.coordinator.applyChrome(to: uiView, isFocused: isEnabled && isFocused)

        if isEnabled && isFocused && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if (!isEnabled || !isFocused) && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }

        if text.isEmpty, uiView.text != placeholder, !uiView.isFirstResponder {
            uiView.text = placeholder
            uiView.textColor = IOSAppTheme.textPlaceholderUIColor
        } else if !text.isEmpty, uiView.text != text {
            uiView.text = text
            uiView.textColor = IOSAppTheme.textPrimaryUIColor
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        @Binding var isFocused: Bool

        var isUpdating = false

        private let placeholder: String
        private let tint: UIColor
        private let maxCharacterCount: Int?

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            placeholder: String,
            tint: UIColor,
            maxCharacterCount: Int?
        ) {
            _text = text
            _isFocused = isFocused
            self.placeholder = placeholder
            self.tint = tint
            self.maxCharacterCount = maxCharacterCount
        }

        private func currentText(for textView: UITextView) -> String {
            textView.textColor == IOSAppTheme.textPlaceholderUIColor ? "" : textView.text
        }

        private func updateBinding(with value: String) {
            isUpdating = true
            text = value
            isUpdating = false
        }

        func applyChrome(to textView: UITextView, isFocused: Bool) {
            textView.layer.borderColor = (isFocused ? tint.withAlphaComponent(0.52) : UIColor.separator.withAlphaComponent(0.18)).cgColor
            textView.layer.borderWidth = isFocused ? 1.5 : 1
            textView.layer.shadowColor = tint.withAlphaComponent(isFocused ? 0.16 : 0).cgColor
            textView.layer.shadowOpacity = isFocused ? 1 : 0
            textView.layer.shadowRadius = isFocused ? 10 : 0
            textView.layer.shadowOffset = CGSize(width: 0, height: isFocused ? 4 : 0)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isFocused = true
            applyChrome(to: textView, isFocused: true)
            if textView.textColor == IOSAppTheme.textPlaceholderUIColor {
                textView.text = ""
                textView.textColor = IOSAppTheme.textPrimaryUIColor
            }
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText: String) -> Bool {
            guard let maxCharacterCount else { return true }

            let existingText = currentText(for: textView)
            guard let swiftRange = Range(range, in: existingText) else { return true }

            let proposedText = existingText.replacingCharacters(in: swiftRange, with: replacementText)
            guard proposedText.count > maxCharacterCount else { return true }

            let replacedCharacterCount = existingText[swiftRange].count
            let availableCharacterCount = maxCharacterCount - (existingText.count - replacedCharacterCount)
            guard availableCharacterCount > 0 else { return false }

            let truncatedReplacement = String(replacementText.prefix(availableCharacterCount))
            guard !truncatedReplacement.isEmpty else { return false }

            let clampedText = existingText.replacingCharacters(in: swiftRange, with: truncatedReplacement)
            textView.text = clampedText
            textView.textColor = IOSAppTheme.textPrimaryUIColor
            updateBinding(with: clampedText)

            let insertionLocation = range.location + (truncatedReplacement as NSString).length
            textView.selectedRange = NSRange(location: insertionLocation, length: 0)
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            updateBinding(with: currentText(for: textView))
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isFocused = false
            applyChrome(to: textView, isFocused: false)

            if textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = ""
                textView.text = placeholder
                textView.textColor = IOSAppTheme.textPlaceholderUIColor
            }
        }
    }
}

struct IOSSaveVoiceSheet: View {
    let title: String
    @Binding var suggestedName: String
    @Binding var transcript: String
    let errorMessage: String?
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Saved voice name", text: $suggestedName)
                }

                Section("Transcript") {
                    IOSMultilineTextView(text: $transcript, placeholder: "Optional transcript")
                        .frame(minHeight: 120)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .tint(IOSBrandTheme.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .disabled(suggestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
