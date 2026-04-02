import Combine
import Foundation

@MainActor
final class GenerationLibraryEvents: ObservableObject {
    static let shared = GenerationLibraryEvents()

    let generationSaved = PassthroughSubject<Void, Never>()

    private init() {}

    func announceGenerationSaved() {
        generationSaved.send(())
    }
}
