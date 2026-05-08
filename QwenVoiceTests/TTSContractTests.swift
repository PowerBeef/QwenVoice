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

    func testContractPinsHuggingFaceRevisions() throws {
        for model in TTSContract.models {
            assertPinnedHuggingFaceRevision(model.huggingFaceRevision, label: model.id)
        }

        let manifestURL = try XCTUnwrap(TTSContract.manifestURL)
        let data = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let rawModels = try XCTUnwrap(manifest["models"] as? [[String: Any]])
        for rawModel in rawModels {
            let modelID = rawModel["id"] as? String ?? "unknown"
            assertPinnedHuggingFaceRevision(
                rawModel["huggingFaceRevision"] as? String,
                label: modelID
            )
            for rawVariant in rawModel["variants"] as? [[String: Any]] ?? [] {
                let variantID = rawVariant["id"] as? String ?? "unknown"
                assertPinnedHuggingFaceRevision(
                    rawVariant["huggingFaceRevision"] as? String,
                    label: "\(modelID).\(variantID)"
                )
            }
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

        XCTAssertEqual(floorModels.count, 6)
        XCTAssertEqual(floorModels.count, midModels.count)
        XCTAssertEqual(floorModels.map(\.id).count, Set(floorModels.map(\.id)).count)

        for mode in QwenVoice.GenerationMode.allCases {
            let floorRecommended = try XCTUnwrap(floorModels.first { $0.mode == mode && $0.isHardwareRecommended })
            let midRecommended = try XCTUnwrap(midModels.first { $0.mode == mode && $0.isHardwareRecommended })
            XCTAssertTrue(floorRecommended.folder.contains("4bit"), "\(mode.rawValue) should recommend Speed on floor Macs.")
            XCTAssertTrue(midRecommended.folder.contains("8bit"), "\(mode.rawValue) should recommend Quality on mid/high Macs.")
        }
    }

    func testActiveVariantPreferenceSelectsGenerationModel() throws {
        let suiteName = "TTSContractTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let defaultModel = try XCTUnwrap(
            TTSContract.modelForTesting(
                mode: .custom,
                deviceClass: .floor8GBMac,
                defaults: defaults
            )
        )
        XCTAssertEqual(defaultModel.variantKind, .speed)

        MacModelVariantPreferences.setSelectedVariantID("quality", for: .custom, defaults: defaults)
        let selectedModel = try XCTUnwrap(
            TTSContract.modelForTesting(
                mode: .custom,
                deviceClass: .floor8GBMac,
                defaults: defaults
            )
        )
        XCTAssertEqual(selectedModel.id, "pro_custom_quality")
        XCTAssertEqual(selectedModel.variantKind, .quality)
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

    private func assertPinnedHuggingFaceRevision(_ revision: String?, label: String) {
        let value = revision ?? ""
        let pattern = #"^[0-9a-f]{40}$"#
        XCTAssertNotNil(
            value.range(of: pattern, options: .regularExpression),
            "\(label) must pin a 40-character lowercase Hugging Face commit SHA."
        )
    }

}
