import Foundation

extension ExtensionEngineCommand {
    var transportName: String {
        switch self {
        case .initialize:
            "initialize"
        case .ping:
            "ping"
        case .loadModel:
            "loadModel"
        case .unloadModel:
            "unloadModel"
        case .prepareAudio:
            "prepareAudio"
        case .ensureModelLoadedIfNeeded:
            "ensureModelLoadedIfNeeded"
        case .prewarmModelIfNeeded:
            "prewarmModelIfNeeded"
        case .prefetchInteractiveReadinessIfNeeded:
            "prefetchInteractiveReadinessIfNeeded"
        case .ensureCloneReferencePrimed:
            "ensureCloneReferencePrimed"
        case .cancelClonePreparationIfNeeded:
            "cancelClonePreparationIfNeeded"
        case .generate:
            "generate"
        case .listPreparedVoices:
            "listPreparedVoices"
        case .enrollPreparedVoice:
            "enrollPreparedVoice"
        case .deletePreparedVoice:
            "deletePreparedVoice"
        case .clearGenerationActivity:
            "clearGenerationActivity"
        case .clearVisibleError:
            "clearVisibleError"
        case .trimMemory:
            "trimMemory"
        }
    }

    var transportTimeout: Duration? {
        switch self {
        case .generate:
            // Hard upper bound so a misbehaving or silent remote cannot leave
            // the client hanging forever. Still far larger than any reasonable
            // synthesis would take on supported hardware (Tier 3.1).
            .seconds(600)
        case .initialize, .loadModel, .unloadModel, .prepareAudio,
             .ensureModelLoadedIfNeeded, .prewarmModelIfNeeded,
             .prefetchInteractiveReadinessIfNeeded, .ensureCloneReferencePrimed,
             .trimMemory:
            .seconds(180)
        case .ping, .cancelClonePreparationIfNeeded, .listPreparedVoices,
             .enrollPreparedVoice, .deletePreparedVoice,
             .clearGenerationActivity, .clearVisibleError:
            .seconds(10)
        }
    }
}
