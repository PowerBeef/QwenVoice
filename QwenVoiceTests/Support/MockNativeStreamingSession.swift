import Foundation
import os
@testable import QwenVoiceCore

/// Test double that conforms to `NativeStreamingSessionRunning` so unit
/// tests can drive `MLXTTSEngine.generate(...)` through the streaming
/// seam without spinning up a real `NativeStreamingSynthesisSession`.
///
/// Tests configure `events` (delivered to the event sink in order before
/// returning) and `result` (the value that `run` returns), or supply
/// `error` to make `run` throw after emitting any pre-error events.
///
/// Built for Session 5b of the QwenVoiceNativeRuntime retirement.
final class MockNativeStreamingSession: NativeStreamingSessionRunning, @unchecked Sendable {
    private struct State {
        var events: [GenerationEvent]
        var result: GenerationResult?
        var error: Error?
        var runCallCount: Int = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(
        events: [GenerationEvent] = [],
        result: GenerationResult? = nil,
        error: Error? = nil
    ) {
        self.state = OSAllocatedUnfairLock(
            initialState: State(events: events, result: result, error: error)
        )
    }

    var events: [GenerationEvent] {
        get { state.withLock { $0.events } }
        set { state.withLock { $0.events = newValue } }
    }

    var result: GenerationResult? {
        get { state.withLock { $0.result } }
        set { state.withLock { $0.result = newValue } }
    }

    var error: Error? {
        get { state.withLock { $0.error } }
        set { state.withLock { $0.error = newValue } }
    }

    var runCallCount: Int {
        state.withLock { $0.runCallCount }
    }

    func run(
        eventSink: @escaping @MainActor @Sendable (GenerationEvent) -> Void
    ) async throws -> GenerationResult {
        let snapshot = state.withLock { current -> (events: [GenerationEvent], result: GenerationResult?, error: Error?) in
            current.runCallCount += 1
            return (current.events, current.result, current.error)
        }

        for event in snapshot.events {
            await MainActor.run { eventSink(event) }
        }
        if let error = snapshot.error {
            throw error
        }
        guard let result = snapshot.result else {
            throw NSError(
                domain: "MockNativeStreamingSession",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "MockNativeStreamingSession received a run() call with no result and no error configured."]
            )
        }
        return result
    }
}
