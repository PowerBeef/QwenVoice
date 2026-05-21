import SwiftUI
import QwenVoiceCore

/// Top-level iOS root view. Replaces the legacy `QVoiceiOSRootView`
/// switch-on-tab tree. Reads everything from the injected `AppModel`
/// and owns the global sheet plumbing:
///
/// - Onboarding `fullScreenCover` gated on `AppModel.isOnboardingPresented`.
/// - Player sheet `sheet(item:)` keyed on `AppModel.playerSheetItem`.
/// - Tab routing via `AppModel.tab`.
/// - Custom `TabDock` at the bottom (no native `TabView`; the design
///   uses a mode-tinted glass dock that doesn't fit `Tab` API).
///
/// Each tab still delegates to its current screen container for Phase
/// 2. Phases 3–5 will progressively replace those bodies with the new
/// screens (StudioScreen, VoicesScreen, HistoryScreen, SettingsScreen).
struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        ZStack {
            activeScreen
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(Theme.Brand.gold)
        .overlay {
            if IOSPreviewRuntime.isEnabled {
                IOSPreviewCaptureBridge(
                    selectedTab: appModel.tab,
                    selectedGenerationSection: appModel.studioMode
                )
                .allowsHitTesting(false)
            }
        }
        .environment(\.presentIOSPlayerSheet) { item in
            appModel.playerSheetItem = item
        }
        .fullScreenCover(isPresented: $appModel.isOnboardingPresented) {
            IOSOnboardingFlow(isPresented: $appModel.isOnboardingPresented)
        }
        .sheet(item: $appModel.playerSheetItem) { item in
            IOSPlayerSheet(
                item: item,
                onDismiss: { appModel.playerSheetItem = nil }
            )
            .presentationBackground(Theme.Surface.canvas)
        }
    }

    // MARK: - Tab routing

    @ViewBuilder
    private var activeScreen: some View {
        @Bindable var appModel = appModel

        switch appModel.tab {
        case .studio:
            NavigationStack {
                StudioScreen()
            }
            .toolbar(.hidden, for: .navigationBar)

        case .voices:
            NavigationStack {
                IOSVoicesView(
                    selectedTab: $appModel.tab,
                    onSelectBuiltInSpeaker: { speaker in
                        appModel.customVoiceDraft.selectedSpeaker = speaker.id
                        appModel.studioMode = .custom
                        appModel.tab = .studio
                    },
                    onSelectSavedVoice: { voice in
                        appModel.pendingVoiceCloningHandoff = PendingVoiceCloningHandoff(
                            savedVoiceID: voice.id,
                            wavPath: voice.wavPath,
                            transcript: (try? voice.loadTranscript()) ?? "",
                            transcriptLoadError: nil
                        )
                        appModel.studioMode = .clone
                        appModel.tab = .studio
                    }
                )
            }
            .toolbar(.hidden, for: .navigationBar)

        case .history:
            NavigationStack {
                IOSLibraryContainerView(
                    selectedTab: $appModel.tab,
                    selectedSection: .constant(.history),
                    onUseVoiceInClone: { voice in
                        appModel.pendingVoiceCloningHandoff = PendingVoiceCloningHandoff(
                            savedVoiceID: voice.id,
                            wavPath: voice.wavPath,
                            transcript: (try? voice.loadTranscript()) ?? "",
                            transcriptLoadError: nil
                        )
                        appModel.studioMode = .clone
                        appModel.tab = .studio
                    }
                )
            }
            .toolbar(.hidden, for: .navigationBar)

        case .settings:
            NavigationStack {
                IOSSettingsContainerView(selectedTab: $appModel.tab)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
