import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @EnvironmentObject var pythonBridge: PythonBridge

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarItem.Section.allCases, id: \.self) { section in
                Section(section.rawValue) {
                    ForEach(section.items) { item in
                        Label(item.rawValue, systemImage: item.iconName)
                            .tag(item)
                            .accessibilityIdentifier(item.accessibilityID)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        .safeAreaInset(edge: .bottom) {
            // Backend status indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(pythonBridge.isReady ? .green : .orange)
                    .frame(width: 8, height: 8)
                Text(pythonBridge.isReady ? "Backend Ready" : "Starting...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("sidebar_backendStatus")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
