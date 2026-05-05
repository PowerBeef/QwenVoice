import XCTest
import QwenVoiceCore
@testable import QwenVoice

final class TTSContractTests: XCTestCase {

    func testModelsNonEmpty() {
        XCTAssertFalse(TTSContract.models.isEmpty)
    }

    func testDefaultSpeakerInAllSpeakers() {
        XCTAssertTrue(TTSContract.allSpeakers.contains(TTSContract.defaultSpeaker))
    }

    func testNoDuplicateModelIDs() {
        let ids = TTSContract.models.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate model IDs found")
    }

    func testEachModelHasRequiredFields() {
        for model in TTSContract.models {
            XCTAssertFalse(model.tier.isEmpty, "\(model.id) missing tier")
            XCTAssertFalse(model.outputSubfolder.isEmpty, "\(model.id) missing outputSubfolder")
            XCTAssertFalse(model.requiredRelativePaths.isEmpty, "\(model.id) missing requiredRelativePaths")
        }
    }

    func testModelForModeReturnsCorrectModel() {
        for mode in QwenVoice.GenerationMode.allCases {
            let model = TTSModel.model(for: mode)
            XCTAssertNotNil(model, "No model found for mode \(mode.rawValue)")
            XCTAssertEqual(model?.mode, mode)
        }
    }

    func testModelByIDLookup() {
        for model in TTSContract.models {
            let found = TTSModel.model(id: model.id)
            XCTAssertNotNil(found)
            XCTAssertEqual(found?.id, model.id)
        }
    }

    func testFloorMacModelsResolveToSpeedArtifacts() throws {
        let floorModels = try TTSContract.modelsForTesting(deviceClass: .floor8GBMac)
        let midModels = try TTSContract.modelsForTesting(deviceClass: .mid16GBMac)

        XCTAssertFalse(floorModels.isEmpty)
        XCTAssertEqual(floorModels.count, midModels.count)
        for floorModel in floorModels {
            let midModel = try XCTUnwrap(midModels.first { $0.id == floorModel.id })
            XCTAssertTrue(floorModel.folder.contains("4bit"), "\(floorModel.id) should use the Speed artifact on floor Macs.")
            XCTAssertTrue(midModel.folder.contains("8bit"), "\(midModel.id) should use the Quality artifact on mid/high Macs.")
        }
    }

    func testContractModelsAreQwen3TTSOnly() throws {
        for model in TTSContract.models {
            assertQwen3TTSOnly(model: model, label: model.id)
        }

        let manifestURL = try XCTUnwrap(TTSContract.manifestURL)
        let data = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let rawModels = try XCTUnwrap(manifest["models"] as? [[String: Any]])
        for rawModel in rawModels {
            let modelID = rawModel["id"] as? String ?? "unknown"
            for rawVariant in rawModel["variants"] as? [[String: Any]] ?? [] {
                let variantID = rawVariant["id"] as? String ?? "unknown"
                assertQwen3TTSOnly(rawModel: rawVariant, label: "\(modelID).\(variantID)")
            }
        }
    }

    private func assertQwen3TTSOnly(model: TTSModel, label: String) {
        XCTAssertTrue(
            model.folder.contains("Qwen3-TTS"),
            "\(label) must use a Qwen3-TTS model folder."
        )
        XCTAssertTrue(
            model.huggingFaceRepo.contains("Qwen3-TTS"),
            "\(label) must use a Qwen3-TTS Hugging Face repo."
        )
        XCTAssertTrue(
            model.requiredRelativePaths.contains("speech_tokenizer/model.safetensors"),
            "\(label) must include the Qwen3-TTS speech tokenizer weights."
        )
    }

    private func assertQwen3TTSOnly(rawModel: [String: Any], label: String) {
        let folder = rawModel["folder"] as? String ?? ""
        let huggingFaceRepo = rawModel["huggingFaceRepo"] as? String ?? ""
        let requiredRelativePaths = rawModel["requiredRelativePaths"] as? [String] ?? []
        XCTAssertTrue(
            folder.contains("Qwen3-TTS"),
            "\(label) must use a Qwen3-TTS model folder."
        )
        XCTAssertTrue(
            huggingFaceRepo.contains("Qwen3-TTS"),
            "\(label) must use a Qwen3-TTS Hugging Face repo."
        )
        XCTAssertTrue(
            requiredRelativePaths.contains("speech_tokenizer/model.safetensors"),
            "\(label) must include the Qwen3-TTS speech tokenizer weights."
        )
    }
}
