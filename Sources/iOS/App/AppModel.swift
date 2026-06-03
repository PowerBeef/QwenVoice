import Foundation
import Observation
import SwiftUI
import QwenVoiceCore

struct IOSDeleteModelSheetPresentation: Identifiable {
    let id = UUID()
    let modelName: String
    let sizeLabel: String
    let onConfirm: @MainActor () -> Void
}

struct IOSBottomPanelPresentation: Identifiable {
    let id: String
    let content: @MainActor (_ bottomSafeAreaInset: CGFloat, _ availableHeight: CGFloat, _ dismiss: @escaping @MainActor () -> Void) -> AnyView

    init(
        id: String = UUID().uuidString,
        content: @escaping @MainActor (_ bottomSafeAreaInset: CGFloat, _ availableHeight: CGFloat, _ dismiss: @escaping @MainActor () -> Void) -> AnyView
    ) {
        self.id = id
        self.content = content
    }
}

/// Root state model for the iOS app, replacing the bag of `@State`
/// properties that lived inside `QVoiceiOSRootView`. Conformant to
/// `Observable` so views read state via `@Environment(AppModel.self)`
/// or `@Bindable` rather than the legacy `@StateObject` /
/// `@ObservableObject` / `@Published` triplet.
///
/// Per `references/state-management.md`: prefer `@Observable` over
/// `ObservableObject` on iOS 17+, and pair with `@Bindable` when a child
/// view needs to write back. Anything passed by value stays a `let`.
///
/// Phases that consume this model:
/// - Phase 2 (this one): tab, studioMode, drafts, onboarding gate,
///   player sheet item. Existing screen containers still own the
///   downstream flows; AppModel is the new source of truth for the
///   pieces shared across them.
/// - Phase 3: per-mode generation state (`StudioGenerationCoordinator`)
///   becomes an Observable property here.
/// - Phase 5: sheet presentation state (delivery / voice / reference /
///   model install / delete model) collapses into one
///   `presentedSheet` enum on this model.
@MainActor
@Observable
final class AppModel {
    // MARK: - Routing

    /// The bottom-tab destination currently visible. Defaults to Studio.
    var tab: IOSAppTab = .studio

    /// Which mode the unified Studio screen is currently editing.
    /// Mirrors the legacy `IOSGenerationSection`; the enum stays
    /// because `TTSContract` keyed against it.
    var studioMode: IOSGenerationSection = .custom

    // MARK: - Drafts

    /// Built-in-speaker generation draft (Custom mode).
    var customVoiceDraft: CustomVoiceDraft

    /// Brief-driven generation draft (Voice Design mode).
    var voiceDesignDraft = VoiceDesignDraft()

    /// Reference-clip clone draft (Voice Cloning mode).
    var voiceCloningDraft = VoiceCloningDraft()

    /// Pending hand-off from Voices tap → Studio Clone mode. The
    /// existing IOSVoiceCloningView consumes this via a binding.
    var pendingVoiceCloningHandoff: PendingVoiceCloningHandoff?

    // MARK: - Onboarding

    /// True until the user dismisses the first-run flow. Initialized
    /// from the persisted `IOSAppDefaults.hasCompletedOnboarding` flag.
    var isOnboardingPresented: Bool

    // MARK: - Global Player sheet

    /// When set, the root view presents the full-screen Player sheet.
    /// History row taps, Voices preview, and Studio inline-player
    /// expansion all set this.
    var playerSheetItem: IOSPlayerSheetItem?

    /// Edge-to-edge model-delete confirmation, hosted by `RootView` so it
    /// can fill the screen bottom instead of inheriting system sheet insets.
    var deleteModelSheetItem: IOSDeleteModelSheetPresentation?

    /// Edge-to-edge bottom panel used by Studio and Settings sheets that
    /// need the reference backdrop + liquid-glass bottom surface.
    var bottomPanelItem: IOSBottomPanelPresentation?

    // MARK: - Modal backdrop

    /// True while a native bottom sheet wants the app chrome behind it
    /// blurred/dimmed, matching the reference backdrop-filter focus layer.
    var isFocusBackdropPresented: Bool = false

    // MARK: - Studio generation coordinators (Phase 3b)

    /// Per-mode generation lifecycle. Per-mode views read state via
    /// `appModel.coordinator(for: .custom)` instead of holding their
    /// own scattered `@State` for `isGenerating`, `errorMessage`, and
    /// `lastCompletedOutput`. The actual engine call (`ttsEngine.generate`)
    /// still lives in the view body because it has to assemble
    /// mode-specific payloads from drafts + speakers + delivery.
    let customCoordinator = StudioGenerationCoordinator(mode: .custom)
    let designCoordinator = StudioGenerationCoordinator(mode: .design)
    let cloneCoordinator = StudioGenerationCoordinator(mode: .clone)

    func coordinator(for mode: GenerationMode) -> StudioGenerationCoordinator {
        switch mode {
        case .custom: return customCoordinator
        case .design: return designCoordinator
        case .clone: return cloneCoordinator
        }
    }

    func presentBottomPanel(
        id: String = UUID().uuidString,
        content: @escaping @MainActor (_ bottomSafeAreaInset: CGFloat, _ availableHeight: CGFloat, _ dismiss: @escaping @MainActor () -> Void) -> AnyView
    ) {
        isFocusBackdropPresented = true
        bottomPanelItem = IOSBottomPanelPresentation(id: id, content: content)
    }

    func dismissBottomPanel() {
        bottomPanelItem = nil
        isFocusBackdropPresented = false
    }

    // MARK: - Init

    init(modelRegistry: ContractBackedModelRegistry) {
        self.customVoiceDraft = CustomVoiceDraft(selectedSpeaker: modelRegistry.defaultSpeaker.id)
        self.isOnboardingPresented = !IOSAppDefaults.hasCompletedOnboarding

#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let seededCustomText = environment["QVOICE_IOS_TEST_CUSTOM_TEXT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !seededCustomText.isEmpty {
            self.customVoiceDraft.text = IOSGenerationTextLimitPolicy.clamped(
                seededCustomText,
                mode: .custom
            )
        }
        if environment["QVOICE_IOS_SKIP_ONBOARDING"] == "1" {
            self.isOnboardingPresented = false
        }
#endif

        // Honor preview-runtime overrides for design-time previews.
        if let preview = IOSPreviewRuntime.current?.definition.initialState {
            self.tab = preview.selectedTab
            self.studioMode = preview.selectedGenerationSection
            self.customVoiceDraft = preview.customDraft
            self.voiceDesignDraft = preview.designDraft
            self.voiceCloningDraft = preview.cloneDraft
        }
    }
}

// Injection: `WindowGroup { RootView().environment(appModel) }` at the
// app entry. Consumers read with `@Environment(AppModel.self) private
// var appModel` — no key-path environment value needed.
