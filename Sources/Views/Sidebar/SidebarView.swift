import SwiftUI

private struct SidebarNavigationRow: View {
    let item: SidebarItem
    let isSelected: Bool
    let action: () -> Void

    private var color: Color {
        AppTheme.sidebarColor(for: item)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: item.iconName)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 22)
                    .foregroundStyle(isSelected ? color : .secondary)

                Text(item.rawValue)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? color : .primary.opacity(0.86))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? color.opacity(0.18) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(item.accessibilityID)
        .accessibilityValue(isSelected ? "selected" : "not selected")
    }
}

private struct SidebarSectionView: View {
    let section: SidebarItem.Section
    @Binding var selection: SidebarItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.rawValue.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)

            VStack(spacing: 8) {
                ForEach(section.items) { item in
                    SidebarNavigationRow(item: item, isSelected: selection == item) {
                        AppLaunchConfiguration.performAnimated(.spring(response: 0.26, dampingFraction: 0.82)) {
                            selection = item
                        }
                    }
                }
            }
        }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(AppTheme.accent.opacity(0.16))
                            .frame(width: 34, height: 34)

                        Image(systemName: "waveform")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(AppTheme.accent)
                    }

                    Text("QwenVoice")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)

                ForEach(SidebarItem.Section.allCases, id: \.self) { section in
                    SidebarSectionView(section: section, selection: $selection)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Spacer(minLength: 20)

            VStack(spacing: 10) {
                SidebarPlayerView()
                    .appAnimation(.easeInOut(duration: 0.25), value: audioPlayer.hasAudio)

                SidebarStatusView()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: LayoutConstants.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(AppTheme.railStroke, lineWidth: 1)
                }
                .padding(.leading, 8)
                .padding(.top, 10)
                .padding(.bottom, 10)
        }
        .padding(.vertical, 6)
        .onAppear {
            if selection == nil {
                selection = .customVoice
            }
        }
    }
}
