import XCTest
@testable import QwenVoice

private struct ContractManifestFixture: Decodable {
    struct Model: Decodable {
        let id: String
        let name: String
        let tier: String
        let mode: String
        let folder: String
        let outputSubfolder: String
        let requiredRelativePaths: [String]
    }

    let defaultSpeaker: String
    let speakers: [String: [String]]
    let models: [Model]
}

final class ContractManifestTests: XCTestCase {
    func testModelRegistryComesFromManifest() throws {
        let manifest = try loadManifest()

        XCTAssertEqual(TTSModel.all.map(\.id), manifest.models.map(\.id))
        XCTAssertEqual(TTSModel.all.map(\.name), manifest.models.map(\.name))
        XCTAssertEqual(TTSModel.all.map(\.folder), manifest.models.map(\.folder))
    }

    func testSpeakerListAndDefaultSpeakerComeFromManifest() throws {
        let manifest = try loadManifest()

        XCTAssertEqual(TTSModel.speakerGroups, manifest.speakers)
        XCTAssertEqual(TTSModel.defaultSpeaker, manifest.defaultSpeaker)

        let expectedSpeakers = manifest.speakers.keys.sorted().flatMap { manifest.speakers[$0] ?? [] }
        XCTAssertEqual(TTSModel.allSpeakers, expectedSpeakers)
    }

    func testModeMappingsExposeTierAndOutputSubfolder() throws {
        let manifest = try loadManifest()

        for manifestModel in manifest.models {
            guard let mode = GenerationMode(rawValue: manifestModel.mode) else {
                XCTFail("Unknown manifest mode \(manifestModel.mode)")
                continue
            }

            guard let model = TTSModel.model(for: mode) else {
                XCTFail("Missing TTSModel for mode \(manifestModel.mode)")
                continue
            }

            XCTAssertEqual(model.id, manifestModel.id)
            XCTAssertEqual(model.tier, manifestModel.tier)
            XCTAssertEqual(model.outputSubfolder, manifestModel.outputSubfolder)
            XCTAssertEqual(model.requiredRelativePaths, manifestModel.requiredRelativePaths)
        }
    }

    private func loadManifest() throws -> ContractManifestFixture {
        let data = try Data(contentsOf: TTSContract.manifestURL)
        return try JSONDecoder().decode(ContractManifestFixture.self, from: data)
    }
}
