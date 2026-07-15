
import SwiftUI

@main
struct VoicesApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem {
                        Label("Text to Speech", systemImage: "waveform")
                    }

                STTView()
                    .tabItem {
                        Label("Speech to Text", systemImage: "mic")
                    }

               STSView()
                  .tabItem {
                     Label("Speech to Speech", systemImage: "waveform.and.mic")
                  }
            }
        }
    }
}
