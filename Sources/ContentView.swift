import SwiftUI
import AppKit
import QwenVoiceNative

extension Notification.Name {
    static let generationChunkReceived = Notification.Name("generationChunkReceived")
}

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
        case "voices":
            self = .voices
        case "models":
            self = .models
        default:
            return nil
        }
    }

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
    @EnvironmentObject private var appCommandRouter: AppCommandRouter

    private let launchSidebarOverride: SidebarItem?

    @State private var selectedItem: SidebarItem?
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

    private var currentWindowTitle: String {
        selectedItem?.rawValue ?? "QwenVoice"
    }

    private var currentActiveScreenID: String {
        selectedItem?.screenAccessibilityID ?? "screen_customVoice"
    }

    private var disabledSidebarItems: Set<SidebarItem> {
        Set(SidebarItem.generationItems.filter { !$0.isAvailable(using: modelManager) })
    }

    private var canUseSavedVoicesInVoiceCloning: Bool {
        guard let cloneModel = SidebarItem.voiceCloning.requiredModel else { return false }
        return modelManager.isAvailable(cloneModel)
    }

    private var currentDisabledSidebarIdentifiers: String {
        let identifiers = disabledSidebarItems.map(\.accessibilityID).sorted()
        return identifiers.isEmpty ? "none" : identifiers.joined(separator: ",")
    }

    private var isPreservingLaunchOverrideSelection: Bool {
        guard let protectedLaunchOverride else { return false }
        return selectedItem == protectedLaunchOverride
    }

    private var sidebarSelectionBinding: Binding<SidebarItem?> {
        Binding(
            get: { selectedItem },
            set: { newValue in
                guard let newValue else { return }
                selectSidebarItemIfEnabled(newValue)
            }
        )
    }

    init() {
        let launchSidebarOverride = AppLaunchConfiguration.current.initialSidebarItem
        self.launchSidebarOverride = launchSidebarOverride

        let initialSelection = SidebarItem.defaultInitialSelection(
            launchOverride: launchSidebarOverride
        )
        _selectedItem = State(initialValue: initialSelection)
        _protectedLaunchOverride = State(initialValue: launchSidebarOverride)
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

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: sidebarSelectionBinding,
                disabledItems: disabledSidebarItems
            )
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            detailContent
        }
        .navigationTitle(currentWindowTitle)
        .toolbar {
            MainWindowToolbar(
                selectedItem: selectedItem,
                historySortOrder: $historySortOrder,
                historySearchText: $historySearchText,
                voicesEnrollRequestID: $voicesEnrollRequestID
            )
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear(perform: handleAppear)
        .task { await handleInitialLoad() }
        .onChange(of: selectedItem) { _, newValue in handleSelectionChange(newValue) }
        .onChange(of: modelManager.statuses) { _, _ in handleStatusesChange() }
        .onReceive(appCommandRouter.sidebarSelection) { item in
            selectSidebarItemIfEnabled(item)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        Group {
            if let selectedItem {
                screenView(for: selectedItem)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Color.clear
            }
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
    private func screenView(for item: SidebarItem) -> some View {
        switch item {
        case .customVoice:
            CustomVoiceView(draft: $customVoiceDraft)
        case .voiceDesign:
            VoiceDesignView(draft: $voiceDesignDraft)
        case .voiceCloning:
            VoiceCloningView(
                draft: $voiceCloningDraft,
                pendingSavedVoiceHandoff: $pendingVoiceCloningHandoff
            )
        case .history:
            HistoryView(
                searchText: $historySearchText,
                sortOrder: $historySortOrder
            )
        case .voices:
            VoicesView(
                enrollRequestID: voicesEnrollRequestID,
                canUseInVoiceCloning: canUseSavedVoicesInVoiceCloning,
                onUseInVoiceCloning: { voice in
                    let plan = Self.savedVoiceCloneHandoffPlan(
                        for: voice,
                        cloneModelID: TTSModel.model(for: .clone)?.id
                    )
                    startSavedVoiceCloningHandoff(plan)
                }
            )
        case .models:
            ModelsView(highlightedModelID: $pendingHighlightedModelID)
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
        selectSidebarItemIfEnabled(
            .voiceCloning,
            bypassDisabledCheck: true
        )
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

    private func handleSelectionChange(_ newValue: SidebarItem?) {
        if let protectedLaunchOverride, newValue != protectedLaunchOverride {
            self.protectedLaunchOverride = nil
        }
    }

    private func handleStatusesChange() {
        guard didCompleteInitialAvailabilityRefresh else { return }
        guard !isPreservingLaunchOverrideSelection else { return }
        reconcileSelectionWithAvailability()
    }

    // MARK: - Helper methods

    private func selectSidebarItemIfEnabled(_ item: SidebarItem, bypassDisabledCheck: Bool = false) {
        guard bypassDisabledCheck || !disabledSidebarItems.contains(item) else { return }
        AppPerformanceSignposts.emit("Sidebar Selection")
        if selectedItem == item {
            return
        }
        selectedItem = item
    }

    private func reconcileSelectionWithAvailability() {
        guard let selectedItem, disabledSidebarItems.contains(selectedItem) else {
            return
        }

        if let modelID = selectedItem.requiredModel?.id {
            pendingHighlightedModelID = modelID
        }

        self.selectedItem = .models
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
    let selectedItem: SidebarItem?
    @Binding var historySortOrder: HistorySortOrder
    @Binding var historySearchText: String
    @Binding var voicesEnrollRequestID: UUID?

    var body: some ToolbarContent {
        if selectedItem == .history {
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

        if selectedItem == .voices {
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
