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
        .liquidGlassContainer(spacing: contentSpacing)
        .padding(.horizontal, 14)
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
                .foregroundStyle(isReady ? accentColor : AppTheme.textSecondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .optionalAccessibilityIdentifier(accessibilityIdentifier)
    }
}

struct StudioCollectionHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let iconName: String
    var accentColor: Color = AppTheme.accent
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accentColor.opacity(0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(accentColor.opacity(0.30), lineWidth: 0.8)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .tracking(1.1)

                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 10)

            if let trailing {
                Text(trailing)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .vocelloGlassBadge(tint: accentColor.opacity(0.18))
            }
        }
        .padding(16)
        .vocelloGlassSurface(
            padding: 0,
            radius: LayoutConstants.stageRadius,
            fill: AppTheme.stageFill
        )
        .accessibilityElement(children: .combine)
    }
}

struct GenerationStudioLayout<Stage: View, Inspector: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let mode: GenerationMode
    let title: String
    let subtitle: String
    let statusTitle: String
    let statusDetail: String
    let isReady: Bool
    let modelName: String
    let characterCount: Int
    let characterLimit: Int?
    let onModeSelect: (GenerationMode) -> Void
    @ViewBuilder let stage: () -> Stage
    @ViewBuilder let inspector: () -> Inspector

    init(
        mode: GenerationMode,
        title: String,
        subtitle: String,
        statusTitle: String,
        statusDetail: String,
        isReady: Bool,
        modelName: String,
        characterCount: Int,
        characterLimit: Int? = nil,
        onModeSelect: @escaping (GenerationMode) -> Void,
        @ViewBuilder stage: @escaping () -> Stage,
        @ViewBuilder inspector: @escaping () -> Inspector
    ) {
        self.mode = mode
        self.title = title
        self.subtitle = subtitle
        self.statusTitle = statusTitle
        self.statusDetail = statusDetail
        self.isReady = isReady
        self.modelName = modelName
        self.characterCount = characterCount
        self.characterLimit = characterLimit
        self.onModeSelect = onModeSelect
        self.stage = stage
        self.inspector = inspector
    }

    private var accentColor: Color {
        AppTheme.modeColor(for: mode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.generationShellSpacing) {
            GenerationStudioHeader(
                mode: mode,
                title: title,
                subtitle: subtitle,
                statusTitle: statusTitle,
                statusDetail: statusDetail,
                isReady: isReady,
                modelName: modelName,
                characterCount: characterCount,
                characterLimit: characterLimit,
                onModeSelect: onModeSelect
            )

            HStack(alignment: .top, spacing: LayoutConstants.generationShellSpacing) {
                stageColumn
                inspectorColumn
            }
        }
        .liquidGlassContainer(spacing: LayoutConstants.generationShellSpacing)
        .modeGlassTint(accentColor)
        .modeCanvasBackdrop(accentColor)
    }

    private var stageColumn: some View {
        stage()
            .frame(
                minWidth: 0,
                idealWidth: LayoutConstants.studioStageMinWidth,
                maxWidth: .infinity,
                alignment: .topLeading
            )
            .layoutPriority(1)
    }

    private var inspectorColumn: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.generationShellSpacing) {
            inspector()
            StudioSignalCard(
                mode: mode,
                isReady: isReady,
                statusTitle: statusTitle,
                statusDetail: statusDetail
            )
        }
        .frame(
            minWidth: LayoutConstants.workflowSecondaryMinWidth,
            idealWidth: LayoutConstants.studioInspectorWidth,
            maxWidth: LayoutConstants.workflowSecondaryMaxWidth,
            alignment: .topLeading
        )
    }
}

private struct GenerationStudioHeader: View {
    let mode: GenerationMode
    let title: String
    let subtitle: String
    let statusTitle: String
    let statusDetail: String
    let isReady: Bool
    let modelName: String
    let characterCount: Int
    let characterLimit: Int?
    let onModeSelect: (GenerationMode) -> Void

    private var accentColor: Color {
        AppTheme.modeColor(for: mode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.studioHeaderSpacing) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: mode.headerIconName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accentColor)
                        Text("Vocello Studio")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .textCase(.uppercase)
                            .tracking(1.2)
                    }

                    Text(title)
                        .font(.system(size: 30, weight: .bold, design: .default))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                StudioReadinessChip(
                    accentColor: accentColor,
                    isReady: isReady,
                    title: statusTitle,
                    detail: statusDetail
                )
            }

            HStack(alignment: .center, spacing: 12) {
                GenerationModeSwitcher(
                    selectedMode: mode,
                    onModeSelect: onModeSelect
                )

                Spacer(minLength: 0)

                StudioTelemetryStrip(
                    accentColor: accentColor,
                    modelName: modelName,
                    characterCount: characterCount,
                    characterLimit: characterLimit
                )
            }
        }
        .padding(16)
        .vocelloGlassSurface(
            padding: 0,
            radius: LayoutConstants.stageRadius,
            fill: AppTheme.stageFill
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("generation_studioHeader")
    }
}

private struct GenerationModeSwitcher: View {
    let selectedMode: GenerationMode
    let onModeSelect: (GenerationMode) -> Void

    private let modes: [GenerationMode] = [.custom, .design, .clone]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(modes, id: \.self) { mode in
                let isSelected = selectedMode == mode
                let color = AppTheme.modeColor(for: mode)

                Button {
                    onModeSelect(mode)
                } label: {
                    Label(mode.studioSwitcherTitle, systemImage: mode.switcherIconName)
                        .labelStyle(.titleAndIcon)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(minWidth: 104)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? AppTheme.warmIvory : AppTheme.textSecondary)
                .background(
                    Capsule()
                        .fill(isSelected ? color.opacity(0.28) : AppTheme.inlineFill.opacity(0.58))
                        .overlay(
                            Capsule()
                                .stroke(
                                    isSelected ? color.opacity(0.74) : AppTheme.inlineStroke.opacity(0.42),
                                    lineWidth: isSelected ? 1.1 : 0.75
                                )
                        )
                )
                .vocelloGlassBadge(tint: isSelected ? color.opacity(0.34) : nil)
                .focusEffectDisabled()
                .accessibilityIdentifier("generation_mode_\(mode.rawValue)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("generation_modeSwitcher")
    }
}

private struct StudioReadinessChip: View {
    let accentColor: Color
    let isReady: Bool
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isReady ? accentColor : AppTheme.textSecondary)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: 240, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .vocelloGlassBadge(tint: isReady ? accentColor.opacity(0.30) : nil)
        .accessibilityIdentifier("generation_readinessChip")
    }
}

private struct StudioTelemetryStrip: View {
    let accentColor: Color
    let modelName: String
    let characterCount: Int
    let characterLimit: Int?

    var body: some View {
        HStack(spacing: 8) {
            StudioTelemetryPill(
                label: "Model",
                value: modelName,
                color: accentColor
            )
            StudioTelemetryPill(
                label: "Script",
                value: characterLimit.map { "\(characterCount)/\($0)" } ?? "\(characterCount)",
                color: AppTheme.textSecondary
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("generation_telemetryStrip")
    }
}

private struct StudioTelemetryPill: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppTheme.textSecondary)
                .tracking(0.8)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .vocelloGlassBadge(tint: color.opacity(0.16))
    }
}

private struct StudioSignalCard: View {
    let mode: GenerationMode
    let isReady: Bool
    let statusTitle: String
    let statusDetail: String

    private var accentColor: Color {
        AppTheme.modeColor(for: mode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text("Studio signal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .textCase(.uppercase)
                    .tracking(1.1)
            }

            HStack(alignment: .center, spacing: 8) {
                ForEach(0..<28, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(index % 3 == 0 ? accentColor.opacity(0.90) : accentColor.opacity(0.36))
                        .frame(width: 3, height: CGFloat(8 + ((index * 11) % 22)))
                        .frame(maxHeight: 34, alignment: .center)
                }
            }
            .frame(height: 38)
            .accessibilityHidden(true)

            WorkflowReadinessNote(
                isReady: isReady,
                title: statusTitle,
                detail: statusDetail,
                accentColor: accentColor
            )
        }
        .vocelloGlassSurface(
            padding: 12,
            radius: LayoutConstants.cardRadius,
            fill: AppTheme.inlineFill
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("generation_studioSignal")
    }
}

extension GenerationMode {
    var studioSwitcherTitle: String {
        switch self {
        case .custom: return "Choose"
        case .design: return "Describe"
        case .clone: return "Clone"
        }
    }

    var headerIconName: String {
        switch self {
        case .custom: return "person.wave.2"
        case .design: return "text.bubble"
        case .clone: return "waveform.badge.plus"
        }
    }

    var switcherIconName: String {
        switch self {
        case .custom: return "person.wave.2"
        case .design: return "paintbrush.pointed"
        case .clone: return "waveform"
        }
    }
}

extension SidebarItem {
    static func item(for mode: GenerationMode) -> SidebarItem {
        switch mode {
        case .custom: return .customVoice
        case .design: return .voiceDesign
        case .clone: return .voiceCloning
        }
    }
}

struct ModelRecoveryCard: View {
    let title: String
    let detail: String
    let primaryActionTitle: String
    var accentColor: Color = AppTheme.accent
    var accessibilityIdentifier: String? = nil
    let onPrimaryAction: () -> Void
    let onSecondaryAction: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "square.stack.3d.down.forward")
                        .font(.subheadline)
                        .foregroundStyle(accentColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }

                HStack(spacing: 10) {
                    Button(primaryActionTitle, action: onPrimaryAction)
                        .buttonStyle(.borderedProminent)
                        .tint(accentColor)

                    Button("Show Models", action: onSecondaryAction)
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .profileGroupBoxStyle()
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
                        .foregroundStyle(AppTheme.textSecondary)
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
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer(minLength: 8)

                if let trailingText {
                    Text(trailingText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
        .profileGroupBoxStyle()
        .frame(maxHeight: fillsAvailableHeight ? .infinity : nil, alignment: .topLeading)
        .optionalAccessibilityIdentifier(accessibilityIdentifier)
    }
}

struct CompactConfigurationSection<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.cardGlassTint) private var cardGlassTint

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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer(minLength: 10)

                if let trailingText {
                    Text(trailingText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }

            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            panelBody
            .padding(.horizontal, panelPadding)
            .padding(.vertical, max(panelPadding - 1, 0))
            #if QW_UI_LIQUID
            .background {
                if #available(macOS 26, *) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AppTheme.inlineFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    AppTheme.inlineStroke.opacity(
                                        colorScheme == .dark
                                            ? AppTheme.surfaceStrokeOpacity(for: colorScheme)
                                            : AppTheme.surfaceStrokeOpacity(for: colorScheme) * 0.88
                                    ),
                                    lineWidth: AppTheme.surfaceStrokeWidth(for: colorScheme)
                                )
                        )
                        .glassEffect(
                            .regular.tint(
                                cardGlassTint.map {
                                    AppTheme.surfaceGlassTint($0, for: colorScheme)
                                } ?? AppTheme.smokedGlassTint
                            ),
                            in: .rect(cornerRadius: 12)
                        )
                        .glass3DDepth(
                            radius: 12,
                            intensity: (colorScheme == .dark ? 1.0 : 0.72)
                                * (cardGlassTint == nil ? 1.0 : 1.15)
                        )
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
            .foregroundStyle(AppTheme.textPrimary)
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
        .liquidGlassContainer(spacing: LayoutConstants.generationShellSpacing)
    }
}
