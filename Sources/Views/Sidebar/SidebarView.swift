import SwiftUI

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
                                AppTheme.sidebarSelectionStroke.opacity(colorScheme == .dark ? 1.0 : 0.78),
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
            return AppTheme.sidebarSelectionStroke
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

        return isSelected ? Color.accentColor : Color.primary
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

        return isDisabled ? Color.secondary.opacity(0.6) : Color.accentColor
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
    @EnvironmentObject private var pythonBridge: PythonBridge

    private var footerPresentation: SidebarFooterPresentation {
        SidebarFooterPresentation.resolve(
            sidebarStatus: pythonBridge.sidebarStatus,
            isLiveStream: audioPlayer.isLiveStream
        )
    }

    private func syncUITestFooterState() {
        guard UITestAutomationSupport.isEnabled else { return }
        TestStateProvider.shared.setSidebarFooter(
            inlineStatusVisible: footerPresentation.inlinePlayerActivity != nil,
            standaloneStatusVisible: footerPresentation.showsStandaloneStatus
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
                    SidebarStatusView()
                }
            }
            .padding(.horizontal, LayoutConstants.shellPadding)
            .padding(.top, LayoutConstants.generationSectionSpacing)
            .padding(.bottom, LayoutConstants.shellPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppTheme.railBackground.opacity(colorScheme == .dark ? 1.0 : 0.985))
        .onAppear(perform: syncUITestFooterState)
        .onChange(of: pythonBridge.sidebarStatus) { _, _ in syncUITestFooterState() }
        .onChange(of: audioPlayer.isLiveStream) { _, _ in syncUITestFooterState() }
    }
}
