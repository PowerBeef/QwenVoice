import Foundation

struct UITestContractModel: Decodable {
    let id: String
    let name: String
    let tier: String
    let mode: String
    let folder: String
    let outputSubfolder: String
    let requiredRelativePaths: [String]
}

struct UITestContractManifest: Decodable {
    let defaultSpeaker: String
    let speakers: [String: [String]]
    let models: [UITestContractModel]

    static let current: UITestContractManifest = {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Resources/qwenvoice_contract.json")

        let data = try! Data(contentsOf: manifestURL)
        return try! JSONDecoder().decode(UITestContractManifest.self, from: data)
    }()

    var allSpeakers: [String] {
        speakers.keys.sorted().flatMap { speakers[$0] ?? [] }
    }

    func model(id: String) -> UITestContractModel? {
        models.first { $0.id == id }
    }

    func model(mode: String) -> UITestContractModel? {
        models.first { $0.mode == mode }
    }
}
