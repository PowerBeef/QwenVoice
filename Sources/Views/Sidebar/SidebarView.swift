import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @EnvironmentObject var pythonBridge: PythonBridge

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarItem.Section.allCases, id: \.self) { section in
                Section {
                    ForEach(section.items) { item in
                        let isSelected = selection == item
                        Label {
                            Text(item.rawValue)
                                .foregroundStyle(isSelected ? AppTheme.accent : .primary)
                        } icon: {
                            Image(systemName: item.iconName)
                                .foregroundStyle(isSelected ? AppTheme.accent : .secondary)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .tag(item)
                        .accessibilityIdentifier(item.accessibilityID)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? AppTheme.accent.opacity(0.15) : Color.clear)
                                .padding(.horizontal, 4)
                        )
                    }
                } header: {
                    Text(section.rawValue)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.8)
                }
            }
        }
        .listStyle(.sidebar)
        .tint(AppTheme.accent)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 280)
        .scrollContentBackground(.hidden)
        .background(
            Material.thinMaterial
        )
        .task {
            // Give the sidebar focus on launch so macOS shows the
            // accent-colored selection instead of grey
            try? await Task.sleep(for: .milliseconds(300))
            if let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                func findOutlineView(_ view: NSView) -> NSOutlineView? {
                    if let ov = view as? NSOutlineView { return ov }
                    return view.subviews.lazy.compactMap { findOutlineView($0) }.first
                }
                if let contentView = window.contentView,
                   let outlineView = findOutlineView(contentView) {
                    outlineView.selectionHighlightStyle = .none
                    window.makeFirstResponder(outlineView)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Backend status indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(pythonBridge.isReady ? .green : .orange)
                    .frame(width: 8, height: 8)
                    .shadow(color: pythonBridge.isReady ? .green.opacity(0.5) : .orange.opacity(0.5), radius: 4)
                Text(pythonBridge.isReady ? "Backend Ready" : "Starting...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("sidebar_backendStatus")
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill((pythonBridge.isReady ? Color.green : Color.orange).opacity(0.1))
                    .overlay(
                         RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder((pythonBridge.isReady ? Color.green : Color.orange).opacity(0.2), lineWidth: 1)
                    )
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }
}
