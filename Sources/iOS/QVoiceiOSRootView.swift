import SwiftUI
import UniformTypeIdentifiers
import QwenVoiceCore

enum IOSAppTab: String, CaseIterable, Identifiable {
    case generate
    case library
    case settings

    var id: String { rawValue }
}

enum IOSLibrarySection: String, CaseIterable, Identifiable {
    case history
    case voices

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history:
            return "History"
        case .voices:
            return "Voices"
        }
    }

    var selectionTint: Color {
        switch self {
        case .history:
            return IOSBrandTheme.library
        case .voices:
            return IOSBrandTheme.library
        }
    }
}

enum IOSGenerationSection: String, CaseIterable, Identifiable {
    case custom
    case design
    case clone

    var id: String { rawValue }

    var mode: GenerationMode {
        switch self {
        case .custom: return .custom
        case .design: return .design
        case .clone: return .clone
        }
    }

    var title: String {
        mode.displayName
    }

    var compactTitle: String {
        switch self {
        case .custom:
            return "Choose Voice"
        case .design:
            return "Describe Voice"
        case .clone:
            return "Use Reference"
        }
    }
}

private struct IOSUITestGenerationOverrides {
    let selectedSection: IOSGenerationSection?
    let scriptText: String?
    let voiceDesignBrief: String?

    static var current: IOSUITestGenerationOverrides {
        let environment = ProcessInfo.processInfo.environment
        return IOSUITestGenerationOverrides(
            selectedSection: environment["QVOICE_UI_TEST_SECTION"]
                .flatMap(IOSGenerationSection.init(rawValue:)),
            scriptText: environment["QVOICE_UI_TEST_SCRIPT_TEXT"],
            voiceDesignBrief: environment["QVOICE_UI_TEST_VOICE_BRIEF"]
        )
    }
}

enum IOSSimulatorPreviewPolicy {
    static var isSimulatorPreview: Bool {
        IOSSimulatorRuntimeSupport.isSimulator
    }

    static func showsFullGenerationUI(for mode: GenerationMode) -> Bool {
        if isSimulatorPreview {
            return true
        }
        return IOSNativeDeviceFeatureGate.unsupportedReason(for: mode) == nil
    }

    static func allowsExecution(
        for mode: GenerationMode,
        declaredModes: Set<GenerationMode>
    ) -> Bool {
        !isSimulatorPreview && IOSNativeDeviceFeatureGate.isModeSupported(mode, declaredModes: declaredModes)
    }

    static var allowsModelMutations: Bool {
        !isSimulatorPreview
    }

    static func previewOperationState(
        for model: TTSModel,
        status: ModelManagerViewModel.ModelStatus,
        operationState: IOSModelInstallerViewModel.OperationState
    ) -> IOSModelInstallerViewModel.OperationState {
        guard isSimulatorPreview else { return operationState }

        switch operationState {
        case .available,
                .downloading,
                .interrupted,
                .resuming,
                .restarting,
                .verifying,
                .installing,
                .installed,
                .deleting:
            return operationState
        case .failed(let message):
            return .failed(message)
        case .idle, .unavailable:
            switch status {
            case .installed:
                return .installed
            case .checking, .notInstalled:
                return .available(estimatedBytes: model.estimatedDownloadBytes)
            case .incomplete(let message, _), .error(let message):
                return .failed(message)
            }
        }
    }
}

private struct IOSPrefetchContext {
    let request: GenerationRequest
    let screen: String
    let requestKey: String
    let signature: String
    let debounceNanoseconds: UInt64
}

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

private struct IOSGenerateContainerView: View {
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

private struct IOSGenerationModeSelector: View {
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

private extension IOSGenerationSection {
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

private struct IOSGeneratePrimaryActionDescriptor {
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

private struct IOSGenerationPrimaryButton: View {
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

private struct IOSCustomVoiceView: View {
    @EnvironmentObject private var ttsEngine: TTSEngineStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var modelManager: ModelManagerViewModel

    let isActive: Bool
    @Binding var draft: CustomVoiceDraft
    @Binding var primaryAction: IOSGeneratePrimaryActionDescriptor
    @State private var isGenerating = false
    @State private var isScriptFocused = false
    @State private var errorMessage: String?

    private var activeModel: TTSModel? {
        TTSModel.model(for: .custom)
    }

    private var isSimulatorPreview: Bool {
        IOSSimulatorPreviewPolicy.isSimulatorPreview
    }

    private var allowsExecution: Bool {
        IOSSimulatorPreviewPolicy.allowsExecution(for: .custom, declaredModes: ttsEngine.supportedModes)
    }

    private var isModelAvailable: Bool {
        guard let activeModel else { return false }
        return modelManager.isAvailable(activeModel)
    }

    private var promptText: String {
        IOSGenerationTextLimitPolicy.clamped(draft.text, mode: .custom)
    }

    private var promptTextBinding: Binding<String> {
        Binding(
            get: { promptText },
            set: { draft.text = IOSGenerationTextLimitPolicy.clamped($0, mode: .custom) }
        )
    }

    private var scriptLimitState: IOSGenerationTextLimitPolicy.State {
        IOSGenerationTextLimitPolicy.state(for: promptText, mode: .custom)
    }

    private var canGenerate: Bool {
        allowsExecution
            && ttsEngine.isReady
            && isModelAvailable
            && !scriptLimitState.trimmedIsEmpty
            && !scriptLimitState.isOverLimit
    }

    private var chromeOpacity: Double {
        isGenerating ? 0.76 : 1
    }

    private var setupMessage: String? {
        if !isModelAvailable, !isSimulatorPreview, let activeModel {
            return "Install \(activeModel.name) in Settings."
        }
        return nil
    }

    private var promptHelper: String? {
        if !isScriptFocused && promptText.isEmpty {
            return nil
        }
        return scriptLimitState.helperMessage
    }

    private var primaryActionToken: String {
        "\(isGenerating)-\(isSimulatorPreview || canGenerate)"
    }

    var body: some View {
        pageContent
            .accessibilityIdentifier("screen_customVoice")
            .task(id: primaryActionToken) {
                guard isActive else { return }
                publishPrimaryAction()
            }
            .onChange(of: isActive) { _, active in
                guard active else { return }
                publishPrimaryAction()
            }
    }

    @ViewBuilder
    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            IOSStudioComposerCard(
                title: "Use an existing voice",
                subtitle: "",
                promptSectionTitle: "Script",
                setupSectionTitle: "Voice",
                tint: IOSBrandTheme.custom,
                helper: promptHelper,
                text: promptTextBinding,
                placeholder: "Type the text to speak",
                isFocused: $isScriptFocused,
                accessibilityIdentifier: "textInput_textEditor",
                counterText: scriptLimitState.counterText,
                counterTone: scriptLimitState.isOverLimit ? .orange : IOSBrandTheme.custom,
                helperTone: scriptLimitState.isOverLimit ? .orange : IOSAppTheme.textSecondary,
                notice: errorMessage,
                noticeTint: .orange,
                maxCharacterCount: scriptLimitState.limit
            ) {
                EmptyView()
            } setup: {
                IOSCustomVoiceSetupCard(
                    selectedSpeaker: $draft.selectedSpeaker,
                    delivery: $draft.delivery,
                    setupMessage: setupMessage,
                    badgeText: nil,
                    badgeTone: nil,
                    modelInstallMessage: activeModel.flatMap { model in
                        guard !isModelAvailable, !isSimulatorPreview else { return nil }
                        return "Install \(model.name) in Settings."
                    }
                )
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(chromeOpacity)
        .animation(IOSSelectionMotion.modeCrossfade, value: isGenerating)
        .onChange(of: draft.text) { _, newValue in
            let clamped = IOSGenerationTextLimitPolicy.clamped(newValue, mode: .custom)
            if clamped != newValue {
                draft.text = clamped
            }
        }
    }

    private func publishPrimaryAction() {
        primaryAction = IOSGeneratePrimaryActionDescriptor(
            title: "Create",
            systemImage: IOSGenerationSection.custom.primaryActionSystemImage,
            tint: IOSGenerationSection.custom.primaryActionTint,
            isRunning: isGenerating,
            isEnabled: isSimulatorPreview || canGenerate,
            accessibilityIdentifier: "textInput_generateButton",
            action: generate
        )
    }

    private func generate() {
        if isSimulatorPreview {
            errorMessage = nil
            return
        }
        guard !scriptLimitState.trimmedIsEmpty, ttsEngine.isReady else { return }
        guard !scriptLimitState.isOverLimit else {
            errorMessage = scriptLimitState.warningMessage
            return
        }
        guard let model = activeModel else { return }
        guard isModelAvailable else {
            errorMessage = "Install \(model.name) in Settings to generate audio."
            return
        }

        isGenerating = true
        errorMessage = nil

        Task {
            let outputPath = makeOutputPath(subfolder: model.outputSubfolder, text: promptText)
            let uiTestRequest = UITestGenerationRequest.uiDrivenIfConfigured(mode: .custom)
            do {
                audioPlayer.prepareStreamingPreview(
                    title: String(promptText.prefix(40)),
                    shouldAutoPlay: AudioService.shouldAutoPlay
                )
                await AppGenerationTelemetryCoordinator.shared.begin(
                    mode: .custom,
                    requestID: uiTestRequest?.requestID,
                    telemetry: uiTestRequest?.telemetry
                )
                let result = try await ttsEngine.generate(
                    GenerationRequest(
                        mode: .custom,
                        modelID: model.id,
                        text: promptText,
                        outputPath: outputPath,
                        shouldStream: true,
                        streamingInterval: GenerationSemantics.appStreamingInterval,
                        payload: .custom(
                            speakerID: draft.selectedSpeaker,
                            deliveryStyle: draft.resolvedDeliveryInstruction
                        )
                    )
                )
                var generation = Generation(
                    text: promptText,
                    mode: model.mode.rawValue,
                    modelTier: model.tier,
                    voice: draft.selectedSpeaker,
                    emotion: draft.resolvedDeliveryInstruction,
                    speed: nil,
                    audioPath: result.audioPath,
                    duration: result.durationSeconds,
                    createdAt: Date()
                )
                try GenerationPersistence.persistAndAutoplay(
                    &generation,
                    result: result,
                    text: promptText,
                    audioPlayer: audioPlayer,
                    caller: "IOSCustomVoiceView"
                )
                await AppGenerationTelemetryCoordinator.shared.publishSuccess(
                    mode: .custom,
                    requestID: uiTestRequest?.requestID,
                    result: result
                )
                IOSHaptics.success()
            } catch {
                if (error as? GenerationPersistence.PersistenceError) == nil {
                    audioPlayer.abortLivePreviewIfNeeded()
                }
                errorMessage = error.localizedDescription
                await AppGenerationTelemetryCoordinator.shared.publishFailure(
                    mode: .custom,
                    requestID: uiTestRequest?.requestID,
                    error: error
                )
                IOSHaptics.warning()
            }

            isGenerating = false
        }
    }
}

private struct IOSVoiceDesignView: View {
    @EnvironmentObject private var ttsEngine: TTSEngineStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var modelManager: ModelManagerViewModel
    @EnvironmentObject private var savedVoicesViewModel: SavedVoicesViewModel

    let isActive: Bool
    @Binding var draft: VoiceDesignDraft
    @Binding var primaryAction: IOSGeneratePrimaryActionDescriptor
    @State private var isGenerating = false
    @State private var isScriptFocused = false
    @State private var errorMessage: String?
    @State private var saveSheetAudioPath: String?
    @State private var isSaveSheetPresented = false
    @State private var saveSheetSuggestedName = ""
    @State private var saveSheetTranscript = ""
    @State private var saveError: String?

    private var activeModel: TTSModel? {
        TTSModel.model(for: .design)
    }

    private var isSimulatorPreview: Bool {
        IOSSimulatorPreviewPolicy.isSimulatorPreview
    }

    private var allowsExecution: Bool {
        IOSSimulatorPreviewPolicy.allowsExecution(for: .design, declaredModes: ttsEngine.supportedModes)
    }

    private var isModelAvailable: Bool {
        guard let activeModel else { return false }
        return modelManager.isAvailable(activeModel)
    }

    private var promptText: String {
        IOSGenerationTextLimitPolicy.clamped(draft.text, mode: .design)
    }

    private var promptTextBinding: Binding<String> {
        Binding(
            get: { promptText },
            set: { draft.text = IOSGenerationTextLimitPolicy.clamped($0, mode: .design) }
        )
    }

    private var scriptLimitState: IOSGenerationTextLimitPolicy.State {
        IOSGenerationTextLimitPolicy.state(for: promptText, mode: .design)
    }

    private var canGenerate: Bool {
        allowsExecution
            && ttsEngine.isReady
            && isModelAvailable
            && !draft.voiceDescription.isEmpty
            && !scriptLimitState.trimmedIsEmpty
            && !scriptLimitState.isOverLimit
    }

    private var chromeOpacity: Double {
        isGenerating ? 0.76 : 1
    }

    private var setupMessage: String? {
        if !isModelAvailable, !isSimulatorPreview, let activeModel {
            return "Install \(activeModel.name) in Settings."
        }
        return nil
    }

    private var promptHelper: String? {
        if !isScriptFocused && promptText.isEmpty {
            return nil
        }
        return scriptLimitState.helperMessage
    }

    private var canSaveVoice: Bool {
        ttsEngine.supportsSavedVoiceMutation && saveSheetAudioPath != nil
    }

    private var primaryActionToken: String {
        "\(isGenerating)-\(isSimulatorPreview || canGenerate)"
    }

    var body: some View {
        pageContent
            .accessibilityIdentifier("screen_voiceDesign")
        .task(id: primaryActionToken) {
            guard isActive else { return }
            publishPrimaryAction()
        }
        .onChange(of: isActive) { _, active in
            guard active else { return }
            publishPrimaryAction()
        }
        .sheet(isPresented: Binding(
            get: { isSaveSheetPresented },
            set: { isPresented in
                isSaveSheetPresented = isPresented
                if !isPresented {
                    saveSheetSuggestedName = ""
                    saveSheetTranscript = ""
                    saveError = nil
                }
            }
        )) {
            if let saveSheetAudioPath {
                IOSSaveVoiceSheet(
                    title: "Save Generated Voice",
                    suggestedName: $saveSheetSuggestedName,
                    transcript: $saveSheetTranscript,
                    errorMessage: saveError,
                    onCancel: {
                        isSaveSheetPresented = false
                        saveSheetSuggestedName = ""
                        saveSheetTranscript = ""
                        saveError = nil
                    },
                    onSave: {
                        Task {
                            do {
                                let voice = try await ttsEngine.enrollPreparedVoice(
                                    name: saveSheetSuggestedName,
                                    audioPath: saveSheetAudioPath,
                                    transcript: saveSheetTranscript.isEmpty ? nil : saveSheetTranscript
                                )
                                await MainActor.run {
                                    savedVoicesViewModel.insertOrReplace(voice)
                                    isSaveSheetPresented = false
                                    saveSheetSuggestedName = ""
                                    saveSheetTranscript = ""
                                    saveError = nil
                                }
                                await savedVoicesViewModel.refresh(using: ttsEngine)
                            } catch {
                                await MainActor.run {
                                    saveError = error.localizedDescription
                                }
                            }
                        }
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            IOSStudioComposerCard(
                title: "Describe the voice you want",
                subtitle: "",
                promptSectionTitle: "Script",
                setupSectionTitle: "Voice",
                tint: IOSBrandTheme.design,
                helper: promptHelper,
                text: promptTextBinding,
                placeholder: "Type the text to speak",
                isFocused: $isScriptFocused,
                accessibilityIdentifier: "textInput_textEditor",
                counterText: scriptLimitState.counterText,
                counterTone: scriptLimitState.isOverLimit ? .orange : IOSBrandTheme.design,
                helperTone: scriptLimitState.isOverLimit ? .orange : IOSAppTheme.textSecondary,
                notice: errorMessage,
                noticeTint: .orange,
                maxCharacterCount: scriptLimitState.limit
            ) {
                if canSaveVoice {
                    IOSComposerCardAction(
                        title: "Save",
                        systemImage: "person.crop.circle.badge.plus",
                        tint: IOSBrandTheme.design,
                        accessibilityIdentifier: "voiceDesign_saveVoiceButton"
                    ) {
                        saveSheetSuggestedName = suggestedSavedVoiceName
                        saveSheetTranscript = promptText
                        isSaveSheetPresented = true
                    }
                } else {
                    EmptyView()
                }
            } setup: {
                IOSVoiceDesignSetupCard(
                    voiceDescription: $draft.voiceDescription,
                    delivery: $draft.delivery,
                    setupMessage: setupMessage,
                    badgeText: nil,
                    badgeTone: nil,
                    modelInstallMessage: activeModel.flatMap { model in
                        guard !isModelAvailable, !isSimulatorPreview else { return nil }
                        return "Install \(model.name) in Settings."
                    }
                )
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(chromeOpacity)
        .animation(IOSSelectionMotion.modeCrossfade, value: isGenerating)
        .onChange(of: draft.text) { _, newValue in
            let clamped = IOSGenerationTextLimitPolicy.clamped(newValue, mode: .design)
            if clamped != newValue {
                draft.text = clamped
            }
        }
    }

    private func publishPrimaryAction() {
        primaryAction = IOSGeneratePrimaryActionDescriptor(
            title: "Create",
            systemImage: IOSGenerationSection.design.primaryActionSystemImage,
            tint: IOSGenerationSection.design.primaryActionTint,
            isRunning: isGenerating,
            isEnabled: isSimulatorPreview || canGenerate,
            accessibilityIdentifier: "textInput_generateButton",
            action: generate
        )
    }

    private var suggestedSavedVoiceName: String {
        let clipped = draft.voiceDescription
            .split(separator: " ")
            .prefix(3)
            .joined(separator: " ")
        return clipped.isEmpty ? "Designed Voice" : clipped
    }

    private func generate() {
        if isSimulatorPreview {
            errorMessage = nil
            return
        }
        guard let model = activeModel else { return }
        guard canGenerate else {
            if !isModelAvailable {
                errorMessage = "Install \(model.name) in Settings to generate audio."
            } else if scriptLimitState.isOverLimit {
                errorMessage = scriptLimitState.warningMessage
            }
            return
        }

        isGenerating = true
        errorMessage = nil

        Task {
            let outputPath = makeOutputPath(subfolder: model.outputSubfolder, text: promptText)
            let uiTestRequest = UITestGenerationRequest.uiDrivenIfConfigured(mode: .design)
            do {
                audioPlayer.prepareStreamingPreview(
                    title: String(promptText.prefix(40)),
                    shouldAutoPlay: AudioService.shouldAutoPlay
                )
                await AppGenerationTelemetryCoordinator.shared.begin(
                    mode: .design,
                    requestID: uiTestRequest?.requestID,
                    telemetry: uiTestRequest?.telemetry
                )
                let result = try await ttsEngine.generate(
                    GenerationRequest(
                        mode: .design,
                        modelID: model.id,
                        text: promptText,
                        outputPath: outputPath,
                        shouldStream: true,
                        streamingInterval: GenerationSemantics.appStreamingInterval,
                        payload: .design(
                            voiceDescription: draft.voiceDescription,
                            deliveryStyle: draft.resolvedDeliveryInstruction
                        )
                    )
                )
                var generation = Generation(
                    text: promptText,
                    mode: model.mode.rawValue,
                    modelTier: model.tier,
                    voice: draft.voiceDescription,
                    emotion: draft.resolvedDeliveryInstruction,
                    speed: nil,
                    audioPath: result.audioPath,
                    duration: result.durationSeconds,
                    createdAt: Date()
                )
                try GenerationPersistence.persistAndAutoplay(
                    &generation,
                    result: result,
                    text: promptText,
                    audioPlayer: audioPlayer,
                    caller: "IOSVoiceDesignView"
                )
                saveSheetAudioPath = result.audioPath
                await AppGenerationTelemetryCoordinator.shared.publishSuccess(
                    mode: .design,
                    requestID: uiTestRequest?.requestID,
                    result: result
                )
                IOSHaptics.success()
            } catch {
                if (error as? GenerationPersistence.PersistenceError) == nil {
                    audioPlayer.abortLivePreviewIfNeeded()
                }
                errorMessage = error.localizedDescription
                await AppGenerationTelemetryCoordinator.shared.publishFailure(
                    mode: .design,
                    requestID: uiTestRequest?.requestID,
                    error: error
                )
                IOSHaptics.warning()
            }
            isGenerating = false
        }
    }
}

private struct IOSVoiceCloningView: View {
    @EnvironmentObject private var ttsEngine: TTSEngineStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var modelManager: ModelManagerViewModel
    @EnvironmentObject private var savedVoicesViewModel: SavedVoicesViewModel

    let isActive: Bool
    @Binding var draft: VoiceCloningDraft
    @Binding var primaryAction: IOSGeneratePrimaryActionDescriptor
    @Binding var pendingSavedVoiceHandoff: PendingVoiceCloningHandoff?

    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var transcriptLoadError: String?
    @State private var hydratedSavedVoiceID: String?
    @State private var isImporterPresented = false
    @State private var isTranscriptExpanded = false
    @State private var isScriptFocused = false

    private var cloneModel: TTSModel? {
        TTSModel.model(for: .clone)
    }

    private var isModelAvailable: Bool {
        guard let cloneModel else { return false }
        return modelManager.isAvailable(cloneModel)
    }

    private var savedVoices: [Voice] {
        savedVoicesViewModel.voices
    }

    private var selectedVoice: Voice? {
        guard let selectedSavedVoiceID = draft.selectedSavedVoiceID else { return nil }
        return savedVoices.first(where: { $0.id == selectedSavedVoiceID })
    }

    private var clonePrimingRequestKey: String? {
        guard let model = cloneModel,
              ttsEngine.isReady,
              isModelAvailable,
              let referenceAudioPath = draft.referenceAudioPath else {
            return nil
        }
        if let selectedSavedVoiceID = draft.selectedSavedVoiceID,
           hydratedSavedVoiceID != selectedSavedVoiceID,
           transcriptLoadError == nil {
            return nil
        }
        return GenerationSemantics.cloneReferenceIdentityKey(
            modelID: model.id,
            refAudio: referenceAudioPath,
            refText: draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript
        )
    }

    private var clonePrimingTaskID: String {
        "\(isActive)-\(clonePrimingRequestKey ?? "clone-priming-idle")"
    }

    private var promptText: String {
        IOSGenerationTextLimitPolicy.clamped(draft.text, mode: .clone)
    }

    private var promptTextBinding: Binding<String> {
        Binding(
            get: { promptText },
            set: { draft.text = IOSGenerationTextLimitPolicy.clamped($0, mode: .clone) }
        )
    }

    private var scriptLimitState: IOSGenerationTextLimitPolicy.State {
        IOSGenerationTextLimitPolicy.state(for: promptText, mode: .clone)
    }

    private var isSimulatorPreview: Bool {
        IOSSimulatorPreviewPolicy.isSimulatorPreview
    }

    private var allowsExecution: Bool {
        IOSSimulatorPreviewPolicy.allowsExecution(for: .clone, declaredModes: ttsEngine.supportedModes)
    }

    private var cloneContextStatus: VoiceCloningContextStatus? {
        guard draft.referenceAudioPath != nil else { return nil }
        if let selectedSavedVoiceID = draft.selectedSavedVoiceID,
           hydratedSavedVoiceID != selectedSavedVoiceID,
           transcriptLoadError == nil {
            return .waitingForHydration
        }
        guard let clonePrimingRequestKey else { return nil }
        if ttsEngine.clonePreparationState.identityKey == clonePrimingRequestKey {
            switch ttsEngine.clonePreparationState.phase {
            case .idle:
                break
            case .preparing:
                return .preparing
            case .primed:
                return .primed
            case .failed:
                return .fallback(
                    ttsEngine.clonePreparationState.message
                        ?? "Reference prep didn't finish. The first preview may be slower."
                )
            }
        }
        return .preparing
    }

    private var canGenerate: Bool {
        ttsEngine.isReady
            && allowsExecution
            && isModelAvailable
            && draft.referenceAudioPath != nil
            && !scriptLimitState.trimmedIsEmpty
            && !scriptLimitState.isOverLimit
    }

    private var setupMessage: String? {
        if !isModelAvailable, !isSimulatorPreview, let cloneModel {
            return "Install \(cloneModel.name) in Settings."
        }
        if draft.referenceAudioPath == nil {
            return "Choose a saved voice or import a recording."
        }
        if let cloneContextStatus {
            switch cloneContextStatus {
            case .waitingForHydration:
                return "Loading the selected voice."
            case .preparing:
                return "Preparing the reference audio."
            case .primed:
                return nil
            case .fallback(let message):
                return message
            }
        }
        return nil
    }

    private var promptHelper: String? {
        if !isScriptFocused && promptText.isEmpty {
            return nil
        }
        return scriptLimitState.helperMessage
    }

    private var primaryActionToken: String {
        "\(isGenerating)-\(isSimulatorPreview || canGenerate)"
    }

    var body: some View {
        pageContent
            .accessibilityIdentifier("screen_voiceCloning")
        .task(id: primaryActionToken) {
            guard isActive else { return }
            publishPrimaryAction()
        }
        .task {
            guard isActive else { return }
            if ttsEngine.isReady {
                await savedVoicesViewModel.ensureLoaded(using: ttsEngine)
            }
            consumePendingSavedVoiceHandoffIfNeeded()
            syncSavedVoiceSelectionState()
        }
        .task(id: clonePrimingTaskID) {
            guard isActive else {
                await ttsEngine.cancelClonePreparationIfNeeded()
                return
            }
            await syncCloneReferencePriming()
        }
        .onChange(of: isActive) { _, active in
            guard active else { return }
            publishPrimaryAction()
            consumePendingSavedVoiceHandoffIfNeeded()
            syncSavedVoiceSelectionState()
        }
        .onChange(of: pendingSavedVoiceHandoff) { _, _ in
            guard isActive else { return }
            consumePendingSavedVoiceHandoffIfNeeded()
        }
        .onChange(of: savedVoicesViewModel.voices) { _, _ in
            guard isActive else { return }
            syncSavedVoiceSelectionState()
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.audio, .wav, .mp3, .aiff, .mpeg4Audio]
        ) { result in
            switch result {
            case .success(let url):
                applyImportedReferenceAudio(from: url)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            IOSStudioComposerCard(
                title: "Use a reference recording",
                subtitle: "",
                promptSectionTitle: "Script",
                setupSectionTitle: "Reference",
                tint: IOSBrandTheme.clone,
                helper: promptHelper,
                text: promptTextBinding,
                placeholder: "Type the new text to speak",
                isFocused: $isScriptFocused,
                accessibilityIdentifier: "textInput_textEditor",
                counterText: scriptLimitState.counterText,
                counterTone: scriptLimitState.isOverLimit ? .orange : IOSBrandTheme.clone,
                helperTone: scriptLimitState.isOverLimit ? .orange : IOSAppTheme.textSecondary,
                notice: errorMessage,
                noticeTint: .orange,
                maxCharacterCount: scriptLimitState.limit
            ) {
                EmptyView()
            } setup: {
                IOSVoiceCloningReferenceCard(
                    savedVoices: savedVoices,
                    selectedSavedVoiceID: draft.selectedSavedVoiceID,
                    referenceAudioPath: draft.referenceAudioPath,
                    transcriptLoadError: transcriptLoadError,
                    setupMessage: setupMessage,
                    badgeText: nil,
                    badgeTone: nil,
                    onSelectSavedVoice: { newValue in
                        guard let newValue else {
                            clearReference()
                            return
                        }
                        guard let voice = savedVoices.first(where: { $0.id == newValue }) else { return }
                        applySavedVoice(voice)
                    },
                    onImportReference: {
                        isImporterPresented = true
                    },
                    onClearReference: clearReference,
                    referenceTranscript: $draft.referenceTranscript,
                    isTranscriptExpanded: $isTranscriptExpanded
                )
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: draft.text) { _, newValue in
            let clamped = IOSGenerationTextLimitPolicy.clamped(newValue, mode: .clone)
            if clamped != newValue {
                draft.text = clamped
            }
        }
    }

    private func publishPrimaryAction() {
        primaryAction = IOSGeneratePrimaryActionDescriptor(
            title: "Create",
            systemImage: IOSGenerationSection.clone.primaryActionSystemImage,
            tint: IOSGenerationSection.clone.primaryActionTint,
            isRunning: isGenerating,
            isEnabled: isSimulatorPreview || canGenerate,
            accessibilityIdentifier: "textInput_generateButton",
            action: generate
        )
    }

    private func consumePendingSavedVoiceHandoffIfNeeded() {
        guard let pendingSavedVoiceHandoff else { return }
        draft.applySavedVoiceSelection(
            id: pendingSavedVoiceHandoff.savedVoiceID,
            wavPath: pendingSavedVoiceHandoff.wavPath,
            transcript: pendingSavedVoiceHandoff.transcript
        )
        transcriptLoadError = pendingSavedVoiceHandoff.transcriptLoadError
        hydratedSavedVoiceID = pendingSavedVoiceHandoff.savedVoiceID
        self.pendingSavedVoiceHandoff = nil
    }

    private func generate() {
        if isSimulatorPreview {
            errorMessage = nil
            return
        }
        guard !scriptLimitState.trimmedIsEmpty, ttsEngine.isReady else { return }
        guard !scriptLimitState.isOverLimit else {
            errorMessage = scriptLimitState.warningMessage
            return
        }
        guard let model = cloneModel else { return }
        guard isModelAvailable else {
            errorMessage = "Install \(model.name) in Settings to generate audio."
            return
        }

        isGenerating = true
        errorMessage = nil

        Task {
            let uiTestRequest = UITestGenerationRequest.uiDrivenIfConfigured(mode: .clone)
            do {
                ensureSelectedSavedVoiceHydratedIfNeeded()
                guard let refPath = draft.referenceAudioPath else {
                    throw NSError(
                        domain: "QVoice.AppGeneration",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Select a reference audio file before generating."]
                    )
                }
                if ttsEngine.clonePreparationState.phase != .failed || ttsEngine.clonePreparationState.identityKey != clonePrimingRequestKey {
                    try? await ttsEngine.ensureCloneReferencePrimed(
                        modelID: model.id,
                        reference: CloneReference(
                            audioPath: refPath,
                            transcript: draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript,
                            preparedVoiceID: draft.selectedSavedVoiceID
                        )
                    )
                }

                let outputPath = makeOutputPath(subfolder: model.outputSubfolder, text: promptText)
                audioPlayer.prepareStreamingPreview(
                    title: String(promptText.prefix(40)),
                    shouldAutoPlay: AudioService.shouldAutoPlay
                )
                await AppGenerationTelemetryCoordinator.shared.begin(
                    mode: .clone,
                    requestID: uiTestRequest?.requestID,
                    telemetry: uiTestRequest?.telemetry
                )
                let result = try await ttsEngine.generate(
                    GenerationRequest(
                        mode: .clone,
                        modelID: model.id,
                        text: promptText,
                        outputPath: outputPath,
                        shouldStream: true,
                        streamingInterval: GenerationSemantics.appStreamingInterval,
                        payload: .clone(
                            reference: CloneReference(
                                audioPath: refPath,
                                transcript: draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript,
                                preparedVoiceID: draft.selectedSavedVoiceID
                            )
                        )
                    )
                )
                let voiceName = selectedVoice?.name ?? URL(fileURLWithPath: refPath).deletingPathExtension().lastPathComponent
                var generation = Generation(
                    text: promptText,
                    mode: model.mode.rawValue,
                    modelTier: model.tier,
                    voice: voiceName,
                    emotion: nil,
                    speed: nil,
                    audioPath: result.audioPath,
                    duration: result.durationSeconds,
                    createdAt: Date()
                )
                try GenerationPersistence.persistAndAutoplay(
                    &generation,
                    result: result,
                    text: promptText,
                    audioPlayer: audioPlayer,
                    caller: "IOSVoiceCloningView"
                )
                await AppGenerationTelemetryCoordinator.shared.publishSuccess(
                    mode: .clone,
                    requestID: uiTestRequest?.requestID,
                    result: result
                )
                IOSHaptics.success()
            } catch {
                if (error as? GenerationPersistence.PersistenceError) == nil {
                    audioPlayer.abortLivePreviewIfNeeded()
                }
                errorMessage = error.localizedDescription
                await AppGenerationTelemetryCoordinator.shared.publishFailure(
                    mode: .clone,
                    requestID: uiTestRequest?.requestID,
                    error: error
                )
                IOSHaptics.warning()
            }
            isGenerating = false
        }
    }

    private func syncCloneReferencePriming() async {
        guard !isGenerating else { return }
        guard allowsExecution else {
            await ttsEngine.cancelClonePreparationIfNeeded()
            return
        }
        guard let model = cloneModel,
              let refPath = draft.referenceAudioPath,
              clonePrimingRequestKey != nil else {
            await ttsEngine.cancelClonePreparationIfNeeded()
            return
        }

        if let selectedSavedVoiceID = draft.selectedSavedVoiceID,
           hydratedSavedVoiceID != selectedSavedVoiceID,
           transcriptLoadError == nil {
            await ttsEngine.cancelClonePreparationIfNeeded()
            return
        }

        do {
            try await ttsEngine.ensureCloneReferencePrimed(
                modelID: model.id,
                reference: CloneReference(
                    audioPath: refPath,
                    transcript: draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript,
                    preparedVoiceID: draft.selectedSavedVoiceID
                )
            )
        } catch {
            #if DEBUG
            print("[IOSVoiceCloningView] clone priming failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func applySavedVoice(_ voice: Voice) {
        do {
            let transcript = try SavedVoiceCloneHydration.loadTranscript(for: voice)
            draft.applySavedVoice(voice, transcript: transcript)
            transcriptLoadError = nil
        } catch {
            draft.applySavedVoice(voice, transcript: "")
            transcriptLoadError = "Couldn't load the saved transcript for \"\(voice.name)\". Cloning can still use the audio."
        }
        hydratedSavedVoiceID = voice.id
    }

    private func ensureSelectedSavedVoiceHydratedIfNeeded() {
        guard let selectedVoice else { return }
        guard draft.selectedSavedVoiceID == selectedVoice.id else { return }
        guard hydratedSavedVoiceID != selectedVoice.id else { return }
        guard transcriptLoadError == nil else { return }
        applySavedVoice(selectedVoice)
    }

    private func clearReference() {
        draft.clearReference()
        transcriptLoadError = nil
        hydratedSavedVoiceID = nil
    }

    private func syncSavedVoiceSelectionState() {
        if draft.selectedSavedVoiceID != nil,
           selectedVoice == nil,
           savedVoicesViewModel.isLoading || savedVoicesViewModel.loadError != nil {
            return
        }

        switch SavedVoiceCloneHydration.action(
            draft: draft,
            voice: selectedVoice,
            hydratedVoiceID: hydratedSavedVoiceID,
            transcriptLoadError: transcriptLoadError
        ) {
        case .none:
            break
        case .acceptCurrentDraft:
            hydratedSavedVoiceID = selectedVoice?.id
        case .applyFromDisk:
            if let selectedVoice {
                applySavedVoice(selectedVoice)
            }
        case .clearStaleSelection:
            clearReference()
        }
    }

    private func applyImportedReferenceAudio(from url: URL) {
        do {
            let imported = try ttsEngine.importReferenceAudio(from: url)
            draft.referenceAudioPath = imported.materializedPath
            draft.selectedSavedVoiceID = nil
            transcriptLoadError = nil
            hydratedSavedVoiceID = nil
            errorMessage = nil
            if let transcriptSidecarURL = imported.transcriptSidecarURL,
               let transcript = try? String(contentsOf: transcriptSidecarURL, encoding: .utf8) {
                draft.referenceTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            errorMessage = "Couldn't import the reference audio: \(error.localizedDescription)"
        }
    }
}
