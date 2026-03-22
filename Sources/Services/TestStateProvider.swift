import Foundation

/// Aggregates app UI state for test-mode queries.
/// Only active when UITestAutomationSupport.isEnabled.
@MainActor
final class TestStateProvider: ObservableObject {
    static let shared = TestStateProvider()

    @Published var activeScreen: String = ""
    @Published var windowTitle: String = ""
    @Published var isReady: Bool = false
    @Published var selectedSpeaker: String = ""
    @Published var emotion: String = ""
    @Published var isGenerating: Bool = false
    @Published var text: String = ""
    @Published var disabledSidebarItems: String = ""

    func snapshot() -> [String: Any] {
        [
            "activeScreen": activeScreen,
            "windowTitle": windowTitle,
            "isReady": isReady,
            "selectedSpeaker": selectedSpeaker,
            "emotion": emotion,
            "isGenerating": isGenerating,
            "text": text,
            "disabledSidebarItems": disabledSidebarItems,
        ]
    }
}
