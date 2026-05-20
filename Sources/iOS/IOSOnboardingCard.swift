import SwiftUI

struct IOSFirstRunOnboardingCard: View {
    @Binding var selectedTab: IOSAppTab

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(IOSBrandTheme.accent)
                Text("Install your first voice")
                    .font(IOSTypeStyle.cardTitle.font)
                    .foregroundStyle(IOSAppTheme.textPrimary)
            }

            Text("Open Settings to download a Custom Voice, Voice Design, or Voice Cloning model. Speed packages are ~2.3 GB each and run on-device.")
                .font(IOSTypeStyle.body.font)
                .foregroundStyle(IOSAppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                IOSHaptics.selection()
                selectedTab = .settings
            } label: {
                Label("Open Settings", systemImage: "arrow.right.circle.fill")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(IOSBrandTheme.accent)
            .accessibilityIdentifier("onboarding_openSettings")
        }
        .padding(16)
        // Neutral surface — gold appears on the CTA only. Mirrors macOS
        // "warm without volume" pattern (PRODUCT.md design principle 5).
        .iosSubtleGlassSurface(
            in: RoundedRectangle(cornerRadius: 16, style: .continuous),
            tint: nil
        )
        .accessibilityIdentifier("onboarding_firstRunCard")
    }
}
