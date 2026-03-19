import XCTest
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
        for mode in GenerationMode.allCases {
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
}
