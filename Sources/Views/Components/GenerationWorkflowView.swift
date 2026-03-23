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

struct HiddenAccessibilityMarker: View {
    let value: String
    let identifier: String

    var body: some View {
        Text(value)
            .font(.caption2)
            .foregroundStyle(.clear)
            .opacity(0.01)
            .frame(width: 1, height: 1, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityLabel(value)
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
    }
}

struct PageScaffold<Header: View, Content: View>: View {
    let accessibilityIdentifier: String?
    let fillsViewportHeight: Bool
    let contentSpacing: CGFloat
    let contentMaxWidth: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    init(
        accessibilityIdentifier: String? = nil,
        fillsViewportHeight: Bool = false,
        contentSpacing: CGFloat = LayoutConstants.sectionSpacing,
        contentMaxWidth: CGFloat = LayoutConstants.contentMaxWidth,
        topPadding: CGFloat = 8,
        bottomPadding: CGFloat = LayoutConstants.canvasPadding,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.accessibilityIdentifier = accessibilityIdentifier
        self.fillsViewportHeight = fillsViewportHeight
        self.contentSpacing = contentSpacing
        self.contentMaxWidth = contentMaxWidth
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.header = header
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                contentColumn(viewportHeight: fillsViewportHeight ? proxy.size.height : nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .profileBackground(Color(nsColor: .windowBackgroundColor))
        }
        .optionalAccessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private func contentColumn(viewportHeight: CGFloat?) -> some View {
        let column = VStack(alignment: .leading, spacing: contentSpacing) {
            header()
            content()
        }
        .padding(.horizontal, LayoutConstants.canvasPadding)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
        .contentColumn(maxWidth: contentMaxWidth)

        if let viewportHeight {
            column
                .frame(
                    maxWidth: .infinity,
                    minHeight: viewportHeight,
                    alignment: .topLeading
                )
        } else {
            column
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension PageScaffold where Header == EmptyView {
    init(
        accessibilityIdentifier: String? = nil,
        fillsViewportHeight: Bool = false,
        contentSpacing: CGFloat = LayoutConstants.sectionSpacing,
        contentMaxWidth: CGFloat = LayoutConstants.contentMaxWidth,
        topPadding: CGFloat = 8,
        bottomPadding: CGFloat = LayoutConstants.canvasPadding,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            accessibilityIdentifier: accessibilityIdentifier,
            fillsViewportHeight: fillsViewportHeight,
            contentSpacing: contentSpacing,
            contentMaxWidth: contentMaxWidth,
            topPadding: topPadding,
            bottomPadding: bottomPadding,
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
    var fillsAvailableHeight: Bool = false
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
            .frame(
                maxWidth: .infinity,
                minHeight: minHeight,
                maxHeight: fillsAvailableHeight ? .infinity : nil,
                alignment: .topLeading
            )
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
        .profileGroupBoxStyle()
        .frame(maxHeight: fillsAvailableHeight ? .infinity : nil, alignment: .topLeading)
        .optionalAccessibilityIdentifier(accessibilityIdentifier)
    }
}

struct CompactConfigurationSection<Content: View>: View {
    let title: String
    var detail: String? = nil
    var iconName: String? = nil
    var accentColor: Color = AppTheme.accent
    var trailingText: String? = nil
    var rowSpacing: CGFloat = LayoutConstants.configurationRowSpacing
    var panelPadding: CGFloat = LayoutConstants.configurationPanelPadding
    var contentSlotHeight: CGFloat? = nil
    var accessibilityIdentifier: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
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

            panelBody
            .padding(.horizontal, panelPadding)
            .padding(.vertical, max(panelPadding - 1, 0))
            #if QW_UI_LIQUID
            .background {
                if #available(macOS 26, *) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular.tint(AppTheme.smokedGlassTint), in: .rect(cornerRadius: 12))
                        .glass3DDepth(radius: 12)
                } else {
                    compactPanelLegacyBackground
                }
            }
            #else
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.inlineFill.opacity(0.58))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.inlineStroke.opacity(0.24), lineWidth: 1)
            )
            #endif
        }
        .optionalAccessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private var panelBody: some View {
        if let contentSlotHeight {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(
                maxWidth: .infinity,
                minHeight: contentSlotHeight,
                maxHeight: contentSlotHeight,
                alignment: .topLeading
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
        }
    }

    #if QW_UI_LIQUID
    private var compactPanelLegacyBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.inlineFill.opacity(0.58))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.inlineStroke.opacity(0.12), lineWidth: 0.5)
        }
    }
    #endif
}

struct ConfigurationFieldRow<Content: View, Supporting: View>: View {
    let label: String
    var rowVerticalPadding: CGFloat = LayoutConstants.configurationRowVerticalPadding
    var horizontalSpacing: CGFloat = 16
    var stackedSpacing: CGFloat = 8
    var supportingSpacing: CGFloat = 6
    var accessibilityIdentifier: String? = nil
    @ViewBuilder let content: () -> Content
    @ViewBuilder let supporting: () -> Supporting

    var body: some View {
        VStack(alignment: .leading, spacing: supportingSpacing) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: horizontalSpacing) {
                    labelView
                        .frame(width: LayoutConstants.configurationLabelWidth, alignment: .leading)

                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: stackedSpacing) {
                    labelView
                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            supporting()
        }
        .padding(.vertical, rowVerticalPadding)
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
        rowVerticalPadding: CGFloat = LayoutConstants.configurationRowVerticalPadding,
        horizontalSpacing: CGFloat = 16,
        stackedSpacing: CGFloat = 8,
        supportingSpacing: CGFloat = 6,
        accessibilityIdentifier: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            label: label,
            rowVerticalPadding: rowVerticalPadding,
            horizontalSpacing: horizontalSpacing,
            stackedSpacing: stackedSpacing,
            supportingSpacing: supportingSpacing,
            accessibilityIdentifier: accessibilityIdentifier,
            content: content
        ) {
            EmptyView()
        }
    }
}

struct DeliveryControlsView: View {
    @Binding var emotion: String
    var deliveryProfile: Binding<DeliveryProfile?>? = nil
    var accentColor: Color = AppTheme.accent
    var accessibilityPrefix: String = "delivery"
    var isCompact: Bool = false
    var showsLabel: Bool = true

    var body: some View {
        EmotionPickerView(
            emotion: $emotion,
            deliveryProfile: deliveryProfile,
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
