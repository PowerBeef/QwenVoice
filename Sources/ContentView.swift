import SwiftUI
import AppKit
import QwenVoiceNative

struct SavedVoiceCloneHandoffPlan: Equatable {
    let handoff: PendingVoiceCloningHandoff
    let cloneModelID: String?
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case customVoice = "Custom Voice"
    case voiceDesign = "Voice Design"
    case voiceCloning = "Voice Cloning"
    case history = "History"
    case voices = "Saved Voices"
    case models = "Models"

    var id: String { rawValue }

    var accessibilityID: String { "sidebar_\(String(describing: self))" }

    var screenAccessibilityID: String {
        switch self {
        case .customVoice:
            return "screen_customVoice"
        case .voiceDesign:
            return "screen_voiceDesign"
        case .voiceCloning:
            return "screen_voiceCloning"
        case .history:
            return "screen_history"
        case .voices:
            return "screen_voices"
        case .models:
            return "screen_models"
        }
    }

    var generationMode: GenerationMode? {
        switch self {
        case .customVoice:
            return .custom
        case .voiceDesign:
            return .design
        case .voiceCloning:
            return .clone
        case .history, .voices, .models:
            return nil
        }
    }

    var requiredModel: TTSModel? {
        generationMode.flatMap(TTSModel.model(for:))
    }

    var iconName: String {
        switch self {
        case .customVoice: return "person.wave.2"
        case .voiceDesign: return "text.bubble"
        case .voiceCloning: return "waveform.badge.plus"
        case .history: return "clock.arrow.circlepath"
        case .voices: return "person.2.wave.2"
        case .models: return "square.stack.3d.down.right"
        }
    }

#if QW_TEST_SUPPORT
    init?(testScreenID: String) {
        switch testScreenID.replacingOccurrences(of: "screen_", with: "") {
        case "customVoice":
            self = .customVoice
        case "voiceDesign":
            self = .voiceDesign
        case "voiceCloning":
            self = .voiceCloning
        case "history":
            self = .history
        case "voices", "savedVoices":
            self = .voices
        case "models":
            self = .models
        default:
            return nil
        }
    }
#endif

    enum Section: String, CaseIterable {
        case generate = "Generate"
        case library = "Library"
        case settings = "Settings"

        var accessibilityID: String {
            "sidebarSection_\(String(describing: self))"
        }

        var items: [SidebarItem] {
            switch self {
            case .generate:
                return [.customVoice, .voiceDesign, .voiceCloning]
            case .library:
                return [.history, .voices]
            case .settings:
                return [.models]
            }
        }
    }

    static var generationItems: [SidebarItem] {
        [.customVoice, .voiceDesign, .voiceCloning]
    }

    @MainActor
    func isAvailable(using modelManager: ModelManagerViewModel) -> Bool {
        guard let requiredModel else { return true }
        return modelManager.isAvailable(requiredModel)
    }

    @MainActor static func defaultInitialSelection(
        launchOverride: SidebarItem? = AppLaunchConfiguration.current.initialSidebarItem
    ) -> SidebarItem {
        if let launchOverride {
            return launchOverride
        }
        return .customVoice
    }
}

@MainActor
struct ContentView: View {
    @EnvironmentObject private var modelManager: ModelManagerViewModel
    @EnvironmentObject private var ttsEngineStore: TTSEngineStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var savedVoicesViewModel: SavedVoicesViewModel
    @EnvironmentObject private var appCommandRouter: AppCommandRouter

    private let launchSidebarOverride: SidebarItem?

    @State private var selectedSection: SidebarSection?
    @State private var generateMode: GenerationMode = .custom
    @State private var libraryTab: LibraryTab = .history
    @State private var settingsTab: SettingsTab = .models

    @State private var protectedLaunchOverride: SidebarItem?
    @State private var pendingHighlightedModelID: String?
    @State private var historySearchText = ""
    @State private var historySortOrder: HistorySortOrder = .newest
    @State private var voicesEnrollRequestID: UUID?
    @State private var customVoiceDraft = CustomVoiceDraft()
    @State private var voiceDesignDraft = VoiceDesignDraft()
    @State private var voiceCloningDraft = VoiceCloningDraft()
    @State private var pendingVoiceCloningHandoff: PendingVoiceCloningHandoff?
    @State private var didCompleteInitialAvailabilityRefresh = false
    @State private var customVoiceActivationID: Int
    @State private var voiceDesignActivationID: Int
    @State private var voiceCloningActivationID: Int

    private var derivedSidebarItem: SidebarItem? {
        switch selectedSection {
        case .home, .none:
            return nil
        case .generate:
            switch generateMode {
            case .custom: return .customVoice
            case .design: return .voiceDesign
            case .clone:  return .voiceCloning
            }
        case .library:
            return libraryTab.sidebarItem
        case .settings:
            return settingsTab.sidebarItem
        }
    }

    private var currentWindowTitle: String {
        derivedSidebarItem?.rawValue ?? selectedSection?.rawValue ?? "Vocello"
    }

    private var currentActiveScreenID: String {
        if let derivedSidebarItem {
            return derivedSidebarItem.screenAccessibilityID
        }
        switch selectedSection {
        case .home: return "screen_home"
        case .generate: return "screen_generate"
        case .library: return "screen_library"
        case .settings: return "screen_settings"
        case .none: return "screen_home"
        }
    }

    private var disabledGenerationItems: Set<SidebarItem> {
        Set(SidebarItem.generationItems.filter { !$0.isAvailable(using: modelManager) })
    }

    private var disabledSidebarSections: Set<SidebarSection> {
        var disabled: Set<SidebarSection> = []
        let allModesDisabled = SidebarItem.generationItems.allSatisfy {
            disabledGenerationItems.contains($0)
        }
        if allModesDisabled {
            disabled.insert(.generate)
        }
        return disabled
    }

    private var canUseSavedVoicesInVoiceCloning: Bool {
        guard let cloneModel = SidebarItem.voiceCloning.requiredModel else { return false }
        return modelManager.isAvailable(cloneModel)
    }

    private var currentDisabledSidebarIdentifiers: String {
        let identifiers = disabledGenerationItems.map(\.accessibilityID).sorted()
        return identifiers.isEmpty ? "none" : identifiers.joined(separator: ",")
    }

    private var isPreservingLaunchOverrideSelection: Bool {
        guard let protectedLaunchOverride else { return false }
        return derivedSidebarItem == protectedLaunchOverride
    }

    private var sidebarSelectionBinding: Binding<SidebarSection?> {
        Binding(
            get: { selectedSection },
            set: { newValue in
                guard let newValue else { return }
                selectSectionIfEnabled(newValue)
            }
        )
    }

    init() {
        let launchSidebarOverride = AppLaunchConfiguration.current.initialSidebarItem
        self.launchSidebarOverride = launchSidebarOverride

        let initialSelection = SidebarItem.defaultInitialSelection(
            launchOverride: launchSidebarOverride
        )

        let sectionFromItem = ContentView.section(for: initialSelection)
        let initialSection = AppLaunchConfiguration.current.initialSidebarSectionOverride ?? sectionFromItem
        _selectedSection = State(initialValue: initialSection)

        if let mode = initialSelection.generationMode {
            _generateMode = State(initialValue: mode)
        }
        if let libraryTab = initialSelection.libraryTab {
            _libraryTab = State(initialValue: libraryTab)
        }
        if let settingsTab = initialSelection.settingsTab {
            _settingsTab = State(initialValue: settingsTab)
        }

        _protectedLaunchOverride = State(initialValue: launchSidebarOverride)
        _customVoiceActivationID = State(initialValue: initialSelection == .customVoice ? 1 : 0)
        _voiceDesignActivationID = State(initialValue: initialSelection == .voiceDesign ? 1 : 0)
        _voiceCloningActivationID = State(initialValue: initialSelection == .voiceCloning ? 1 : 0)
    }

    static func section(for item: SidebarItem) -> SidebarSection {
        switch item {
        case .customVoice, .voiceDesign, .voiceCloning: return .generate
        case .history, .voices: return .library
        case .models: return .settings
        }
    }

    static func savedVoiceCloneHandoffPlan(
        for voice: Voice,
        cloneModelID: String?,
        transcriptLoader: (Voice) throws -> String = { voice in
            try SavedVoiceCloneHydration.loadTranscript(for: voice)
        }
    ) -> SavedVoiceCloneHandoffPlan {
        let handoff: PendingVoiceCloningHandoff
        do {
            let transcript = try transcriptLoader(voice)
            handoff = PendingVoiceCloningHandoff(
                savedVoiceID: voice.id,
                wavPath: voice.wavPath,
                transcript: transcript,
                transcriptLoadError: nil
            )
        } catch {
            handoff = PendingVoiceCloningHandoff(
                savedVoiceID: voice.id,
                wavPath: voice.wavPath,
                transcript: "",
                transcriptLoadError: "Couldn't load the saved transcript for \"\(voice.name)\". You can still clone from the audio file alone."
            )
        }

        return SavedVoiceCloneHandoffPlan(
            handoff: handoff,
            cloneModelID: cloneModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var activePlayerTint: Color {
        switch selectedSection ?? .home {
        case .home:     return AppTheme.accent
        case .generate: return AppTheme.modeColor(for: generateMode)
        case .library:  return AppTheme.library
        case .settings: return AppTheme.settings
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedSection: sidebarSelectionBinding,
                disabledSections: disabledSidebarSections
            )
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
        } detail: {
            detailContent
        }
        .navigationTitle(currentWindowTitle)
        .toolbar {
            MainWindowToolbar(
                derivedSidebarItem: derivedSidebarItem,
                historySortOrder: $historySortOrder,
                historySearchText: $historySearchText,
                voicesEnrollRequestID: $voicesEnrollRequestID
            )
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WindowFooterPlayer(modeTint: activePlayerTint)
                .environmentObject(audioPlayer)
        }
        .onAppear(perform: handleAppear)
        .task { await handleInitialLoad() }
        .onChange(of: selectedSection) { _, _ in handleSelectionChange() }
        .onChange(of: generateMode) { _, _ in handleSelectionChange() }
        .onChange(of: libraryTab) { _, _ in handleSelectionChange() }
        .onChange(of: settingsTab) { _, _ in handleSelectionChange() }
        .onChange(of: modelManager.statuses) { _, _ in handleStatusesChange() }
        .onReceive(appCommandRouter.sidebarSelection) { item in
            navigateToSidebarItem(item)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        Group {
            sectionHostView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .profileBackground(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topLeading) {
            HiddenWindowMarkers(
                windowTitle: currentWindowTitle,
                activeScreenID: currentActiveScreenID,
                disabledIdentifiers: currentDisabledSidebarIdentifiers
            )
        }
    }

    @ViewBuilder
    private var sectionHostView: some View {
        switch selectedSection ?? .home {
        case .home:
            HomeView { mode in
                navigateToSidebarItem(SidebarItem.item(for: mode))
            }
        case .generate:
            GenerateView(
                mode: $generateMode,
                customVoiceDraft: $customVoiceDraft,
                voiceDesignDraft: $voiceDesignDraft,
                voiceCloningDraft: $voiceCloningDraft,
                pendingVoiceCloningHandoff: $pendingVoiceCloningHandoff,
                customVoiceActivationID: customVoiceActivationID,
                voiceDesignActivationID: voiceDesignActivationID,
                voiceCloningActivationID: voiceCloningActivationID,
                ttsEngineStore: ttsEngineStore,
                audioPlayer: audioPlayer,
                modelManager: modelManager,
                savedVoicesViewModel: savedVoicesViewModel,
                appCommandRouter: appCommandRouter
            )
        case .library:
            LibraryView(
                tab: $libraryTab,
                historySearchText: $historySearchText,
                historySortOrder: $historySortOrder,
                voicesEnrollRequestID: voicesEnrollRequestID,
                canUseSavedVoicesInVoiceCloning: canUseSavedVoicesInVoiceCloning,
                onUseInVoiceCloning: { voice in
                    let plan = Self.savedVoiceCloneHandoffPlan(
                        for: voice,
                        cloneModelID: TTSModel.model(for: .clone)?.id
                    )
                    startSavedVoiceCloningHandoff(plan)
                }
            )
        case .settings:
            SettingsView(
                tab: $settingsTab,
                pendingHighlightedModelID: $pendingHighlightedModelID
            )
        }
    }

    // MARK: - Inline closure methods

    private func handleAppear() {
    }

    private func startSavedVoiceCloningHandoff(_ plan: SavedVoiceCloneHandoffPlan) {
        pendingVoiceCloningHandoff = plan.handoff
        Task {
            await Self.beginSavedVoiceClonePreloadIfPossible(
                plan: plan,
                engineStore: ttsEngineStore
            )
        }
        navigateToSidebarItem(.voiceCloning, bypassDisabledCheck: true)
    }

    static func beginSavedVoiceClonePreloadIfPossible(
        plan: SavedVoiceCloneHandoffPlan,
        engineStore: TTSEngineStore
    ) async {
        guard let cloneModelID = plan.cloneModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !cloneModelID.isEmpty else {
            return
        }
        await engineStore.ensureModelLoadedIfNeeded(id: cloneModelID)
    }

    private func handleInitialLoad() async {
        await modelManager.refresh()
        didCompleteInitialAvailabilityRefresh = true
        if !isPreservingLaunchOverrideSelection {
            reconcileSelectionWithAvailability()
        }
    }

    private func handleSelectionChange() {
        if let protectedLaunchOverride, derivedSidebarItem != protectedLaunchOverride {
            self.protectedLaunchOverride = nil
        }
        if selectedSection == .generate {
            bumpGenerationActivationCounter(for: generateMode)
        }
    }

    private func handleStatusesChange() {
        guard didCompleteInitialAvailabilityRefresh else { return }
        guard !isPreservingLaunchOverrideSelection else { return }
        reconcileSelectionWithAvailability()
    }

    // MARK: - Helper methods

    private func selectSectionIfEnabled(_ section: SidebarSection) {
        guard !disabledSidebarSections.contains(section) else { return }
        AppPerformanceSignposts.emit("Sidebar Selection")
        if selectedSection == section {
            return
        }
        selectedSection = section
    }

    private func navigateToSidebarItem(_ item: SidebarItem, bypassDisabledCheck: Bool = false) {
        if !bypassDisabledCheck, disabledGenerationItems.contains(item) {
            return
        }
        let targetSection = ContentView.section(for: item)
        if let mode = item.generationMode {
            generateMode = mode
        }
        if let libraryTab = item.libraryTab {
            self.libraryTab = libraryTab
        }
        if let settingsTab = item.settingsTab {
            self.settingsTab = settingsTab
        }
        if selectedSection != targetSection {
            selectedSection = targetSection
        }
    }

    private func reconcileSelectionWithAvailability() {
        guard selectedSection == .generate else { return }
        let currentItem = derivedSidebarItem
        guard let currentItem, disabledGenerationItems.contains(currentItem) else { return }

        if let modelID = currentItem.requiredModel?.id {
            pendingHighlightedModelID = modelID
        }

        // Find an available mode; fall back to Settings/Models if none.
        if let firstAvailable = SidebarItem.generationItems.first(where: { !disabledGenerationItems.contains($0) }),
           let availableMode = firstAvailable.generationMode {
            generateMode = availableMode
        } else {
            settingsTab = .models
            selectedSection = .settings
        }
    }

    private func bumpGenerationActivationCounter(for mode: GenerationMode) {
        switch mode {
        case .custom:
            customVoiceActivationID += 1
        case .design:
            voiceDesignActivationID += 1
        case .clone:
            voiceCloningActivationID += 1
        }
    }
}

// MARK: - HiddenWindowMarkers

private struct HiddenWindowMarkers: View {
    let windowTitle: String
    let activeScreenID: String
    let disabledIdentifiers: String

    var body: some View {
        VStack(spacing: 0) {
            hiddenMarker(
                value: windowTitle,
                identifier: "mainWindow_activeTitle"
            )
            hiddenMarker(
                value: activeScreenID,
                identifier: "mainWindow_activeScreen"
            )
            hiddenMarker(
                value: disabledIdentifiers,
                identifier: "mainWindow_disabledSidebarItems"
            )
            hiddenMarker(
                value: "true",
                identifier: "mainWindow_ready"
            )
        }
    }

    private func hiddenMarker(value: String, identifier: String) -> some View {
        Text(value)
            .font(.system(size: 1))
            .opacity(0.01)
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(value)
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
            .accessibilityHidden(false)
    }
}

// MARK: - MainWindowToolbar

private struct MainWindowToolbar: ToolbarContent {
    let derivedSidebarItem: SidebarItem?
    @Binding var historySortOrder: HistorySortOrder
    @Binding var historySearchText: String
    @Binding var voicesEnrollRequestID: UUID?

    var body: some ToolbarContent {
        if derivedSidebarItem == .history {
            ToolbarItem {
                HStack(spacing: 10) {
                    Menu {
                        Picker("Sort", selection: $historySortOrder) {
                            ForEach(HistorySortOrder.allCases) { order in
                                Text(order.label).tag(order)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                    }
                    .accessibilityLabel("Sort history")
                    .accessibilityIdentifier("history_sortPicker")

                    ToolbarSearchField(
                        text: $historySearchText,
                        placeholder: "Search history",
                        accessibilityIdentifier: "history_searchField"
                    )
                    .frame(width: 220)
                }
            }
        }

        if derivedSidebarItem == .voices {
            ToolbarItem {
                Button("Add Voice Sample") {
                    voicesEnrollRequestID = UUID()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("voices_enrollButton")
            }
        }
    }
}

// MARK: - ToolbarSearchField

private struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityIdentifier: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(frame: .zero)
        field.target = context.coordinator
        field.action = #selector(Coordinator.didActivateSearch(_:))
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        configure(field)
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        configure(nsView)
    }

    private func configure(_ field: NSSearchField) {
        field.placeholderString = placeholder
        field.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        field.setAccessibilityLabel(placeholder)
    }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc
        func didActivateSearch(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
