@preconcurrency import Combine
import Foundation

@MainActor
public final class GenerationChunkBroker {
    public static let shared = GenerationChunkBroker()

    private let subject = PassthroughSubject<GenerationEvent, Never>()

    private init() {}

    public var publisher: AnyPublisher<GenerationEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    public nonisolated static func publish(_ event: GenerationEvent) {
        Task { @MainActor in
            shared.subject.send(event)
        }
    }
}
