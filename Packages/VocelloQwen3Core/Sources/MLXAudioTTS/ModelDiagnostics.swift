import Foundation

public protocol SpeechGenerationModelDiagnosticsProvider: AnyObject {
    var loadTimingsMS: [String: Int] { get }
    var loadBooleanFlags: [String: Bool] { get }
    var latestPreparationTimingsMS: [String: Int] { get }
    var latestPreparationBooleanFlags: [String: Bool] { get }
    var latestPreparationStringFlags: [String: String] { get }
    func resetPreparationDiagnostics()
}

public extension SpeechGenerationModelDiagnosticsProvider {
    var latestPreparationStringFlags: [String: String] {
        [:]
    }
}
