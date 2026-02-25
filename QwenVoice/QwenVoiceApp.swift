import SwiftUI

@main
struct QwenVoiceApp: App {
    @StateObject private var pythonBridge = PythonBridge()
    @StateObject private var audioPlayer = AudioPlayerViewModel()
    @StateObject private var envManager = PythonEnvironmentManager()

    var body: some Scene {
        WindowGroup {
            Group {
                switch envManager.state {
                case .ready(let pythonPath):
                    ContentView()
                        .environmentObject(pythonBridge)
                        .environmentObject(audioPlayer)
                        .environmentObject(envManager)
                        .frame(minWidth: 780, minHeight: 520)
                        .onAppear {
                            if envManager.needsBackendRestart {
                                pythonBridge.stop()
                                envManager.needsBackendRestart = false
                            }
                            startBackend(pythonPath: pythonPath)
                        }
                default:
                    SetupView(envManager: envManager)
                        .frame(minWidth: 500, minHeight: 400)
                }
            }
            .onAppear {
                setupAppSupport()
                envManager.ensureEnvironment()
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) { }

            // Playback commands
            CommandMenu("Playback") {
                Button("Play / Pause") {
                    audioPlayer.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!audioPlayer.hasAudio)

                Button("Stop") {
                    audioPlayer.stop()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!audioPlayer.hasAudio)
            }

            // File menu additions
            CommandGroup(after: .saveItem) {
                Divider()
                Button("Open Output Folder") {
                    NSWorkspace.shared.open(Self.outputsDir)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Reveal in Finder") {
                    if let path = audioPlayer.currentFilePath {
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(audioPlayer.currentFilePath == nil)
            }
        }
    }

    private func startBackend(pythonPath: String) {
        guard !pythonBridge.isReady, pythonBridge.lastError == nil else { return }
        pythonBridge.start(pythonPath: pythonPath)
        Task {
            try? await pythonBridge.initialize(appSupportDir: Self.appSupportDir.path)
        }
    }

    private func setupAppSupport() {
        let fm = FileManager.default
        let dirs = [
            Self.appSupportDir.path,
            Self.appSupportDir.appendingPathComponent("models").path,
            Self.appSupportDir.appendingPathComponent("outputs").path,
            Self.appSupportDir.appendingPathComponent("outputs/CustomVoice").path,
            Self.appSupportDir.appendingPathComponent("outputs/VoiceDesign").path,
            Self.appSupportDir.appendingPathComponent("outputs/Clones").path,
            Self.appSupportDir.appendingPathComponent("voices").path,
        ]
        for dir in dirs {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    static var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("QwenVoice")
    }

    static var modelsDir: URL { appSupportDir.appendingPathComponent("models") }
    static var outputsDir: URL { appSupportDir.appendingPathComponent("outputs") }
    static var voicesDir: URL { appSupportDir.appendingPathComponent("voices") }
}
