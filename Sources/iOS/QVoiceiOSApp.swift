import AVFoundation
import MLX
import SwiftUI
import UIKit
import QwenVoiceCore

@main
struct QVoiceiOSApp: App {
    @StateObject private var deps = IOSAppDependenciesContainer()
    @UIApplicationDelegateAdaptor private var appDelegate: IOSAppDelegate
    @StateObject private var audioPlayer = AudioPlayerViewModel()
    @StateObject private var savedVoicesViewModel = SavedVoicesViewModel()
    @StateObject private var runtimeReleaseCoordinator = RuntimeReleaseCoordinator()
    @State private var didInitializeEngine = false
    private let memoryBudgetPolicy = IOSMemoryBudgetPolicy.iPhoneShippingDefault
    @Environment(\.scenePhase) private var scenePhase

    init() {
        configureAudioSession()
        configureNativeRuntimeMemoryCacheIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let error = deps.startupError {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .foregroundColor(.orange)
                        Text("App Initialization Failed")
                            .font(.title2.bold())
                        Text(error.localizedDescription)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                    }
                    .padding()
                } else if let modelRegistry = deps.registry, let engine = deps.engine, let manager = deps.modelManager, let installer = deps.modelInstaller {
                    if IOSDeviceSupport.isSupportedHardware {
                        QVoiceiOSRootView(modelRegistry: modelRegistry)
                            .environmentObject(engine)
                            .environmentObject(audioPlayer)
                            .environmentObject(audioPlayer.playbackProgress)
                            .environmentObject(manager)
                            .environmentObject(savedVoicesViewModel)
                            .environmentObject(installer)
                            .onAppear {
                                setupAppSupport()
                                _ = engine.refreshMemoryPolicy()
                                startEngineIfNeeded()
                            }
                            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                                handleMemoryPressure(reason: "memory_warning")
                            }
                            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                                let thermalState = ProcessInfo.processInfo.thermalState
                                if thermalState == .serious || thermalState == .critical {
                                    let reason = "thermal_\(thermalState.rawValue)"
                                    handleMemoryPressure(reason: reason)
                                }
                            }
                            .onReceive(engine.$hasActiveGeneration) { hasActiveGeneration in
                                guard !hasActiveGeneration else { return }
                                executeDeferredMemoryPressureReliefIfNeeded()
                                executeDeferredRuntimeReleaseIfNeeded()
                            }
                            .onReceive(engine.$extensionLifecycleState.removeDuplicates()) { lifecycleState in
                                switch lifecycleState {
                                case .interrupted, .invalidated:
                                    audioPlayer.abortLivePreviewIfNeeded()
                                case .connected:
                                    executeDeferredMemoryPressureReliefIfNeeded()
                                    executeDeferredRuntimeReleaseIfNeeded()
                                case .idle, .launching, .recovering, .failed:
                                    break
                                }
                            }
                    } else {
                        IOSUnsupportedDeviceView(reason: IOSDeviceSupport.unsupportedReason)
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, newValue in
            handleScenePhaseChange(newValue)
        }
    }

    private func startEngineIfNeeded() {
        guard !didInitializeEngine, let engine = deps.engine else { return }
        didInitializeEngine = true
        engine.start()
        Task {
            do {
                try await engine.initialize(appSupportDirectory: AppPaths.appSupportDir)
                _ = engine.refreshMemoryPolicy()
                print("[QVoiceiOSApp] Engine initialized. BenchmarkRunner.isEnabled=\(BenchmarkRunner.isEnabled) args=\(CommandLine.arguments)")
                if BenchmarkRunner.isEnabled {
                    let runner = BenchmarkRunner(engine: engine)
                    await runner.run()
                }
            } catch {
                didInitializeEngine = false
                engine.setVisibleError("Engine initialization failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleScenePhaseChange(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            _ = deps.engine?.refreshMemoryPolicy()
            executeDeferredMemoryPressureReliefIfNeeded()
            executeDeferredRuntimeReleaseIfNeeded()
        case .background:
            releaseRuntime(reason: "background")
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func releaseRuntime(reason: String) {
        let action = runtimeReleaseCoordinator.requestRelease(
            reason: reason,
            hasActiveGeneration: deps.engine?.hasActiveGeneration ?? false
        )

        switch action {
        case .none:
            break
        case .deferred:
            break
        case .execute(let executeReason, let wasDeferred):
            performRuntimeRelease(reason: executeReason, wasDeferred: wasDeferred)
        }
    }

    private func executeDeferredRuntimeReleaseIfNeeded() {
        let action = runtimeReleaseCoordinator.executeDeferredReleaseIfReady(
            hasActiveGeneration: deps.engine?.hasActiveGeneration ?? false
        )

        guard case .execute(let reason, let wasDeferred) = action else {
            return
        }

        performRuntimeRelease(reason: reason, wasDeferred: wasDeferred)
    }

    private func handleMemoryPressure(reason: String) {
        let action = runtimeReleaseCoordinator.requestCacheRelief(
            reason: reason,
            hasActiveGeneration: deps.engine?.hasActiveGeneration ?? false
        )

        switch action {
        case .none:
            break
        case .deferred:
            break
        case .execute(let executeReason):
            performMemoryPressureRelief(reason: executeReason)
        }
    }

    private func executeDeferredMemoryPressureReliefIfNeeded() {
        let action = runtimeReleaseCoordinator.executeDeferredCacheReliefIfReady(
            hasActiveGeneration: deps.engine?.hasActiveGeneration ?? false
        )

        guard case .execute(let reason) = action else {
            return
        }

        performMemoryPressureRelief(reason: reason)
    }

    private func performMemoryPressureRelief(reason: String) {
        guard let engine = deps.engine else {
            clearNativeRuntimeCacheIfAvailable()
            return
        }

        let snapshot = engine.currentMemorySnapshot()
        let trimLevel = memoryBudgetPolicy.trimLevelForPressureEvent(
            snapshot: snapshot,
            isBackgroundTransition: false
        )

        Task { @MainActor in
            await AppGenerationTelemetryCoordinator.shared.recordStage(
                "pre_memory_trim_\(reason)"
            )
            await engine.trimMemory(level: trimLevel, reason: reason)
            if trimLevel == .fullUnload {
                audioPlayer.abortLivePreviewIfNeeded()
                engine.clearGenerationActivity()
            }
            #if DEBUG
            print("[QVoiceiOSApp] Applied \(trimLevel.rawValue) due to \(reason)")
            #endif
        }
    }

    private func configureNativeRuntimeMemoryCacheIfNeeded() {
        guard !IOSSimulatorRuntimeSupport.isSimulator else { return }
        Memory.cacheLimit = 128 * 1024 * 1024
    }

    private func clearNativeRuntimeCacheIfAvailable() {
        guard !IOSSimulatorRuntimeSupport.isSimulator else { return }
        Memory.clearCache()
    }

    private func performRuntimeRelease(reason: String, wasDeferred: Bool) {
        guard let engine = deps.engine else { return }
        Task { @MainActor in
            defer {
                let followUpAction = runtimeReleaseCoordinator.completeRelease(
                    hasActiveGeneration: engine.hasActiveGeneration
                )
                if case .execute(let nextReason, let nextWasDeferred) = followUpAction {
                    performRuntimeRelease(reason: nextReason, wasDeferred: nextWasDeferred)
                }
            }

            await AppGenerationTelemetryCoordinator.shared.recordStage(
                "pre_runtime_release_\(reason)"
            )
            await engine.cancelClonePreparationIfNeeded()
            do {
                try await engine.unloadModel()
            } catch {
                engine.clearVisibleError()
            }
            audioPlayer.abortLivePreviewIfNeeded()
            engine.clearGenerationActivity()
            #if DEBUG
            print("[QVoiceiOSApp] Released runtime due to \(reason)")
            #endif
        }
    }

    private func setupAppSupport() {
        let fileManager = FileManager.default
        let outputSubdirectories = Set(TTSModel.all.map(\.outputSubfolder))
        let directories = [
            AppPaths.appSupportDir,
            AppPaths.modelsDir,
            AppPaths.modelDownloadRootDir,
            AppPaths.modelDownloadStagingDir,
            AppPaths.outputsDir,
            AppPaths.voicesDir,
            AppPaths.appSupportDir.appendingPathComponent("cache", isDirectory: true),
            AppPaths.importedReferenceAudioDir,
            AppPaths.preparedAudioDir,
            AppPaths.normalizedCloneReferenceDir,
            AppPaths.streamSessionsDir,
            AppPaths.nativeMLXCacheDir,
        ] + outputSubdirectories.sorted().map {
            AppPaths.outputsDir.appendingPathComponent($0, isDirectory: true)
        }

        for directory in directories {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try? IOSModelDeliverySupport.excludeFromBackup(AppPaths.modelsDir)
        try? IOSModelDeliverySupport.excludeFromBackup(AppPaths.modelDownloadRootDir)
        try? IOSModelDeliverySupport.excludeFromBackup(AppPaths.modelDownloadStagingDir)
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            #if DEBUG
            print("[QVoiceiOSApp] Failed to configure audio session: \(error.localizedDescription)")
            #endif
        }
    }
}
