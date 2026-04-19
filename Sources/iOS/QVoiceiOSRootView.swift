import SwiftUI
import QwenVoiceCore

struct QVoiceiOSRootView: View {
    let modelRegistry: ContractBackedModelRegistry

    @State private var selectedTab: IOSAppTab = .generate
    @State private var selectedLibrarySection: IOSLibrarySection = .history
    @State private var selectedGenerationSection: IOSGenerationSection = .custom
    @State private var customVoiceDraft: CustomVoiceDraft
    @State private var voiceDesignDraft = VoiceDesignDraft()
    @State private var voiceCloningDraft = VoiceCloningDraft()
    @State private var pendingVoiceCloningHandoff: PendingVoiceCloningHandoff?
    @State private var customPrimaryAction = IOSGeneratePrimaryActionDescriptor.placeholder(for: .custom)
    @State private var designPrimaryAction = IOSGeneratePrimaryActionDescriptor.placeholder(for: .design)
    @State private var clonePrimaryAction = IOSGeneratePrimaryActionDescriptor.placeholder(for: .clone)

    init(modelRegistry: ContractBackedModelRegistry) {
        self.modelRegistry = modelRegistry
        let uiTestOverrides = IOSUITestGenerationOverrides.current
        let previewInitialState = IOSPreviewRuntime.current?.definition.initialState

        var customDraft = CustomVoiceDraft(selectedSpeaker: modelRegistry.defaultSpeaker.id)
        if let previewCustomDraft = previewInitialState?.customDraft {
            customDraft = previewCustomDraft
        } else if uiTestOverrides.selectedSection == .custom, let scriptText = uiTestOverrides.scriptText {
            customDraft.text = IOSGenerationTextLimitPolicy.clamped(scriptText, mode: .custom)
        }

        var designDraft = VoiceDesignDraft()
        if let previewDesignDraft = previewInitialState?.designDraft {
            designDraft = previewDesignDraft
        } else if uiTestOverrides.selectedSection == .design {
            if let scriptText = uiTestOverrides.scriptText {
                designDraft.text = IOSGenerationTextLimitPolicy.clamped(scriptText, mode: .design)
            }
            if let voiceDesignBrief = uiTestOverrides.voiceDesignBrief {
                designDraft.voiceDescription = voiceDesignBrief
            }
        }

        var cloneDraft = VoiceCloningDraft()
        if let previewCloneDraft = previewInitialState?.cloneDraft {
            cloneDraft = previewCloneDraft
        } else if uiTestOverrides.selectedSection == .clone, let scriptText = uiTestOverrides.scriptText {
            cloneDraft.text = IOSGenerationTextLimitPolicy.clamped(scriptText, mode: .clone)
        }

        _selectedTab = State(initialValue: previewInitialState?.selectedTab ?? .generate)
        _selectedGenerationSection = State(
            initialValue: previewInitialState?.selectedGenerationSection ?? uiTestOverrides.selectedSection ?? .custom
        )
        _customVoiceDraft = State(initialValue: customDraft)
        _voiceDesignDraft = State(initialValue: designDraft)
        _voiceCloningDraft = State(initialValue: cloneDraft)
    }

    var body: some View {
        ZStack {
            activeRootScreen
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(IOSBrandTheme.accent)
        .overlay {
            if IOSPreviewRuntime.isEnabled {
                IOSPreviewCaptureBridge(
                    selectedTab: selectedTab,
                    selectedGenerationSection: selectedGenerationSection
                )
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var activeRootScreen: some View {
        switch selectedTab {
        case .generate:
            NavigationStack {
                IOSGenerateContainerView(
                    selectedTab: $selectedTab,
                    isTabActive: true,
                    selectedSection: $selectedGenerationSection,
                    customVoiceDraft: $customVoiceDraft,
                    voiceDesignDraft: $voiceDesignDraft,
                    voiceCloningDraft: $voiceCloningDraft,
                    pendingVoiceCloningHandoff: $pendingVoiceCloningHandoff,
                    customPrimaryAction: $customPrimaryAction,
                    designPrimaryAction: $designPrimaryAction,
                    clonePrimaryAction: $clonePrimaryAction
                )
            }
            .toolbar(.hidden, for: .navigationBar)

        case .library:
            NavigationStack {
                IOSLibraryContainerView(
                    selectedTab: $selectedTab,
                    selectedSection: $selectedLibrarySection,
                    onUseVoiceInClone: { voice in
                        pendingVoiceCloningHandoff = PendingVoiceCloningHandoff(
                            savedVoiceID: voice.id,
                            wavPath: voice.wavPath,
                            transcript: (try? voice.loadTranscript()) ?? "",
                            transcriptLoadError: nil
                        )
                        selectedGenerationSection = .clone
                        selectedTab = .generate
                    }
                )
            }
            .toolbar(.hidden, for: .navigationBar)

        case .settings:
            NavigationStack {
                IOSSettingsContainerView(selectedTab: $selectedTab)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
