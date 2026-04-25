import SwiftUI

/// Host view for the Settings section. Owns the brand H1 and embeds the
/// Models tab. Preferences continues to live in the system Settings scene
/// opened via Cmd+,; integrating it as an in-pane segmented tab is a
/// follow-up to this brand-refresh refactor.
@MainActor
struct SettingsView: View {
    @Binding var tab: SettingsTab
    @Binding var pendingHighlightedModelID: String?

    @ScaledMetric private var horizontalInset: CGFloat = 28
    @ScaledMetric private var topInset: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .vocelloH1()
                .padding(.horizontal, horizontalInset)
                .padding(.top, topInset)

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("screen_settings")
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .models, .preferences:
            ModelsView(highlightedModelID: $pendingHighlightedModelID)
                .accessibilityIdentifier("screen_models")
        }
    }
}
