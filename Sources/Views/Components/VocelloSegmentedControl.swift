import SwiftUI

/// Capsule segmented control for in-pane sub-section navigation
/// (Generate's Custom/Design/Clone tabs, Library's History/Voices,
/// Settings' Models/Preferences). Each segment can declare its own tint,
/// so the active pill picks up the right brand color per section.
struct VocelloSegmentedControl<Value: Hashable & Identifiable>: View {
    struct Segment {
        let value: Value
        let label: String
        let tint: Color
        let accessibilityIdentifier: String?

        init(
            value: Value,
            label: String,
            tint: Color,
            accessibilityIdentifier: String? = nil
        ) {
            self.value = value
            self.label = label
            self.tint = tint
            self.accessibilityIdentifier = accessibilityIdentifier
        }
    }

    let segments: [Segment]
    @Binding var selection: Value

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(segments, id: \.value.id) { segment in
                segmentButton(segment, isActive: selection == segment.value)
            }
        }
        .padding(4)
        .background(trackBackground)
    }

    @ViewBuilder
    private func segmentButton(_ segment: Segment, isActive: Bool) -> some View {
        Button {
            AppLaunchConfiguration.performAnimated(.easeInOut(duration: 0.2)) {
                selection = segment.value
            }
        } label: {
            SegmentLabel(
                text: segment.label,
                tint: segment.tint,
                isActive: isActive
            )
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .accessibilityLabel(segment.label)
        .accessibilityValue(isActive ? "selected" : "not selected")
        .ifLet(segment.accessibilityIdentifier) { view, id in
            view.accessibilityIdentifier(id)
        }
    }

    @ViewBuilder
    private var trackBackground: some View {
        Capsule(style: .continuous)
            .fill(AppTheme.cardFill.opacity(colorScheme == .dark ? 0.74 : 0.86))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(AppTheme.cardStroke.opacity(colorScheme == .dark ? 0.18 : 0.40), lineWidth: 0.5)
            )
    }
}

private struct SegmentLabel: View {
    let text: String
    let tint: Color
    let isActive: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .tracking(-0.1)
            .foregroundStyle(isActive ? AppTheme.warmIvory : AppTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(activeFillBackground)
    }

    @ViewBuilder
    private var activeFillBackground: some View {
        if isActive {
            Capsule(style: .continuous)
                .fill(tint.opacity(0.22))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(tint.opacity(0.42), lineWidth: 0.75)
                )
        } else {
            Color.clear
        }
    }
}

private extension View {
    @ViewBuilder
    func ifLet<Value, Transform: View>(
        _ value: Value?,
        transform: (Self, Value) -> Transform
    ) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}
