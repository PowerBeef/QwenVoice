import SwiftUI
import QwenVoiceNative

private struct SidebarSectionHeader: View {
    let title: String
    let accessibilityID: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityIdentifier(accessibilityID)
    }
}

/// Compact Vocello brand lockup pinned to the top of the sidebar via
/// `safeAreaInset(edge: .top)`. Reuses the bundled `VocelloHeaderMark`
/// asset that the iPhone target already ships; the same asset carries the
/// Vocello wordmark + V glyph so we don't need to ship a separate macOS
/// lockup. Stays out of the List's scroll region so the brand anchor
/// remains visible as the user scrolls through sections.
private struct SidebarBrandHeader: View {
    var body: some View {
        Image("VocelloHeaderMark")
            .resizable()
            .scaledToFit()
            .frame(height: 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .accessibilityHidden(true)
    }
}

private struct SidebarRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let item: SidebarItem
    @Binding var selection: SidebarItem?
    let isDisabled: Bool
    @State private var isHovered = false

    private var isSelected: Bool {
        selection == item
    }

    @ViewBuilder
    private var rowBackground: some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.sidebarSelectionFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                // Per-mode selection edge — golden for
                                // Custom Voice / Library, lavender for
                                // Voice Design, terracotta for Voice
                                // Cloning. Matches the non-liquid
                                // fallback in `borderColor`.
                                AppTheme.sidebarColor(for: item).opacity(
                                    colorScheme == .dark ? 0.55 : 0.42
                                ),
                                lineWidth: colorScheme == .dark ? AppTheme.surfaceStrokeWidth(for: colorScheme) : 0.9
                            )
                    )
                    .glassEffect(.regular.tint(AppTheme.smokedGlassTint).interactive(), in: .rect(cornerRadius: 8))
                    .glass3DDepth(radius: 8, intensity: colorScheme == .dark ? 0.5 : 0.28)
            } else if isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.sidebarHoverFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                AppTheme.sidebarHoverStroke.opacity(colorScheme == .dark ? 1.0 : 0.72),
                                lineWidth: colorScheme == .dark ? AppTheme.surfaceStrokeWidth(for: colorScheme) : 0.85
                            )
                    )
                    .glassEffect(.regular.tint(AppTheme.smokedGlassTint).interactive(), in: .rect(cornerRadius: 8))
                    .glass3DDepth(radius: 8, intensity: colorScheme == .dark ? 0.25 : 0.16)
            } else {
                Color.clear
            }
        } else {
            legacyRowBackground
        }
        #else
        legacyRowBackground
        #endif
    }

    private var legacyRowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(backgroundColor)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isSelected || isHovered ? 1 : 0)
            }
    }

    private var backgroundColor: Color {
        if isDisabled {
            return isSelected ? Color.secondary.opacity(0.06) : .clear
        }

        if isSelected {
            return AppTheme.sidebarSelectionFill
        }

        if isHovered {
            return AppTheme.sidebarHoverFill
        }

        return .clear
    }

    private var borderColor: Color {
        if isDisabled {
            return isSelected ? Color.secondary.opacity(0.16) : .clear
        }

        if isSelected {
            // Per-mode edge accent — the stroke picks up the item's
            // Vocello palette color so selecting Voice Design shows a
            // lavender edge, Voice Cloning terracotta, etc. Library
            // and Settings rows still resolve to accent (golden) via
            // AppTheme.sidebarColor(for:).
            return AppTheme.sidebarColor(for: item).opacity(0.32)
        }

        if isHovered {
            return AppTheme.sidebarHoverStroke
        }

        return .clear
    }

    private var iconColor: Color {
        if isDisabled {
            return Color.secondary.opacity(isSelected ? 0.8 : 0.65)
        }

        return isSelected ? AppTheme.sidebarColor(for: item) : Color.primary
    }

    private var textColor: Color {
        if isDisabled {
            return Color.secondary.opacity(isSelected ? 0.88 : 0.72)
        }

        return Color.primary
    }

    private var selectionIndicatorColor: Color {
        if !isSelected {
            return .clear
        }

        return isDisabled ? Color.secondary.opacity(0.6) : AppTheme.sidebarColor(for: item)
    }

    private var accessibilityStateValue: String {
        var states: [String] = []

        if isSelected {
            states.append("selected")
        } else {
            states.append("not selected")
        }

        if isDisabled {
            states.append("disabled")
        }

        return states.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(selectionIndicatorColor)
                .frame(width: 3, height: 16)

            Image(systemName: item.iconName)
                .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(iconColor)
                .frame(width: 22, alignment: .center)

            Text(item.rawValue)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(textColor)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 34)
            .background(rowBackground)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                guard !isDisabled else { return }
                selection = item
            }
            .onHover { hovering in
                isHovered = isDisabled ? false : hovering
            }
            .onChange(of: isDisabled) { _, disabled in
                if disabled {
                    isHovered = false
                }
            }
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .animation(.easeOut(duration: 0.14), value: isSelected)
            .disabled(isDisabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.rawValue)
            .accessibilityValue(accessibilityStateValue)
            .accessibilityIdentifier(item.accessibilityID)
    }
}

struct SidebarView: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel

    @Binding var selection: SidebarItem?
    let disabledItems: Set<SidebarItem>

    private var usesNativeListSelection: Bool {
        guard let selection else { return true }
        return !disabledItems.contains(selection)
    }

    var body: some View {
        Group {
            if usesNativeListSelection {
                List(selection: $selection) {
                    sidebarListContent
                }
            } else {
                List {
                    sidebarListContent
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(AppTheme.railBackground)
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarBrandHeader()
        }
        .safeAreaInset(edge: .bottom) {
            SidebarFooterRegion()
                .environmentObject(audioPlayer)
        }
    }

    @ViewBuilder
    private var sidebarListContent: some View {
        ForEach(SidebarItem.Section.allCases, id: \.self) { section in
            Section {
                ForEach(section.items) { item in
                    SidebarRow(
                        item: item,
                        selection: $selection,
                        isDisabled: disabledItems.contains(item)
                    )
                        .tag(item as SidebarItem?)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        .listRowBackground(Color.clear)
                }
            } header: {
                SidebarSectionHeader(
                    title: section.rawValue,
                    accessibilityID: section.accessibilityID
                )
            }
        }
    }
}

private struct SidebarFooterRegion: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var ttsEngineStore: TTSEngineStore

    private let appEngineSelection = AppEngineSelection.current()

    private var resolvedSidebarStatus: SidebarStatus {
        appEngineSelection.resolveSidebarStatus(
            ttsEngineSnapshot: ttsEngineStore.snapshot,
            prefersInlinePresentation: audioPlayer.isLiveStream
        )
    }

    private var footerPresentation: SidebarFooterPresentation {
        SidebarFooterPresentation.resolve(
            sidebarStatus: resolvedSidebarStatus,
            isLiveStream: audioPlayer.isLiveStream
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(AppTheme.railStroke.opacity(colorScheme == .dark ? 0.9 : 0.34))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 10) {
                if audioPlayer.hasAudio {
                    SidebarPlayerView(inlinePlayerActivity: footerPresentation.inlinePlayerActivity)

                    if footerPresentation.showsStandaloneStatus {
                        Rectangle()
                            .fill(AppTheme.railStroke.opacity(colorScheme == .dark ? 0.65 : 0.22))
                            .frame(height: 1)
                    }
                }

                if footerPresentation.showsStandaloneStatus {
                    SidebarStatusView(
                        sidebarStatus: resolvedSidebarStatus,
                        clearError: {
                            appEngineSelection.clearSidebarError(
                                ttsEngineStore: ttsEngineStore
                            )
                        }
                    )
                }
            }
            .padding(.horizontal, LayoutConstants.shellPadding)
            .padding(.top, LayoutConstants.generationSectionSpacing)
            .padding(.bottom, LayoutConstants.shellPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppTheme.railBackground.opacity(colorScheme == .dark ? 1.0 : 0.985))
    }
}
