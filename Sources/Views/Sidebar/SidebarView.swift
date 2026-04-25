import SwiftUI
import QwenVoiceNative

/// Compact Vocello brand lockup pinned to the top of the sidebar.
/// Pairs the V monogram (drawn in `VocelloVMark`) with the Cormorant
/// wordmark + small AI-TTS micro-tag, matching the iOS reference's
/// `VHeader`. Lives in `safeAreaInset(edge: .top)` so it stays anchored.
private struct SidebarBrandHeader: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VocelloVMark(size: 24)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 3 }

            Text("Vocello")
                .vocelloWordmark()

            Text("AI-TTS")
                .font(.vocelloMicroLabel)
                .tracking(0.6)
                .foregroundStyle(AppTheme.textSecondary.opacity(0.55))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(minHeight: LayoutConstants.sidebarBrandHeaderHeight, alignment: .leading)
        .accessibilityHidden(true)
    }
}

private struct SidebarSectionRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let section: SidebarSection
    @Binding var selection: SidebarSection?
    let isDisabled: Bool
    @State private var isHovered = false

    private var isSelected: Bool { selection == section }

    private var iconColor: Color {
        if isDisabled { return Color.secondary.opacity(isSelected ? 0.8 : 0.6) }
        return isSelected ? section.sidebarTint : AppTheme.textPrimary
    }

    private var textColor: Color {
        if isDisabled { return Color.secondary.opacity(isSelected ? 0.88 : 0.72) }
        return AppTheme.textPrimary
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(section.sidebarTint.opacity(colorScheme == .dark ? 0.16 : 0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            section.sidebarTint.opacity(colorScheme == .dark ? 0.55 : 0.42),
                            lineWidth: 0.75
                        )
                )
        } else if isHovered {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.sidebarHoverFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            AppTheme.sidebarHoverStroke.opacity(colorScheme == .dark ? 0.85 : 0.50),
                            lineWidth: 0.5
                        )
                )
        } else {
            Color.clear
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.iconName)
                .font(.body.weight(isSelected ? .semibold : .regular))
                .imageScale(.large)
                .foregroundStyle(iconColor)
                .frame(width: 22, alignment: .center)

            Text(section.rawValue)
                .font(.vocelloSidebarRow(active: isSelected))
                .foregroundStyle(textColor)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 36)
        .background(rowBackground)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            guard !isDisabled else { return }
            selection = section
        }
        .onHover { hovering in
            isHovered = isDisabled ? false : hovering
        }
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .disabled(isDisabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(section.rawValue)
        .accessibilityValue(isSelected ? "selected" : "not selected")
        .accessibilityIdentifier(section.accessibilityID)
    }
}

struct SidebarView: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel

    @Binding var selectedSection: SidebarSection?
    let disabledSections: Set<SidebarSection>

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedSection) {
                ForEach(SidebarSection.allCases) { section in
                    SidebarSectionRow(
                        section: section,
                        selection: $selectedSection,
                        isDisabled: disabledSections.contains(section)
                    )
                    .tag(section as SidebarSection?)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .vocelloGlassRail()
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarBrandHeader()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooterStatus()
        }
    }
}

/// Memory/health status pill at the bottom of the sidebar — the
/// take-player chrome moved to the global window-footer player so this
/// region only carries runtime telemetry now.
private struct SidebarFooterStatus: View {
    @EnvironmentObject private var ttsEngineStore: TTSEngineStore
    @Environment(\.colorScheme) private var colorScheme

    private let appEngineSelection = AppEngineSelection.current()

    private var resolvedSidebarStatus: SidebarStatus {
        appEngineSelection.resolveSidebarStatus(
            ttsEngineSnapshot: ttsEngineStore.snapshot,
            prefersInlinePresentation: false
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(AppTheme.railStroke.opacity(colorScheme == .dark ? 0.85 : 0.30))
                .frame(height: 0.5)

            SidebarStatusView(
                sidebarStatus: resolvedSidebarStatus,
                clearError: {
                    appEngineSelection.clearSidebarError(ttsEngineStore: ttsEngineStore)
                }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppTheme.railBackground.opacity(colorScheme == .dark ? 0.92 : 0.985))
    }
}
