import XCTest
@testable import QwenVoiceNative

final class NativeModelRegistryTests: XCTestCase {
    func testRegistryUsesContractFolderForInstallDirectory() throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = NativeRuntimeTestSupport.ModelEntry(
            id: "pro_custom",
            name: "Custom Voice",
            folder: "Folder-Based-Install-Root",
            mode: "custom"
        )
        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        let registry = try NativeModelRegistry(manifestURL: manifestURL)

        let descriptor = try XCTUnwrap(registry.descriptor(id: "pro_custom"))
        XCTAssertEqual(descriptor.folder, model.folder)
        XCTAssertEqual(
            registry.installDirectory(for: descriptor, in: root.appendingPathComponent("models", isDirectory: true)),
            root.appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(model.folder, isDirectory: true)
        )
    }

    func testAvailabilityReturnsMissingRequiredPathsForIncompleteInstall() throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = NativeRuntimeTestSupport.ModelEntry(
            id: "pro_clone",
            name: "Voice Cloning",
            folder: "Clone-Folder",
            mode: "clone",
            requiredRelativePaths: [
                "config.json",
                "speech_tokenizer/model.safetensors",
                "tokenizer.json",
            ]
        )
        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        let registry = try NativeModelRegistry(manifestURL: manifestURL)
        let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try NativeRuntimeTestSupport.installModel(
            model,
            into: modelsDirectory,
            existingRelativePaths: ["config.json"]
        )

        let availability = registry.availability(
            forModelID: "pro_clone",
            in: modelsDirectory
        )

        XCTAssertEqual(
            availability,
            .unavailable(
                descriptor: NativeModelDescriptor(
                    id: "pro_clone",
                    name: "Voice Cloning",
                    folder: "Clone-Folder",
                    modeIdentifier: "clone",
                    requiredRelativePaths: [
                        "config.json",
                        "speech_tokenizer/model.safetensors",
                        "tokenizer.json",
                    ]
                ),
                missingRequiredPaths: [
                    "speech_tokenizer/model.safetensors",
                    "tokenizer.json",
                ]
            )
        )
    }

    func testAvailabilityReturnsUnknownForMissingDescriptor() throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [])
        let registry = try NativeModelRegistry(manifestURL: manifestURL)

        XCTAssertEqual(
            registry.availability(
                forModelID: "missing",
                in: root.appendingPathComponent("models", isDirectory: true)
            ),
            .unknown
        )
    }
}
