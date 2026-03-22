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
                    .fill(.clear)
                    .glassEffect(.regular.tint(.accentColor).interactive(), in: .rect(cornerRadius: 8))
            } else if isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
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
            return .accentColor.opacity(0.08)
        }

        if isHovered {
            return Color.primary.opacity(0.04)
        }

        return .clear
    }

    private var borderColor: Color {
        if isDisabled {
            return isSelected ? Color.secondary.opacity(0.16) : .clear
        }

        if isSelected {
            return .accentColor.opacity(0.24)
        }

        if isHovered {
            return Color.primary.opacity(0.08)
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
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
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
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                if audioPlayer.hasAudio {
                    SidebarPlayerView()
                    Divider()
                }

                SidebarStatusView()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .profileBackground(Color(nsColor: .windowBackgroundColor))
    }
}
