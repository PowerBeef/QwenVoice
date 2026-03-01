import SwiftUI

extension Notification.Name {
    static let navigateToModels = Notification.Name("navigateToModels")
    static let generationSaved = Notification.Name("generationSaved")
}

enum SidebarItem: String, CaseIterable, Identifiable {
    // Generate
    case customVoice = "Custom Voice"
    case voiceCloning = "Voice Cloning"
    // Library
    case history = "History"
    case voices = "Voices"
    // Settings
    case models = "Models"
    case preferences = "Preferences"

    var id: String { rawValue }

    var accessibilityID: String { "sidebar_\(String(describing: self))" }

    var iconName: String {
        switch self {
        case .customVoice: return "person.wave.2"
        case .voiceCloning: return "doc.on.doc"
        case .history: return "clock"
        case .voices: return "waveform"
        case .models: return "arrow.down.circle"
        case .preferences: return "gearshape"
        }
    }

    init?(testScreenID: String) {
        let normalized = testScreenID.replacingOccurrences(of: "screen_", with: "")
        switch normalized {
        case "customVoice":
            self = .customVoice
        case "voiceCloning":
            self = .voiceCloning
        case "history":
            self = .history
        case "voices":
            self = .voices
        case "models":
            self = .models
        case "preferences":
            self = .preferences
        default:
            return nil
        }
    }

    enum Section: String, CaseIterable {
        case generate = "Generate"
        case library = "Library"
        case settings = "Settings"

        var items: [SidebarItem] {
            switch self {
            case .generate: return [.customVoice, .voiceCloning]
            case .library: return [.history, .voices]
            case .settings: return [.models, .preferences]
            }
        }
    }
}

struct ContentView: View {
    @State private var selectedItem: SidebarItem?
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel

    init() {
        _selectedItem = State(initialValue: AppLaunchConfiguration.current.initialSidebarItem ?? .customVoice)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedItem)
        } detail: {
            ZStack {
                AuroraBackground()
                    .ignoresSafeArea()

                Group {
                    switch selectedItem {
                    case .customVoice:
                        CustomVoiceView()
                    case .voiceCloning:
                        VoiceCloningView()
                    case .history:
                        HistoryView()
                    case .voices:
                        VoicesView()
                    case .models:
                        ModelsView()
                    case .preferences:
                        PreferencesView()
                    case nil:
                        CustomVoiceView()
                    }
                }
                .id(selectedItem)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToModels)) { _ in
            selectedItem = .models
        }
    }
}
