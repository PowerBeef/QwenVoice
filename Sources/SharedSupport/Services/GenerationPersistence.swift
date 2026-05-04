import Foundation

#if canImport(QwenVoiceCore)
import QwenVoiceCore
#endif

#if canImport(QwenVoiceNative)
import QwenVoiceNative
#endif

#if canImport(QwenVoiceNative)
typealias PersistenceGenerationResult = QwenVoiceNative.GenerationResult
#elseif canImport(QwenVoiceCore)
typealias PersistenceGenerationResult = QwenVoiceCore.GenerationResult
#endif

/// Shared generation persistence and autoplay logic used by all three generation views.
@MainActor
enum GenerationPersistence {

    /// Hands off playback (synchronously, on `@MainActor`) and schedules
    /// the SQLite save + library-event broadcast in a detached background
    /// Task. The caller's `Generation` value is captured by-value into
    /// the detached Task (no `inout` — the caller never observed
    /// `generation.id` post-save anyway).
    ///
    /// Behavior change from May 2026: persistence errors that occur
    /// AFTER playback handoff are no longer thrown — they're logged via
    /// `print()` in DEBUG only. Rationale: the user already heard their
    /// audio play. A persistence failure means the generation won't
    /// appear in History, which is a quiet non-blocking failure that
    /// doesn't affect the immediate UX. Surfacing it via a thrown error
    /// previously caused an alert that landed AFTER playback was already
    /// running, confusing users who weren't sure what failed.
    ///
    /// UI win: the synchronous DB save (5-30ms blocking on @MainActor)
    /// is gone. UI rendering of the just-completed generation is no
    /// longer hitched by the SQLite write.
    static func persistAndAutoplay(
        _ generation: Generation,
        result: PersistenceGenerationResult,
        text: String,
        audioPlayer: AudioPlayerViewModel,
        caller: String
    ) {
        AppPerformanceSignposts.emit("Final File Ready")
        CustomVoiceUIPerformanceTrace.mark(
            .finalFileReady,
            metadata: [
                "caller": caller,
                "used_streaming": result.usedStreaming ? "true" : "false",
            ],
            metrics: [
                "duration_ms": Int(result.durationSeconds * 1_000),
            ]
        )

        if result.usedStreaming {
            audioPlayer.completeStreamingPreview(
                result: result,
                title: String(text.prefix(40)),
                shouldAutoPlay: AudioService.shouldAutoPlay
            )
        } else {
            let autoplayStart = DispatchTime.now().uptimeNanoseconds
            audioPlayer.playFile(
                result.audioPath,
                title: String(text.prefix(40)),
                isAutoplay: AudioService.shouldAutoPlay,
                presentationContext: .generatePreview
            )
            #if DEBUG
            print("[Performance][\(caller)] autoplay_start_wall_ms=\(elapsedMs(since: autoplayStart))")
            #endif
        }

        // Schedule persistence in a detached Task so it doesn't block the
        // main run loop. `DatabaseService` is now non-isolated; its
        // `DatabaseQueue` handles thread-safety internally.
        Task.detached {
            let saveStart = DispatchTime.now().uptimeNanoseconds
            let savedGeneration: Generation
            do {
                savedGeneration = try await DatabaseService.shared.saveGenerationAsync(generation)
            } catch {
                #if DEBUG
                print("[Performance][\(caller)] db_save_failed: \(error.localizedDescription)")
                #endif
                return
            }
            let saveMS = elapsedMs(since: saveStart)
            #if DEBUG
            print("[Performance][\(caller)] db_save_wall_ms=\(saveMS) (off-main)")
            #endif
            await MainActor.run {
                CustomVoiceUIPerformanceTrace.mark(
                    .databaseSaveFinished,
                    metrics: ["wall_ms": saveMS]
                )

                let notificationStart = DispatchTime.now().uptimeNanoseconds
                #if canImport(QwenVoiceNative)
                GenerationLibraryEvents.shared.announceGenerationAppended(savedGeneration)
                #else
                NotificationCenter.default.post(name: .generationSaved, object: nil)
                #endif
                #if DEBUG
                print("[Performance][\(caller)] history_notification_wall_ms=\(elapsedMs(since: notificationStart))")
                #endif
                CustomVoiceUIPerformanceTrace.mark(
                    .historyNotificationFinished,
                    metrics: ["wall_ms": elapsedMs(since: notificationStart)]
                )
                CustomVoiceUIPerformanceTrace.mark(.persistenceFinished)
            }
        }
    }

    nonisolated private static func elapsedMs(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
}
