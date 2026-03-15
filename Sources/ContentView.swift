import SwiftUI
import AppKit

extension Notification.Name {
    static let navigateToModels = Notification.Name("navigateToModels")
    static let navigateToSidebarItem = Notification.Name("navigateToSidebarItem")
    static let generationSaved = Notification.Name("generationSaved")
    static let generationChunkReceived = Notification.Name("generationChunkReceived")
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case customVoice = "Custom Voice"
    case voiceDesign = "Voice Design"
    case voiceCloning = "Voice Cloning"
    case history = "History"
    case voices = "Voices"
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
}

struct ContentView: View {
    @State private var selectedItem: SidebarItem?
    @State private var activatedItems: Set<SidebarItem>
    @State private var pendingHighlightedModelID: String?
    @State private var historySearchText = ""
    @State private var historySortOrder: HistorySortOrder = .newest
    @State private var voicesEnrollRequestID: UUID?
    @State private var voiceDesignVoiceDescription = ""

    private var currentWindowTitle: String {
        selectedItem?.rawValue ?? "QwenVoice"
    }

    private var currentActiveScreenID: String {
        selectedItem?.screenAccessibilityID ?? "screen_customVoice"
    }

    init() {
        let initialSelection = AppLaunchConfiguration.current.initialSidebarItem ?? .customVoice
        _selectedItem = State(initialValue: initialSelection)
        _activatedItems = State(initialValue: [initialSelection])
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedItem)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            detailContent
        }
        .navigationTitle(currentWindowTitle)
        .toolbar {
            mainWindowToolbarContent
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            if let selectedItem {
                activatedItems.insert(selectedItem)
            }
        }
        .onChange(of: selectedItem) { _, newValue in
            if let newValue {
                activatedItems.insert(newValue)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToModels)) { notification in
            pendingHighlightedModelID = notification.object as? String
            selectedItem = .models
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSidebarItem)) { notification in
            if let item = notification.object as? SidebarItem {
                selectedItem = item
            } else if let screenID = notification.object as? String,
                      let item = SidebarItem(testScreenID: screenID) {
                selectedItem = item
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        ZStack {
            ForEach(SidebarItem.allCases) { item in
                if activatedItems.contains(item) {
                    screenView(for: item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .opacity(selectedItem == item ? 1 : 0)
                        .allowsHitTesting(selectedItem == item)
                        .accessibilityHidden(selectedItem != item)
                        .zIndex(selectedItem == item ? 1 : 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topLeading) {
            hiddenWindowMarkers
        }
    }

    @ViewBuilder
    private func screenView(for item: SidebarItem) -> some View {
        switch item {
        case .customVoice:
            CustomVoiceView()
        case .voiceDesign:
            VoiceDesignView(voiceDescription: $voiceDesignVoiceDescription)
        case .voiceCloning:
            VoiceCloningView()
        case .history:
            HistoryView(
                searchText: $historySearchText,
                sortOrder: $historySortOrder
            )
        case .voices:
            VoicesView(enrollRequestID: voicesEnrollRequestID)
        case .models:
            ModelsView(highlightedModelID: $pendingHighlightedModelID)
        }
    }

    @ToolbarContentBuilder
    private var mainWindowToolbarContent: some ToolbarContent {
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
                Button("Enroll Voice") {
                    voicesEnrollRequestID = UUID()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("voices_enrollButton")
            }
        }
    }

    private var hiddenWindowMarkers: some View {
        VStack(spacing: 0) {
            hiddenMarker(
                value: currentWindowTitle,
                identifier: "mainWindow_activeTitle"
            )
            hiddenMarker(
                value: currentActiveScreenID,
                identifier: "mainWindow_activeScreen"
            )
        }
    }

    private func hiddenMarker(value: String, identifier: String) -> some View {
        Text(value)
            .font(.caption2)
            .foregroundStyle(.clear)
            .opacity(0.01)
            .frame(width: 1, height: 1, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityLabel(value)
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
    }
}

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

    final class Coordinator: NSObject, NSSearchFieldDelegate {
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
