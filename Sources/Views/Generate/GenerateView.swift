import SwiftUI
import QwenVoiceNative

/// Host view for the Generate section. Owns the brand H1, the mode
/// segmented control, and the routing into the per-mode views
/// (CustomVoice / VoiceDesign / VoiceCloning).
///
/// State is passed through from `ContentView` so generation drafts,
/// activation counters, and pending handoffs persist across mode swaps.
@MainActor
struct GenerateView: View {
    @Binding var mode: GenerationMode

    @Binding var customVoiceDraft: CustomVoiceDraft
    @Binding var voiceDesignDraft: VoiceDesignDraft
    @Binding var voiceCloningDraft: VoiceCloningDraft
    @Binding var pendingVoiceCloningHandoff: PendingVoiceCloningHandoff?

    let customVoiceActivationID: Int
    let voiceDesignActivationID: Int
    let voiceCloningActivationID: Int

    let ttsEngineStore: TTSEngineStore
    let audioPlayer: AudioPlayerViewModel
    let modelManager: ModelManagerViewModel
    let savedVoicesViewModel: SavedVoicesViewModel
    let appCommandRouter: AppCommandRouter

    private var modeSegments: [VocelloSegmentedControl<GenerationMode>.Segment] {
        [
            .init(value: .custom, label: "Custom", tint: AppTheme.customVoice, accessibilityIdentifier: "generate_tab_custom"),
            .init(value: .design, label: "Design", tint: AppTheme.voiceDesign, accessibilityIdentifier: "generate_tab_design"),
            .init(value: .clone,  label: "Clone",  tint: AppTheme.voiceCloning, accessibilityIdentifier: "generate_tab_clone"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Generate")
                    .vocelloH1()

                VocelloSegmentedControl(
                    segments: modeSegments,
                    selection: $mode
                )
                .frame(maxWidth: 540, alignment: .leading)
                .accessibilityIdentifier("generate_modeSegmented")
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)

            modeContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("screen_generate")
    }

    @ViewBuilder
    private var modeContent: some View {
        switch mode {
        case .custom:
            CustomVoiceView(
                draft: $customVoiceDraft,
                activationID: customVoiceActivationID,
                ttsEngineStore: ttsEngineStore,
                audioPlayer: audioPlayer,
                modelManager: modelManager,
                appCommandRouter: appCommandRouter
            )
            .accessibilityIdentifier("screen_customVoice")
        case .design:
            VoiceDesignView(
                draft: $voiceDesignDraft,
                activationID: voiceDesignActivationID,
                ttsEngineStore: ttsEngineStore,
                audioPlayer: audioPlayer,
                modelManager: modelManager,
                savedVoicesViewModel: savedVoicesViewModel,
                appCommandRouter: appCommandRouter
            )
            .accessibilityIdentifier("screen_voiceDesign")
        case .clone:
            VoiceCloningView(
                draft: $voiceCloningDraft,
                pendingSavedVoiceHandoff: $pendingVoiceCloningHandoff,
                activationID: voiceCloningActivationID,
                ttsEngineStore: ttsEngineStore,
                audioPlayer: audioPlayer,
                modelManager: modelManager,
                savedVoicesViewModel: savedVoicesViewModel,
                appCommandRouter: appCommandRouter
            )
            .accessibilityIdentifier("screen_voiceCloning")
        }
    }
}
