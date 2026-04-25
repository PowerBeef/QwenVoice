import SwiftUI

/// Host view for the Library section. Owns the brand H1, the
/// History/Voices segmented control, and the routing into the per-tab
/// views.
@MainActor
struct LibraryView: View {
    @Binding var tab: LibraryTab
    @Binding var historySearchText: String
    @Binding var historySortOrder: HistorySortOrder
    let voicesEnrollRequestID: UUID?
    let canUseSavedVoicesInVoiceCloning: Bool
    let onUseInVoiceCloning: (Voice) -> Void

    private var tabSegments: [VocelloSegmentedControl<LibraryTab>.Segment] {
        [
            .init(value: .history, label: "History", tint: AppTheme.library, accessibilityIdentifier: "library_tab_history"),
            .init(value: .voices,  label: "Voices",  tint: AppTheme.library, accessibilityIdentifier: "library_tab_voices"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Library")
                    .vocelloH1()

                VocelloSegmentedControl(
                    segments: tabSegments,
                    selection: $tab
                )
                .frame(maxWidth: 360, alignment: .leading)
                .accessibilityIdentifier("library_tabSegmented")
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("screen_library")
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .history:
            HistoryView(
                searchText: $historySearchText,
                sortOrder: $historySortOrder
            )
            .accessibilityIdentifier("screen_history")
        case .voices:
            VoicesView(
                enrollRequestID: voicesEnrollRequestID,
                canUseInVoiceCloning: canUseSavedVoicesInVoiceCloning,
                onUseInVoiceCloning: onUseInVoiceCloning
            )
            .accessibilityIdentifier("screen_voices")
        }
    }
}
