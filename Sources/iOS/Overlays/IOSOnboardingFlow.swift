import SwiftUI

/// Full-screen first-run onboarding from the Claude Design prototype
/// (design_references/Vocello iOS/screens.jsx Onboarding). Three pages:
/// Welcome → Install pointer → Open Studio. Informational only; the actual
/// model install happens later in Settings via the existing
/// IOSModelInstallSheet flow so onboarding stays focused on framing.
///
/// Wired in QVoiceiOSRootView as a `.fullScreenCover` gated on
/// `IOSAppDefaults.hasCompletedOnboarding`.
struct IOSOnboardingFlow: View {
    @Binding var isPresented: Bool

    @State private var page: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let totalPages = 3

    var body: some View {
        ZStack {
            IOSModeBackdrop(tint: IOSBrandTheme.accent, intensity: .warm)

            VStack(spacing: 0) {
                topBar
                pages
                pagination
                ctaButton
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            IOSProductTitleLockup(title: IOSBrandTheme.productName)

            Spacer()

            if page < totalPages - 1 {
                Button("Skip") {
                    complete()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(IOSAppTheme.textSecondary)
                .buttonStyle(.plain)
                .accessibilityIdentifier("onboarding_skip")
            }
        }
        .frame(height: 44)
        .padding(.top, 12)
    }

    // MARK: - Pages

    @ViewBuilder
    private var pages: some View {
        Group {
            switch page {
            case 0:
                IOSOnboardingWelcomePage()
            case 1:
                IOSOnboardingInstallPage()
            default:
                IOSOnboardingReadyPage()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .transition(.opacity)
        .iosAppAnimation(IOSDesignMotion.sheetReveal, value: page)
    }

    // MARK: - Pagination dots

    private var pagination: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalPages, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(i == page ? IOSBrandTheme.accent : IOSAppTheme.textTertiary.opacity(0.4))
                    .frame(width: i == page ? 20 : 6, height: 6)
                    .iosAppAnimation(IOSDesignMotion.stateChange, value: page)
            }
        }
        .padding(.bottom, 24)
        .accessibilityElement()
        .accessibilityLabel("Page \(page + 1) of \(totalPages)")
    }

    // MARK: - CTA

    private var ctaButton: some View {
        IOSPrimaryCTAButton(
            title: ctaTitle,
            tint: IOSBrandTheme.accent,
            isEnabled: true,
            action: handleCTA
        )
        .accessibilityIdentifier("onboarding_cta")
    }

    private var ctaTitle: String {
        switch page {
        case 0: return "Get started"
        case 1: return "Continue"
        default: return "Open Studio"
        }
    }

    private func handleCTA() {
        IOSHaptics.impact(.light)
        if page < totalPages - 1 {
            withAnimation(IOSDesignMotion.sheetReveal) {
                page += 1
            }
        } else {
            complete()
        }
    }

    private func complete() {
        IOSAppDefaults.hasCompletedOnboarding = true
        IOSHaptics.success()
        withAnimation(IOSDesignMotion.sheetSlideUp) {
            isPresented = false
        }
    }
}

// MARK: - Page 1: Welcome

private struct IOSOnboardingWelcomePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Welcome to Vocello")
                    .font(.system(.largeTitle, design: .default, weight: .bold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .multilineTextAlignment(.leading)

                Text("Your voice studio that runs entirely on this iPhone.")
                    .font(.body)
                    .foregroundStyle(IOSAppTheme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 16) {
                IOSOnboardingBenefitRow(
                    symbol: "lock.shield",
                    title: "Private by design",
                    detail: "Audio stays on this iPhone. No accounts, no uploads."
                )
                IOSOnboardingBenefitRow(
                    symbol: "iphone.gen3",
                    title: "On-device generation",
                    detail: "Apple Neural Engine renders the voice locally."
                )
                IOSOnboardingBenefitRow(
                    symbol: "waveform.path.ecg",
                    title: "Three workflows",
                    detail: "Custom voices, voice design from a brief, or cloning from a clip."
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Page 2: Install

private struct IOSOnboardingInstallPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Install a voice model")
                    .font(.system(.largeTitle, design: .default, weight: .bold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .multilineTextAlignment(.leading)

                Text("Vocello downloads one of three voice models on first use. They live in the Settings tab. Each model is roughly 1.7 GB and lands once.")
                    .font(.body)
                    .foregroundStyle(IOSAppTheme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                IOSOnboardingModelHint(
                    tint: IOSBrandTheme.custom,
                    name: "Custom Voice",
                    detail: "Pick from 12 built-in speakers. Best for narration."
                )
                IOSOnboardingModelHint(
                    tint: IOSBrandTheme.design,
                    name: "Voice Design",
                    detail: "Describe a voice in a sentence and generate."
                )
                IOSOnboardingModelHint(
                    tint: IOSBrandTheme.clone,
                    name: "Voice Cloning",
                    detail: "Save voices from a short reference clip you own."
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Page 3: Ready

private struct IOSOnboardingReadyPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text("You're set.")
                    .font(.system(.largeTitle, design: .default, weight: .bold))
                    .foregroundStyle(IOSAppTheme.textPrimary)

                Text("Type a line in Studio, pick a voice or describe one, and tap Generate. Saved takes live in History and Voices.")
                    .font(.body)
                    .foregroundStyle(IOSAppTheme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Visual: stacked waveform bars in three mode tints.
            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { i in
                    let tint: Color = {
                        switch i {
                        case 0: return IOSBrandTheme.custom
                        case 1: return IOSBrandTheme.design
                        default: return IOSBrandTheme.clone
                        }
                    }()
                    IOSWaveformBars(
                        seed: 42 + i,
                        barCount: 18,
                        tint: tint,
                        progress: 1.0,
                        isAnimating: false
                    )
                    .frame(height: 64)
                    .padding(12)
                    .background {
                        RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                            .fill(IOSAppTheme.glassSurfaceFillMuted.opacity(0.5))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                            .stroke(tint.opacity(0.32), lineWidth: 0.9)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Reusable rows

private struct IOSOnboardingBenefitRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(IOSBrandTheme.accent.opacity(0.18))
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(IOSBrandTheme.accent)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(IOSAppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct IOSOnboardingModelHint: View {
    let tint: Color
    let name: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill(tint.opacity(0.6))
                .frame(width: 10, height: 10)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(IOSAppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
