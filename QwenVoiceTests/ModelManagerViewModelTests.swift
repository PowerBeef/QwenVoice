import XCTest
@testable import QwenVoice

final class ModelManagerViewModelTests: XCTestCase {
    @MainActor
    func testInitMarksCompleteModelDirectoryAsDownloaded() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let installedModel = try XCTUnwrap(TTSModel.model(id: "pro_custom"))
        try createInstalledModelFixture(for: installedModel, in: tempRoot)

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)

        guard case .downloaded = viewModel.statuses[installedModel.id] else {
            return XCTFail("Expected \(installedModel.id) to be marked downloaded at init, got \(String(describing: viewModel.statuses[installedModel.id]))")
        }
        XCTAssertEqual(viewModel.statuses["pro_design"], .notDownloaded(message: nil))
        XCTAssertEqual(viewModel.statuses["pro_clone"], .notDownloaded(message: nil))
    }

    @MainActor
    func testInitMarksPartialModelDirectoryAsRepairable() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let partialModel = try XCTUnwrap(TTSModel.model(id: "pro_custom"))
        try createPartialModelFixture(for: partialModel, in: tempRoot)

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)

        guard case .repairAvailable(_, let missingRequiredPaths, nil) = viewModel.statuses[partialModel.id] else {
            return XCTFail("Expected \(partialModel.id) to be marked repairable, got \(String(describing: viewModel.statuses[partialModel.id]))")
        }
        XCTAssertFalse(missingRequiredPaths.isEmpty)
        XCTAssertTrue(viewModel.isLikelyInstalled(partialModel))
        XCTAssertEqual(viewModel.primaryActionTitle(for: partialModel), "Repair Model")
    }

    @MainActor
    func testRefreshPromotesCompleteModelDirectoryToDownloaded() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let installedModel = try XCTUnwrap(TTSModel.model(id: "pro_custom"))
        try createInstalledModelFixture(for: installedModel, in: tempRoot)

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)
        await viewModel.refresh()

        guard case .downloaded = viewModel.statuses[installedModel.id] else {
            return XCTFail("Expected \(installedModel.id) to be marked downloaded after refresh, got \(String(describing: viewModel.statuses[installedModel.id]))")
        }
    }

    private func createInstalledModelFixture(for model: TTSModel, in modelsDirectory: URL) throws {
        let fileManager = FileManager.default
        let modelDirectory = model.installDirectory(in: modelsDirectory)
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        for relativePath in model.requiredRelativePaths {
            let fileURL = modelDirectory.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: fileURL)
        }
    }

    private func createPartialModelFixture(for model: TTSModel, in modelsDirectory: URL) throws {
        let fileManager = FileManager.default
        let modelDirectory = model.installDirectory(in: modelsDirectory)
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        guard let firstRelativePath = model.requiredRelativePaths.first else {
            XCTFail("Expected requiredRelativePaths for \(model.id)")
            return
        }

        let fileURL = modelDirectory.appendingPathComponent(firstRelativePath)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: fileURL)
    }
}

final class HuggingFaceDownloaderPathValidationTests: XCTestCase {
    func testValidatedRelativeRepoPathRejectsTraversal() {
        XCTAssertThrowsError(try HuggingFaceDownloader.validatedRelativeRepoPath("../model.safetensors")) { error in
            guard case HuggingFaceDownloader.DownloadError.invalidRemotePath(let path) = error else {
                return XCTFail("Expected invalidRemotePath, got \(error)")
            }
            XCTAssertEqual(path, "../model.safetensors")
        }
    }

    func testValidatedRelativeRepoPathRejectsHiddenComponents() {
        XCTAssertThrowsError(try HuggingFaceDownloader.validatedRelativeRepoPath("weights/.secret/model.safetensors")) { error in
            guard case HuggingFaceDownloader.DownloadError.invalidRemotePath(let path) = error else {
                return XCTFail("Expected invalidRemotePath, got \(error)")
            }
            XCTAssertEqual(path, "weights/.secret/model.safetensors")
        }
    }

    func testValidatedDestinationURLAllowsNestedSafePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let destination = try HuggingFaceDownloader.validatedDestinationURL(
            for: "speech_tokenizer/model.safetensors",
            in: root
        )

        XCTAssertTrue(destination.path.hasPrefix(root.path + "/"))
        XCTAssertEqual(destination.lastPathComponent, "model.safetensors")
        XCTAssertEqual(destination.deletingLastPathComponent().lastPathComponent, "speech_tokenizer")
    }
}
