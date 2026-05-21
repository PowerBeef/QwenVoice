import SwiftUI
import UIKit

/// Multi-line text editor that **actually** honors
/// `.frame(maxHeight: .infinity)` from a SwiftUI parent.
///
/// SwiftUI's stock `TextEditor` ignores its preferred-height instruction
/// from parents and reports an intrinsic size that doesn't compose with
/// `.layoutPriority(1)` cleanly — it claims the canvas's entire vertical
/// budget regardless of sibling layout priority, which is what blocked
/// the Studio composer's `flex: 1` design (audit item B.3, see
/// `/tmp/ui-audit-26-05-21/UI-AUDIT.md`). This wrapper bridges a
/// `UITextView` and overrides `intrinsicContentSize.height` to
/// `UIView.noIntrinsicMetric` so SwiftUI's preferred-size pipeline
/// drives the height end-to-end.
///
/// API mirrors what `IOSStudioCanvas.composerPad` previously read from
/// `TextEditor`: a `text` binding, an `font` + `textColor` pair, a
/// `tintColor` for the cursor, an `isFocused` binding for the
/// keyboard, and an optional `onChange(_:)` callback for character-cap
/// enforcement at the parent level.
struct IOSFlexibleTextEditor: UIViewRepresentable {
    @Binding var text: String
    var font: UIFont
    var textColor: UIColor
    var tintColor: UIColor
    var isFocused: Binding<Bool>?

    func makeUIView(context: Context) -> NoIntrinsicHeightTextView {
        let view = NoIntrinsicHeightTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = font
        view.textColor = textColor
        view.tintColor = tintColor
        // Match SwiftUI TextEditor's default content insets so the
        // caret + first-line text align with the placeholder Text view
        // overlaid by the parent ZStack in IOSStudioCanvas.
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = true
        view.alwaysBounceVertical = false
        view.showsVerticalScrollIndicator = true
        view.autocorrectionType = .default
        view.autocapitalizationType = .sentences
        view.smartQuotesType = .yes
        view.smartDashesType = .yes
        return view
    }

    func updateUIView(_ view: NoIntrinsicHeightTextView, context: Context) {
        if view.text != text {
            view.text = text
        }
        if view.font != font {
            view.font = font
        }
        if view.textColor != textColor {
            view.textColor = textColor
        }
        if view.tintColor != tintColor {
            view.tintColor = tintColor
        }

        if let isFocused {
            // Reflect the SwiftUI focus binding into UIKit. Guard the
            // call so we don't fight UIKit's own focus events.
            if isFocused.wrappedValue, !view.isFirstResponder {
                DispatchQueue.main.async { view.becomeFirstResponder() }
            } else if !isFocused.wrappedValue, view.isFirstResponder {
                DispatchQueue.main.async { view.resignFirstResponder() }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: IOSFlexibleTextEditor

        init(_ parent: IOSFlexibleTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            // Avoid a feedback loop if the binding update triggers
            // updateUIView with the same text.
            if parent.text != textView.text {
                parent.text = textView.text
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused?.wrappedValue = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused?.wrappedValue = false
        }
    }
}

/// UITextView subclass that opts out of supplying an intrinsic height
/// to Auto Layout, so SwiftUI's `.frame(maxHeight:)` (including
/// `.infinity`) drives the height. Width still uses Auto Layout's
/// usual content-hugging behavior.
final class NoIntrinsicHeightTextView: UITextView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }
}
