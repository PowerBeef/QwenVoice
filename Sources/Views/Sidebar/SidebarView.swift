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
    @State private var isHovered = false

    private var isSelected: Bool {
        selection == item
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(backgroundColor)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isSelected || isHovered ? 1 : 0)
            }
    }

    private var backgroundColor: Color {
        if isSelected {
            return .accentColor.opacity(0.12)
        }

        if isHovered {
            return Color.primary.opacity(0.05)
        }

        return .clear
    }

    private var borderColor: Color {
        if isSelected {
            return .accentColor.opacity(0.24)
        }

        if isHovered {
            return Color.primary.opacity(0.08)
        }

        return .clear
    }

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(isSelected ? Color.accentColor : .clear)
                .frame(width: 3, height: 16)

            Image(systemName: item.iconName)
                .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .frame(width: 22, alignment: .center)

            Text(item.rawValue)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(Color.primary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(rowBackground)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                selection = item
            }
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .animation(.easeOut(duration: 0.14), value: isSelected)
            .accessibilityValue(selection == item ? "selected" : "not selected")
            .accessibilityIdentifier(item.accessibilityID)
    }
}

struct SidebarView: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel

    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarItem.Section.allCases, id: \.self) { section in
                Section {
                    ForEach(section.items) { item in
                        SidebarRow(item: item, selection: $selection)
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
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            SidebarFooterRegion()
                .environmentObject(audioPlayer)
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
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
