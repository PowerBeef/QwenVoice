import Foundation

/// Shared generation persistence and autoplay logic used by all three generation views.
@MainActor
enum GenerationPersistence {

    enum PersistenceError: LocalizedError {
        case postPlaybackPersistenceFailed(Swift.Error)

        var errorDescription: String? {
            switch self {
            case .postPlaybackPersistenceFailed(let underlyingError):
                return underlyingError.localizedDescription
            }
        }
    }

    /// Saves a generation to the database, posts a notification, and triggers autoplay if configured.
    static func persistAndAutoplay(
        _ generation: inout Generation,
        result: GenerationResult,
        text: String,
        audioPlayer: AudioPlayerViewModel,
        caller: String,
        generationEvents: GenerationLibraryEvents = .shared
    ) throws {
        AppPerformanceSignposts.emit("Final File Ready")

        var didHandoffPlayback = false
        if result.usedStreaming {
            audioPlayer.completeStreamingPreview(
                result: result,
                title: String(text.prefix(40)),
                shouldAutoPlay: AudioService.shouldAutoPlay
            )
            didHandoffPlayback = true
        } else if AudioService.shouldAutoPlay {
            let autoplayStart = DispatchTime.now().uptimeNanoseconds
            audioPlayer.playFile(
                result.audioPath,
                title: String(text.prefix(40)),
                isAutoplay: true
            )
            didHandoffPlayback = true
            #if DEBUG
            print("[Performance][\(caller)] autoplay_start_wall_ms=\(elapsedMs(since: autoplayStart))")
            #endif
        }

        var persistenceError: Swift.Error?
        do {
            let saveStart = DispatchTime.now().uptimeNanoseconds
            try DatabaseService.shared.saveGeneration(&generation)
            #if DEBUG
            print("[Performance][\(caller)] db_save_wall_ms=\(elapsedMs(since: saveStart))")
            #endif

            let notificationStart = DispatchTime.now().uptimeNanoseconds
            generationEvents.announceGenerationSaved()
            #if DEBUG
            print("[Performance][\(caller)] history_notification_wall_ms=\(elapsedMs(since: notificationStart))")
            #endif
        } catch {
            persistenceError = error
        }

        if let persistenceError {
            if didHandoffPlayback {
                throw PersistenceError.postPlaybackPersistenceFailed(persistenceError)
            }
            throw persistenceError
        }
    }

    private static func elapsedMs(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
}
