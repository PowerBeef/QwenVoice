import Foundation
import os
@testable import QwenVoiceCore

/// Test double that conforms to `MLXModelCoordinating` so unit tests can
/// drive `MLXTTSEngine` through its internal load-coordinator seam without
/// touching MLX, prepared-cache logic, or the real load pipeline.
///
/// Default behavior is "every load throws"; callers configure
/// `loadHandler` when they need a non-trivial result. Tracks invocation
/// history so tests can assert on call counts and arguments.
///
/// Test double for `MLXModelCoordinating`. Widen this mock alongside
/// `MLXModelLoadCoordinator` behavior when runtime tests need variant-aware
/// loaders, prewarm-aware capability profiles, or additional load diagnostics.
final class MockMLXModelCoordinator: MLXModelCoordinating, @unchecked Sendable {
    enum MockError: Error, LocalizedError {
        case loadHandlerNotConfigured(modelID: String)

        var errorDescription: String? {
            switch self {
            case .loadHandlerNotConfigured(let modelID):
                return "MockMLXModelCoordinator received a loadModel(id: \"\(modelID)\") call with no loadHandler configured."
            }
        }
    }

    struct LoadCall: Equatable {
        let modelID: String
        let capabilityProfile: NativeLoadCapabilityProfile
    }

    typealias LoadHandler = @Sendable (
        _ modelID: String,
        _ capabilityProfile: NativeLoadCapabilityProfile
    ) async throws -> NativeModelLoadResult

    private struct State {
        var loadCalls: [LoadCall] = []
        var unloadCallCount = 0
        var prewarmedKeys: Set<String> = []
        var clearPrewarmCallCount = 0
        var loadHandler: LoadHandler?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(loadHandler: LoadHandler? = nil) {
        self.state = OSAllocatedUnfairLock(initialState: State(loadHandler: loadHandler))
    }

    /// When set, called for every `loadModel(...)` invocation. When `nil`
    /// (the default), every load throws `MockError.loadHandlerNotConfigured`.
    var loadHandler: LoadHandler? {
        get { state.withLock { $0.loadHandler } }
        set { state.withLock { $0.loadHandler = newValue } }
    }

    var loadCalls: [LoadCall] {
        state.withLock { $0.loadCalls }
    }

    var unloadCallCount: Int {
        state.withLock { $0.unloadCallCount }
    }

    func loadModel(
        id: String,
        capabilityProfile: NativeLoadCapabilityProfile
    ) async throws -> NativeModelLoadResult {
        let handler = state.withLock { current -> LoadHandler? in
            current.loadCalls.append(LoadCall(modelID: id, capabilityProfile: capabilityProfile))
            return current.loadHandler
        }

        guard let handler else {
            throw MockError.loadHandlerNotConfigured(modelID: id)
        }
        return try await handler(id, capabilityProfile)
    }

    func unloadModel() async {
        state.withLock {
            $0.unloadCallCount += 1
            $0.prewarmedKeys.removeAll()
        }
    }

    func isPrewarmed(identityKey: String) async -> Bool {
        state.withLock { $0.prewarmedKeys.contains(identityKey) }
    }

    func markPrewarmed(identityKey: String) async {
        state.withLock { $0.prewarmedKeys.insert(identityKey) }
    }

    func clearPrewarmState() async {
        state.withLock {
            $0.clearPrewarmCallCount += 1
            $0.prewarmedKeys.removeAll()
        }
    }
}
