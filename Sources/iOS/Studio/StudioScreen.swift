import SwiftUI
import QwenVoiceCore

/// Unified Studio screen.
///
/// Replaces the legacy `IOSGenerateContainerView` as the entry point
/// for the `.studio` tab. Reads everything from the injected
/// `AppModel`; renders the design's flat Studio layout from
/// `design_references/Vocello iOS/studio.jsx`:
///
///   ┌─────────────────────────────┐
///   │ wordmark + memory chip      │  ← shell canopy
///   │ ModeSegmented               │
///   │ per-mode body (IOSStudioCanvas)
///   │   composer                  │
///   │   setup chips               │
///   │   dock area (CTA / gen / player)
///   └─────────────────────────────┘
///
/// Phase 3a — keeps the existing per-mode views (`IOSCustomVoiceView`,
/// `IOSVoiceDesignView`, `IOSVoiceCloningView`) as the owners of the
/// generation lifecycle. They render `IOSStudioCanvas` internally with
/// the right chip configuration. Future work (Phase 3b) extracts the
/// generation state into an `@Observable StudioGenerationCoordinator`
/// so the per-mode views collapse into a single `StudioBody`.
///
/// The memory indicator, prefetch coordinator, and engine signposts
/// continue to live behind `IOSStudioShellScreen` for now — the shell
/// gives us the canopy + the engine-lifecycle toast + the now-playing
/// rail without re-implementing them here. That layer retires in
/// Phase 6 once the new TabDock owns the bottom chrome.
struct StudioScreen: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        IOSGenerateContainerView(
            selectedTab: $appModel.tab,
            isTabActive: true,
            selectedSection: $appModel.studioMode,
            customVoiceDraft: $appModel.customVoiceDraft,
            voiceDesignDraft: $appModel.voiceDesignDraft,
            voiceCloningDraft: $appModel.voiceCloningDraft,
            pendingVoiceCloningHandoff: $appModel.pendingVoiceCloningHandoff,
            customPrimaryAction: $appModel.customPrimaryAction,
            designPrimaryAction: $appModel.designPrimaryAction,
            clonePrimaryAction: $appModel.clonePrimaryAction
        )
    }
}
