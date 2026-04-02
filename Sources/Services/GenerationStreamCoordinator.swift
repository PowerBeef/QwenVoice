import Foundation

struct StreamingRequestContext {
    let mode: GenerationMode
    let title: String
}

@MainActor
final class GenerationStreamCoordinator {
    private struct ActiveStreamingRequest {
        let context: StreamingRequestContext
        var streamSessionDirectory: String?
        var cumulativeDurationSeconds: Double
    }

    private var activeStreamingRequests: [Int: ActiveStreamingRequest] = [:]

    func register(requestID: Int, context: StreamingRequestContext) {
        activeStreamingRequests[requestID] = ActiveStreamingRequest(
            context: context,
            streamSessionDirectory: nil,
            cumulativeDurationSeconds: 0
        )
    }

    func remove(requestID: Int) {
        activeStreamingRequests.removeValue(forKey: requestID)
    }

    func removeAll() {
        activeStreamingRequests.removeAll()
    }

    func handleGenerationChunkNotification(_ params: [String: RPCValue]) {
        guard let requestID = params["request_id"]?.intValue,
              var activeStream = activeStreamingRequests[requestID],
              let chunkPath = params["chunk_path"]?.stringValue else {
            return
        }

        let streamSessionDirectory = params["stream_session_dir"]?.stringValue
        if activeStream.streamSessionDirectory == nil {
            activeStream.streamSessionDirectory = streamSessionDirectory
        }
        let chunkDuration = params["chunk_duration_seconds"]?.doubleValue ?? 0
        let cumulativeDuration = params["cumulative_duration_seconds"]?.doubleValue
            ?? activeStream.cumulativeDurationSeconds + chunkDuration
        activeStream.cumulativeDurationSeconds = cumulativeDuration
        activeStreamingRequests[requestID] = activeStream

        NotificationCenter.default.post(
            name: .generationChunkReceived,
            object: nil,
            userInfo: [
                "requestID": requestID,
                "mode": activeStream.context.mode.rawValue,
                "title": activeStream.context.title,
                "chunkPath": chunkPath,
                "isFinal": params["is_final"]?.boolValue ?? false,
                "chunkDurationSeconds": chunkDuration,
                "cumulativeDurationSeconds": cumulativeDuration,
                "streamSessionDirectory": activeStream.streamSessionDirectory ?? "",
            ]
        )
    }
}
