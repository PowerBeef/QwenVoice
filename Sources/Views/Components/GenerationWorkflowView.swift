import SwiftUI

private extension View {
    @ViewBuilder
    func optionalAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

struct PageScaffold<Header: View, Content: View>: View {
    let accessibilityIdentifier: String?
    let contentSpacing: CGFloat
    let contentMaxWidth: CGFloat
    let topPadding: CGFloat
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    init(
        accessibilityIdentifier: String? = nil,
        contentSpacing: CGFloat = LayoutConstants.sectionSpacing,
        contentMaxWidth: CGFloat = LayoutConstants.contentMaxWidth,
        topPadding: CGFloat = 8,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.accessibilityIdentifier = accessibilityIdentifier
        self.contentSpacing = contentSpacing
        self.contentMaxWidth = contentMaxWidth
        self.topPadding = topPadding
        self.header = header
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: contentSpacing) {
                header()
                content()
            }
            .padding(.horizontal, LayoutConstants.canvasPadding)
            .padding(.top, topPadding)
            .padding(.bottom, LayoutConstants.canvasPadding)
            .contentColumn(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .optionalAccessibilityIdentifier(accessibilityIdentifier)
    }
}

extension PageScaffold where Header == EmptyView {
    init(
        accessibilityIdentifier: String? = nil,
        contentSpacing: CGFloat = LayoutConstants.sectionSpacing,
        contentMaxWidth: CGFloat = LayoutConstants.contentMaxWidth,
        topPadding: CGFloat = 8,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            accessibilityIdentifier: accessibilityIdentifier,
            contentSpacing: contentSpacing,
            contentMaxWidth: contentMaxWidth,
            topPadding: topPadding,
            header: { EmptyView() },
            content: content
        )
    }
}

struct WorkflowReadinessNote: View {
    let isReady: Bool
    let title: String
    let detail: String
    var accentColor: Color = AppTheme.accent
    var accessibilityIdentifier: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "info.circle")
                .font(.subheadline)
                .foregroundStyle(isReady ? accentColor : .secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .optionalAccessibilityIdentifier(accessibilityIdentifier)
    }
}

enum StudioCardStyle {
    case standard
    case inline
}

struct StudioSectionCard<Content: View>: View {
    let title: String
    var detail: String? = nil
    var iconName: String? = nil
    var accentColor: Color = AppTheme.accent
    var trailingText: String? = nil
    var minHeight: CGFloat? = nil
    var contentAlignment: HorizontalAlignment = .leading
    var style: StudioCardStyle = .standard
    var accessibilityIdentifier: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        GroupBox {
            VStack(alignment: contentAlignment, spacing: style == .inline ? 8 : 10) {
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                content()
            }
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        } label: {
            HStack(spacing: 8) {
                if let iconName {
                    Image(systemName: iconName)
                        .foregroundStyle(accentColor)
                }

                Text(title)
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)

                if let trailingText {
                    Text(trailingText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .groupBoxStyle(.automatic)
        .optionalAccessibilityIdentifier(accessibilityIdentifier)
    }
}

struct CompactConfigurationSection<Content: View>: View {
    let title: String
    var detail: String? = nil
    var iconName: String? = nil
    var accentColor: Color = AppTheme.accent
    var trailingText: String? = nil
    var accessibilityIdentifier: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.configurationRowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let iconName {
                    Image(systemName: iconName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accentColor)
                }

                Text(title)
                    .font(.headline.weight(.semibold))

                Spacer(minLength: 10)

                if let trailingText {
                    Text(trailingText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, LayoutConstants.configurationPanelPadding)
            .padding(.vertical, LayoutConstants.configurationPanelPadding - 1)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.inlineFill.opacity(0.58))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.inlineStroke.opacity(0.24), lineWidth: 1)
            )
        }
        .optionalAccessibilityIdentifier(accessibilityIdentifier)
    }
}

struct ConfigurationFieldRow<Content: View, Supporting: View>: View {
    let label: String
    var accessibilityIdentifier: String? = nil
    @ViewBuilder let content: () -> Content
    @ViewBuilder let supporting: () -> Supporting

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    labelView
                        .frame(width: LayoutConstants.configurationLabelWidth, alignment: .leading)

                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 8) {
                    labelView
                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            supporting()
        }
        .padding(.vertical, LayoutConstants.configurationRowVerticalPadding)
        .optionalAccessibilityIdentifier(accessibilityIdentifier)
    }

    private var labelView: some View {
        Text(label)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
    }
}

extension ConfigurationFieldRow where Supporting == EmptyView {
    init(
        label: String,
        accessibilityIdentifier: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(label: label, accessibilityIdentifier: accessibilityIdentifier, content: content) {
            EmptyView()
        }
    }
}

struct DeliveryControlsView: View {
    @Binding var emotion: String
    var accentColor: Color = AppTheme.accent
    var accessibilityPrefix: String = "delivery"
    var isCompact: Bool = false
    var showsLabel: Bool = true

    var body: some View {
        EmotionPickerView(
            emotion: $emotion,
            accentColor: accentColor,
            accessibilityPrefix: accessibilityPrefix,
            showsLabel: showsLabel
        )
        .optionalAccessibilityIdentifier(isCompact ? nil : "\(accessibilityPrefix)_toneCard")
    }
}

struct AdaptiveControlDeck<Primary: View, Secondary: View>: View {
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let secondary: () -> Secondary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: LayoutConstants.generationShellSpacing) {
                primary()
                    .frame(
                        minWidth: LayoutConstants.workflowPrimaryMinWidth,
                        maxWidth: .infinity,
                        alignment: .topLeading
                    )
                    .layoutPriority(1)

                secondary()
                    .frame(
                        minWidth: LayoutConstants.workflowSecondaryMinWidth,
                        idealWidth: LayoutConstants.workflowSecondaryIdealWidth,
                        maxWidth: LayoutConstants.workflowSecondaryMaxWidth,
                        alignment: .topLeading
                    )
            }

            VStack(alignment: .leading, spacing: LayoutConstants.generationShellSpacing) {
                primary()
                secondary()
            }
        }
    }
}

struct GenerationStudioShell<Setup: View, Delivery: View, Composer: View>: View {
    @ViewBuilder let setup: () -> Setup
    @ViewBuilder let delivery: () -> Delivery
    @ViewBuilder let composer: () -> Composer

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.generationShellSpacing) {
            AdaptiveControlDeck {
                setup()
            } secondary: {
                delivery()
            }

            composer()
        }
    }
}
