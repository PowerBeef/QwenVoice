import SwiftUI

/// Bottom sheet that lets the user edit the Voice Design brief, replacing
/// the legacy inline `IOSVoiceDesignSetupCard` editor. Multi-line text
/// editor + a Done button. Caller binds to the brief string; the sheet
/// dismisses on Done.
///
/// Per design_references/Vocello iOS/sheets.jsx (DesignBriefSheet pattern).
struct IOSVoiceDesignBriefSheet: View {
    @Binding var voiceDescription: String
    let tint: Color

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        IOSBottomSheet(title: "Voice brief", tint: tint) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Describe the voice in your own words. A sentence is enough. The model uses this brief to pick timbre, accent, pacing, and warmth.")
                    .font(.subheadline)
                    .foregroundStyle(IOSAppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)

                TextEditor(text: $voiceDescription)
                    .focused($isFocused)
                    .font(.body)
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 140)
                    .background {
                        RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                            .fill(IOSAppTheme.glassSurfaceFillMuted.opacity(0.62))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                            .stroke(isFocused ? tint.opacity(0.34) : Color.white.opacity(0.10), lineWidth: 0.9)
                    }
                    .padding(.horizontal, 20)

                IOSPrimaryCTAButton(
                    title: "Done",
                    symbol: "checkmark",
                    tint: tint,
                    isEnabled: true,
                    action: { dismiss() }
                )
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 24)
        }
        .onAppear { isFocused = true }
    }
}
