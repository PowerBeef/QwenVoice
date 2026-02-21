import SwiftUI

extension Notification.Name {
    static let navigateToModels = Notification.Name("navigateToModels")
}

enum SidebarItem: String, CaseIterable, Identifiable {
    // Generate
    case customVoice = "Custom Voice"
    case voiceDesign = "Voice Design"
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
        case .voiceDesign: return "paintbrush"
        case .voiceCloning: return "doc.on.doc"
        case .history: return "clock"
        case .voices: return "waveform"
        case .models: return "arrow.down.circle"
        case .preferences: return "gearshape"
        }
    }

    enum Section: String, CaseIterable {
        case generate = "Generate"
        case library = "Library"
        case settings = "Settings"

        var items: [SidebarItem] {
            switch self {
            case .generate: return [.customVoice, .voiceDesign, .voiceCloning]
            case .library: return [.history, .voices]
            case .settings: return [.models, .preferences]
            }
        }
    }
}

struct ContentView: View {
    @State private var selectedItem: SidebarItem? = .customVoice
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedItem)
        } detail: {
            VStack(spacing: 0) {
                // Main content area
                Group {
                    switch selectedItem {
                    case .customVoice:
                        CustomVoiceView()
                    case .voiceDesign:
                        VoiceDesignView()
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                // Persistent audio player bar
                AudioPlayerBar()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToModels)) { _ in
            selectedItem = .models
        }
    }
}
