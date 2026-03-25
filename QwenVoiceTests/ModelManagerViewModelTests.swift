import XCTest
@testable import QwenVoice

final class ModelManagerViewModelTests: XCTestCase {
    @MainActor
    func testInitMarksCompleteModelDirectoryAsChecking() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let installedModel = try XCTUnwrap(TTSModel.model(id: "pro_custom"))
        try createInstalledModelFixture(for: installedModel, in: tempRoot)

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)

        XCTAssertEqual(viewModel.statuses[installedModel.id], .checking)
        XCTAssertEqual(viewModel.statuses["pro_design"], .notDownloaded)
        XCTAssertEqual(viewModel.statuses["pro_clone"], .notDownloaded)
    }

    @MainActor
    func testInitLeavesPartialModelDirectoryAsNotDownloaded() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let partialModel = try XCTUnwrap(TTSModel.model(id: "pro_custom"))
        try createPartialModelFixture(for: partialModel, in: tempRoot)

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)

        XCTAssertEqual(viewModel.statuses[partialModel.id], .notDownloaded)
        XCTAssertFalse(viewModel.isLikelyInstalled(partialModel))
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
