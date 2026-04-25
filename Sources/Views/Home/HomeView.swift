import SwiftUI

/// Landing screen — greeting, voice-orb hero, three mode launchers.
/// Recent-takes integration with the history database is a planned
/// follow-up; the placeholder card surfaces the slot today.
@MainActor
struct HomeView: View {
    let onSelectMode: (GenerationMode) -> Void

    @ScaledMetric private var horizontalPadding: CGFloat = 32
    @ScaledMetric private var topPadding: CGFloat = 32
    @ScaledMetric private var verticalSpacing: CGFloat = 28

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: verticalSpacing) {
                heroBlock
                launchersGrid
                recentTakesPlaceholder
                Spacer(minLength: 0)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            .padding(.bottom, 24)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("screen_home")
    }

    private var heroBlock: some View {
        HStack(alignment: .center, spacing: 22) {
            VoiceOrb()

            VStack(alignment: .leading, spacing: 6) {
                Text(greeting)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .tracking(0.2)

                Text("What should we voice today?")
                    .vocelloH1()
            }
        }
    }

    private var launchersGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 14, alignment: .topLeading)],
            spacing: 14
        ) {
            ForEach(GenerationMode.allCases, id: \.self) { mode in
                HomeModeLauncher(mode: mode) {
                    onSelectMode(mode)
                }
            }
        }
    }

    private var recentTakesPlaceholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECENT TAKES")
                .font(.vocelloMicroLabel)
                .tracking(1.4)
                .foregroundStyle(AppTheme.textSecondary)

            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.library)
                    .frame(width: placeholderIconSize, height: placeholderIconSize)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AppTheme.library.opacity(0.18))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your recent takes will appear here")
                        .font(.vocelloFooterTitle)
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("Generate something to start your library.")
                        .font(.vocelloCaption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(placeholderBackground)
        }
    }

    @ScaledMetric private var placeholderIconSize: CGFloat = 36

    private var placeholderBackground: some View {
        let shape = RoundedRectangle(cornerRadius: LayoutConstants.brandCardRadius, style: .continuous)
        return shape
            .fill(AppTheme.cardFill.opacity(0.74))
            .overlay(shape.stroke(AppTheme.cardStroke.opacity(0.4), lineWidth: 0.5))
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Good night"
        }
    }
}

private struct HomeModeLauncher: View {
    let mode: GenerationMode
    let action: () -> Void

    private var tint: Color {
        AppTheme.modeColor(for: mode)
    }

    private var label: String {
        switch mode {
        case .custom: return "Choose Voice"
        case .design: return "Describe Voice"
        case .clone:  return "Use Reference"
        }
    }

    private var sublabel: String {
        switch mode {
        case .custom: return "Built-in speakers"
        case .design: return "Natural-language tone"
        case .clone:  return "From a short audio clip"
        }
    }

    private var iconName: String {
        switch mode {
        case .custom: return "person.wave.2"
        case .design: return "text.bubble"
        case .clone:  return "waveform.badge.plus"
        }
    }

    var body: some View {
        Button(action: action) {
            HomeModeLauncherCard(
                tint: tint,
                iconName: iconName,
                label: label,
                sublabel: sublabel
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: LayoutConstants.brandCardRadius, style: .continuous))
        .accessibilityLabel(label)
        .accessibilityHint(sublabel)
    }
}

private struct HomeModeLauncherCard: View {
    let tint: Color
    let iconName: String
    let label: String
    let sublabel: String

    @ScaledMetric private var iconBadgeSize: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            iconBadge
            textBlock
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(cardBackground)
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.20))
                .frame(width: iconBadgeSize, height: iconBadgeSize)
            Image(systemName: iconName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
        }
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.vocelloLauncherTitle)
                .foregroundStyle(AppTheme.textPrimary)
            Text(sublabel)
                .font(.vocelloCaption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: LayoutConstants.brandCardRadius, style: .continuous)
        return shape
            .fill(tint.opacity(0.10))
            .overlay(shape.stroke(tint.opacity(0.28), lineWidth: 0.75))
    }
}
