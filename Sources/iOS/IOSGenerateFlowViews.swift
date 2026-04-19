import SwiftUI
import QwenVoiceCore

private struct IOSPrefetchContext {
    let request: GenerationRequest
    let screen: String
    let requestKey: String
    let signature: String
    let debounceNanoseconds: UInt64
}

struct IOSGenerateContainerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var ttsEngine: TTSEngineStore
    @StateObject private var memoryIndicatorStore = IOSGenerateMemoryIndicatorStore()
    @ScaledMetric(relativeTo: .body) private var selectorRailHeight = 42

    @Binding var selectedTab: IOSAppTab
    let isTabActive: Bool
    @Binding var selectedSection: IOSGenerationSection
    @Binding var customVoiceDraft: CustomVoiceDraft
    @Binding var voiceDesignDraft: VoiceDesignDraft
    @Binding var voiceCloningDraft: VoiceCloningDraft
    @Binding var pendingVoiceCloningHandoff: PendingVoiceCloningHandoff?
    @Binding var customPrimaryAction: IOSGeneratePrimaryActionDescriptor
    @Binding var designPrimaryAction: IOSGeneratePrimaryActionDescriptor
    @Binding var clonePrimaryAction: IOSGeneratePrimaryActionDescriptor

    private var activePrimaryAction: IOSGeneratePrimaryActionDescriptor {
        switch selectedSection {
        case .custom:
            return customPrimaryAction
        case .design:
            return designPrimaryAction
        case .clone:
            return clonePrimaryAction
        }
    }

    var body: some View {
        IOSStudioShellScreen(
            selectedTab: $selectedTab,
            activeTab: .generate,
            tint: selectedSection.primaryActionTint
        ) {
            IOSMemoryHeaderAccessory(state: memoryIndicatorStore.state)
        } bottomAccessory: {
            IOSGenerationPrimaryButton(
                title: activePrimaryAction.title,
                systemImage: activePrimaryAction.systemImage,
                tint: activePrimaryAction.tint,
                isRunning: activePrimaryAction.isRunning,
                isEnabled: activePrimaryAction.isEnabled,
                accessibilityIdentifier: activePrimaryAction.accessibilityIdentifier,
                action: activePrimaryAction.action
            )
            .frame(maxWidth: .infinity)
        } content: {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    IOSGenerationModeSelector(selectedSection: $selectedSection)
                        .frame(height: selectorRailHeight)

                    IOSGenerateModeViewport(selection: selectedSection) {
                        IOSCustomVoiceView(
                            isActive: selectedSection == .custom,
                            draft: $customVoiceDraft,
                            primaryAction: $customPrimaryAction
                        )
                    } design: {
                        IOSVoiceDesignView(
                            isActive: selectedSection == .design,
                            draft: $voiceDesignDraft,
                            primaryAction: $designPrimaryAction
                        )
                    } clone: {
                        IOSVoiceCloningView(
                            isActive: selectedSection == .clone,
                            draft: $voiceCloningDraft,
                            primaryAction: $clonePrimaryAction,
                            pendingSavedVoiceHandoff: $pendingVoiceCloningHandoff
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background {
            IOSGeneratePrefetchCoordinator(
                isTabActive: isTabActive,
                selectedSection: selectedSection,
                customVoiceDraft: customVoiceDraft,
                voiceDesignDraft: voiceDesignDraft
            )
        }
        .task {
            configureMemoryIndicator()
        }
        .onChange(of: isTabActive) { _, _ in
            refreshMemoryIndicatorMonitoring()
        }
        .onChange(of: scenePhase) { _, _ in
            refreshMemoryIndicatorMonitoring()
        }
        .onChange(of: ttsEngine.hasActiveGeneration) { _, _ in
            refreshMemoryIndicatorMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ttsEngineMemoryContextDidChange, object: ttsEngine)) { _ in
            memoryIndicatorStore.requestRefresh()
        }
        .accessibilityIdentifier("screen_generateStudio")
    }

    private func configureMemoryIndicator() {
        memoryIndicatorStore.configure(
            snapshotProvider: ttsEngine.memoryIndicatorSnapshotProvider,
            policy: ttsEngine.memoryIndicatorBudgetPolicy
        )
        refreshMemoryIndicatorMonitoring()
    }

    private func refreshMemoryIndicatorMonitoring() {
        memoryIndicatorStore.updateMonitoring(
            isGenerateVisible: isTabActive,
            isSceneActive: scenePhase == .active,
            isGenerating: ttsEngine.hasActiveGeneration
        )
    }
}

private struct IOSGeneratePrefetchCoordinator: View {
    @EnvironmentObject private var ttsEngine: TTSEngineStore
    @EnvironmentObject private var modelManager: ModelManagerViewModel

    let isTabActive: Bool
    let selectedSection: IOSGenerationSection
    let customVoiceDraft: CustomVoiceDraft
    let voiceDesignDraft: VoiceDesignDraft

    @State private var didRefreshAvailability = false
    @State private var prefetchTask: Task<Void, Never>?
    @State private var lastCompletedPrefetchSignature: String?
    @State private var latestPrefetchToken = ""

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                await modelManager.refresh()
                didRefreshAvailability = true
                guard let context = currentPrefetchContext() else { return }
                await performPrefetch(context, token: UUID().uuidString)
            }
            .onChange(of: isTabActive) { _, _ in
                scheduleSelectedGenerationPrefetch(force: true)
            }
            .onChange(of: selectedSection) { _, _ in
                scheduleSelectedGenerationPrefetch(force: true)
            }
            .onChange(of: modelManager.statuses) { _, _ in
                guard didRefreshAvailability else { return }
                scheduleSelectedGenerationPrefetch(force: true)
            }
            .onChange(of: customVoiceDraft.selectedSpeaker) { _, _ in
                scheduleSelectedGenerationPrefetch()
            }
            .onChange(of: customVoiceDraft.resolvedDeliveryInstruction) { _, _ in
                scheduleSelectedGenerationPrefetch()
            }
            .onChange(of: voiceDesignDraft.voiceDescription) { _, _ in
                scheduleSelectedGenerationPrefetch()
            }
            .onChange(of: voiceDesignDraft.resolvedDeliveryInstruction) { _, _ in
                scheduleSelectedGenerationPrefetch()
            }
            .onChange(of: voiceDesignDraft.text) { _, _ in
                scheduleSelectedGenerationPrefetch()
            }
    }

    private func scheduleSelectedGenerationPrefetch(force: Bool = false) {
        prefetchTask?.cancel()
        guard let context = currentPrefetchContext() else { return }
        if !force, lastCompletedPrefetchSignature == context.signature {
            return
        }

        prefetchTask = Task { @MainActor in
            if context.debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: context.debounceNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await performPrefetch(context, token: UUID().uuidString)
        }
    }

    private func performPrefetch(_ context: IOSPrefetchContext, token: String) async {
        latestPrefetchToken = token

        let diagnostics = await ttsEngine.prefetchInteractiveReadinessIfNeeded(for: context.request)
        guard latestPrefetchToken == token else { return }

        if diagnostics != nil {
            lastCompletedPrefetchSignature = context.signature
        }
    }

    private func currentPrefetchContext() -> IOSPrefetchContext? {
        guard isTabActive else { return nil }
        guard let model = TTSModel.model(for: selectedSection.mode),
              modelManager.isAvailable(model),
              ttsEngine.supportsMode(selectedSection.mode) else {
            return nil
        }

        switch selectedSection {
        case .custom:
            let prefetchText = customVoiceDraft.text.isEmpty
                ? MLXTTSEngine.lightweightWarmupTextForUI
                : customVoiceDraft.text
            let request = GenerationRequest(
                mode: .custom,
                modelID: model.id,
                text: prefetchText,
                outputPath: "",
                shouldStream: true,
                streamingInterval: GenerationSemantics.appStreamingInterval,
                payload: .custom(
                    speakerID: customVoiceDraft.selectedSpeaker,
                    deliveryStyle: customVoiceDraft.resolvedDeliveryInstruction
                )
            )
            let normalizedEmotion = GenerationSemantics.normalizedConditioningCacheKeyText(
                customVoiceDraft.resolvedDeliveryInstruction
            )
            return IOSPrefetchContext(
                request: request,
                screen: "screen_customVoice",
                requestKey: GenerationSemantics.prewarmIdentityKey(
                    modelID: request.modelID,
                    mode: request.mode,
                    voice: customVoiceDraft.selectedSpeaker,
                    instruct: customVoiceDraft.resolvedDeliveryInstruction
                ),
                signature: [
                    "custom",
                    model.id,
                    GenerationSemantics.qwenLanguageHint(for: request),
                    customVoiceDraft.selectedSpeaker,
                    normalizedEmotion,
                ].joined(separator: "|"),
                debounceNanoseconds: 150_000_000
            )
        case .design:
            let prefetchText = voiceDesignDraft.text.isEmpty
                ? GenerationSemantics.canonicalDesignWarmShortText
                : voiceDesignDraft.text
            let voiceDescription = voiceDesignDraft.voiceDescription.isEmpty
                ? "Clear, natural narration voice"
                : voiceDesignDraft.voiceDescription
            let request = GenerationRequest(
                mode: .design,
                modelID: model.id,
                text: prefetchText,
                outputPath: "",
                shouldStream: true,
                streamingInterval: GenerationSemantics.appStreamingInterval,
                payload: .design(
                    voiceDescription: voiceDescription,
                    deliveryStyle: voiceDesignDraft.resolvedDeliveryInstruction
                )
            )
            let requestKey = GenerationSemantics.designConditioningWarmKey(for: request) ?? ""
            let bucket = GenerationSemantics.designWarmBucket(for: prefetchText)
            let instructionIdentity = GenerationSemantics.normalizedDesignConditioningIdentity(
                language: GenerationSemantics.qwenLanguageHint(for: request),
                voiceDescription: voiceDescription,
                emotion: voiceDesignDraft.resolvedDeliveryInstruction
            )
            return IOSPrefetchContext(
                request: request,
                screen: "screen_voiceDesign",
                requestKey: requestKey,
                signature: [
                    "design",
                    model.id,
                    instructionIdentity,
                    bucket.rawValue,
                ].joined(separator: "|"),
                debounceNanoseconds: 350_000_000
            )
        case .clone:
            return nil
        }
    }
}

struct IOSGenerationModeSelector: View {
    @Binding var selectedSection: IOSGenerationSection

    var body: some View {
        IOSCapsuleSelector(
            items: IOSGenerationSection.allCases,
            selection: $selectedSection,
            title: \.compactTitle,
            selectedTint: \.primaryActionTint,
            controlAccessibilityIdentifier: "generateSectionPicker",
            itemAccessibilityIdentifier: { "generateSection_\($0.rawValue)" }
        )
    }
}

struct IOSCapsuleSelector<Item: Identifiable & Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: KeyPath<Item, String>
    let selectedTint: (Item) -> Color
    let controlAccessibilityIdentifier: String
    let itemAccessibilityIdentifier: (Item) -> String
    @Namespace private var selectionPillNamespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                Button {
                    guard item != selection else { return }
                    selection = item
                } label: {
                    Text(item[keyPath: title])
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(
                            item == selection
                                ? IOSAppTheme.accentForeground
                                : IOSAppTheme.textPrimary
                        )
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 36)
                        .background {
                            if item == selection {
                                Capsule(style: .continuous)
                                    .fill(Color.clear)
                                    .iosSelectorPillGlass(tint: selectedTint(item))
                                    .matchedGeometryEffect(id: "selectionPill", in: selectionPillNamespace)
                            }
                        }
                }
                .buttonStyle(.plain)
                .animation(IOSSelectionMotion.selectorLabel, value: selection)
                .accessibilityIdentifier(itemAccessibilityIdentifier(item))
                .accessibilityAddTraits(item == selection ? .isSelected : [])
            }
        }
        .animation(IOSSelectionMotion.selectorPill, value: selection)
        .padding(2)
        .iosSelectorRailGlass(tint: selectedTint(selection))
        .padding(.vertical, 1)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(controlAccessibilityIdentifier)
    }
}

extension IOSGenerationSection {
    var primaryActionSystemImage: String {
        switch self {
        case .custom:
            return "waveform.and.mic"
        case .design:
            return "paintbrush.pointed"
        case .clone:
            return "waveform.path.ecg"
        }
    }

    var primaryActionTint: Color {
        IOSBrandTheme.modeColor(for: mode)
    }
}

struct IOSGeneratePrimaryActionDescriptor {
    let title: String
    let systemImage: String
    let tint: Color
    let isRunning: Bool
    let isEnabled: Bool
    let accessibilityIdentifier: String
    let action: () -> Void

    static func placeholder(for section: IOSGenerationSection) -> IOSGeneratePrimaryActionDescriptor {
        IOSGeneratePrimaryActionDescriptor(
            title: "Create",
            systemImage: section.primaryActionSystemImage,
            tint: section.primaryActionTint,
            isRunning: false,
            isEnabled: false,
            accessibilityIdentifier: "textInput_generateButton",
            action: {}
        )
    }
}

struct IOSGenerationPrimaryButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let isRunning: Bool
    let isEnabled: Bool
    let accessibilityIdentifier: String
    let action: () -> Void

    private var foregroundStyle: Color {
        IOSAppTheme.accentForeground
    }

    var body: some View {
        Button {
            IOSHaptics.impact(.medium)
            action()
        } label: {
            HStack(spacing: 8) {
                if isRunning {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(foregroundStyle)
                } else {
                    Image(systemName: systemImage)
                }

                Text(title)
                    .font(.headline.weight(.semibold))
            }
            .foregroundStyle(foregroundStyle)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
        }
        .iosAdaptiveUtilityButtonStyle(prominent: true, tint: tint)
        .disabled(!isEnabled)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
