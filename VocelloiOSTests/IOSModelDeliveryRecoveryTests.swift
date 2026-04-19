import CryptoKit
import XCTest
@testable import QVoiceiOS
@testable import QwenVoiceCore

@MainActor
final class IOSModelDeliveryRecoveryTests: XCTestCase {
    func testRestoreCleansPersistedStateWhenModelDescriptorIsMissing() async throws {
        let fixture = try IOSModelDeliveryFixture()
        defer { fixture.cleanup() }

        try fixture.writeFile(
            Data("partial-model".utf8),
            relativePath: "model.safetensors"
        )
        try fixture.writePersistedState(
            IOSPersistedInstallStateFixture(
                modelID: "missing_model",
                artifactVersion: fixture.model.artifactVersion,
                stagingDirectoryPath: fixture.stagingRoot.path,
                catalogEntry: fixture.catalogEntry,
                pendingRelativePaths: fixture.catalogEntry.files.map(\.relativePath),
                currentRelativePath: nil,
                completedBytes: 0,
                totalBytes: fixture.catalogEntry.totalBytes,
                currentFileRetryCount: 0,
                currentResumeDataPath: nil,
                currentPhase: .downloading
            )
        )

        let actor = fixture.makeActor()
        await actor.restoreInFlightInstallIfNeeded()

        XCTAssertFalse(fixture.fileManager.fileExists(atPath: fixture.stateFileURL.path))
        XCTAssertFalse(fixture.fileManager.fileExists(atPath: fixture.stagingRoot.path))
    }

    func testRestoreCleansPersistedStateWhenArtifactVersionDrifts() async throws {
        let fixture = try IOSModelDeliveryFixture()
        defer { fixture.cleanup() }

        try fixture.writeFile(
            Data("partial-model".utf8),
            relativePath: "model.safetensors"
        )
        try fixture.writePersistedState(
            IOSPersistedInstallStateFixture(
                modelID: fixture.model.id,
                artifactVersion: "outdated-artifact",
                stagingDirectoryPath: fixture.stagingRoot.path,
                catalogEntry: fixture.catalogEntry,
                pendingRelativePaths: fixture.catalogEntry.files.map(\.relativePath),
                currentRelativePath: nil,
                completedBytes: 0,
                totalBytes: fixture.catalogEntry.totalBytes,
                currentFileRetryCount: 0,
                currentResumeDataPath: nil,
                currentPhase: .downloading
            )
        )

        let actor = fixture.makeActor()
        await actor.restoreInFlightInstallIfNeeded()

        XCTAssertFalse(fixture.fileManager.fileExists(atPath: fixture.stateFileURL.path))
        XCTAssertFalse(fixture.fileManager.fileExists(atPath: fixture.stagingRoot.path))
    }

    func testRestoreCompletesVerifiedInstallFromPreparedStagingArea() async throws {
        let fixture = try IOSModelDeliveryFixture()
        defer { fixture.cleanup() }

        try fixture.writeFile(
            fixture.requiredModelData,
            relativePath: "model.safetensors"
        )
        try fixture.writePersistedState(
            IOSPersistedInstallStateFixture(
                modelID: fixture.model.id,
                artifactVersion: fixture.model.artifactVersion,
                stagingDirectoryPath: fixture.stagingRoot.path,
                catalogEntry: fixture.catalogEntry,
                pendingRelativePaths: [],
                currentRelativePath: nil,
                completedBytes: fixture.catalogEntry.totalBytes,
                totalBytes: fixture.catalogEntry.totalBytes,
                currentFileRetryCount: 0,
                currentResumeDataPath: nil,
                currentPhase: .verifying
            )
        )

        var snapshots: [IOSModelDeliverySnapshot] = []
        let actor = fixture.makeActor { snapshot in
            snapshots.append(snapshot)
        }

        await actor.restoreInFlightInstallIfNeeded()

        let installedRoot = fixture.modelAssetStore.localRoot(for: fixture.assetDescriptor)
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: installedRoot.path))
        XCTAssertTrue(
            fixture.fileManager.fileExists(
                atPath: installedRoot.appendingPathComponent("model.safetensors").path
            )
        )
        XCTAssertFalse(fixture.fileManager.fileExists(atPath: fixture.stateFileURL.path))
        XCTAssertFalse(fixture.fileManager.fileExists(atPath: fixture.stagingRoot.path))
        XCTAssertEqual(snapshots.map(\.phase), [.verifying, .verifying, .installing, .installed])
    }

    func testVerifyDownloadedModelRejectsUnexpectedFiles() throws {
        let fixture = try IOSModelDeliveryFixture()
        defer { fixture.cleanup() }

        try fixture.writeFile(
            fixture.requiredModelData,
            relativePath: "model.safetensors"
        )
        try fixture.writeFile(
            Data("rogue".utf8),
            relativePath: "rogue.txt"
        )

        XCTAssertThrowsError(
            try IOSModelDeliverySupport.verifyDownloadedModel(
                descriptor: fixture.model,
                entry: fixture.catalogEntry,
                stagedRoot: fixture.stagingRoot,
                fileManager: fixture.fileManager
            )
        ) { error in
            XCTAssertEqual(error as? IOSModelDeliveryError, .unexpectedFile("rogue.txt"))
        }
    }

    func testMatchingCatalogEntryRejectsUnexpectedTraversalPath() throws {
        let fixture = try IOSModelDeliveryFixture()
        defer { fixture.cleanup() }

        let invalidEntry = IOSModelCatalogEntry(
            modelID: fixture.model.id,
            artifactVersion: fixture.model.artifactVersion,
            totalBytes: 12,
            baseURL: URL(string: "https://downloads.qvoice.app/ios/models/\(fixture.model.id)")!,
            files: [
                IOSModelCatalogFile(
                    relativePath: "../escape/model.safetensors",
                    sizeBytes: 12,
                    sha256: String(repeating: "a", count: 64),
                    url: nil
                )
            ]
        )

        XCTAssertThrowsError(
            try IOSModelDeliverySupport.matchingCatalogEntry(
                for: fixture.model,
                in: IOSModelCatalogDocument(generatedAt: nil, models: [invalidEntry]),
                configuration: fixture.configuration
            )
        ) { error in
            XCTAssertEqual(
                error as? IOSModelDeliveryError,
                .unexpectedFile("../escape/model.safetensors")
            )
        }
    }
}

private struct IOSPersistedInstallStateFixture: Encodable {
    let modelID: String
    let artifactVersion: String
    let stagingDirectoryPath: String
    let catalogEntry: IOSModelCatalogEntry
    let pendingRelativePaths: [String]
    let currentRelativePath: String?
    let completedBytes: Int64
    let totalBytes: Int64
    let currentFileRetryCount: Int
    let currentResumeDataPath: String?
    let currentPhase: IOSModelDeliverySnapshot.Phase
}

private struct IOSModelDeliveryFixture {
    let root: URL
    let fileManager: FileManager
    let modelAssetStore: LocalModelAssetStore
    let model: ModelDescriptor
    let assetDescriptor: ModelAssetDescriptor
    let configuration: IOSModelDeliveryConfiguration
    let stateFileURL: URL
    let stagingRoot: URL
    let requiredModelData: Data
    let catalogEntry: IOSModelCatalogEntry

    init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        self.root = fileManager.temporaryDirectory
            .appendingPathComponent("ios-model-delivery-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let registry = IOSModelDeliveryTestRegistry()
        let modelsRoot = root.appendingPathComponent("models", isDirectory: true)
        try fileManager.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        self.modelAssetStore = LocalModelAssetStore(
            modelRegistry: registry,
            rootDirectory: modelsRoot,
            storeVersionSeed: "tests"
        )
        self.model = registry.models[0]
        self.assetDescriptor = try XCTUnwrap(modelAssetStore.descriptor(id: model.id))
        self.configuration = IOSModelDeliveryConfiguration(
            catalogURL: URL(string: "https://downloads.qvoice.app/ios/catalog/v1/models.json")!,
            backgroundSessionIdentifier: "com.qvoice.tests.delivery.\(UUID().uuidString)"
        )
        self.stateFileURL = root
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("delivery.json", isDirectory: false)
        self.stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        self.requiredModelData = Data("verified-model".utf8)
        self.catalogEntry = IOSModelCatalogEntry(
            modelID: model.id,
            artifactVersion: model.artifactVersion,
            totalBytes: Int64(requiredModelData.count),
            baseURL: URL(string: "https://downloads.qvoice.app/ios/models/\(model.id)")!,
            files: [
                IOSModelCatalogFile(
                    relativePath: "model.safetensors",
                    sizeBytes: Int64(requiredModelData.count),
                    sha256: Self.sha256Hex(for: requiredModelData),
                    url: nil
                )
            ]
        )
    }

    func makeActor(
        snapshotSink: @escaping @MainActor @Sendable (IOSModelDeliverySnapshot) -> Void = { _ in }
    ) -> IOSModelDeliveryActor {
        IOSModelDeliveryActor(
            modelAssetStore: modelAssetStore,
            configuration: configuration,
            stateFileURL: stateFileURL,
            fileManager: fileManager,
            snapshotSink: snapshotSink
        )
    }

    func writePersistedState(_ state: IOSPersistedInstallStateFixture) throws {
        try fileManager.createDirectory(
            at: stateFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateFileURL, options: .atomic)
    }

    func writeFile(_ data: Data, relativePath: String) throws {
        let destination = stagingRoot.appendingPathComponent(relativePath, isDirectory: false)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
    }

    func cleanup() {
        try? fileManager.removeItem(at: root)
    }

    private static func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct IOSModelDeliveryTestRegistry: ModelRegistry {
    let models: [ModelDescriptor] = [
        ModelDescriptor(
            id: "pro_custom",
            name: "Custom Voice",
            tier: "pro",
            folder: "Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
            mode: .custom,
            huggingFaceRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
            artifactVersion: "2026.04.05.2",
            iosDownloadEligible: true,
            estimatedDownloadBytes: 1_234,
            outputSubfolder: "CustomVoice",
            requiredRelativePaths: ["model.safetensors"]
        )
    ]

    let defaultSpeaker = SpeakerDescriptor(group: "English", id: "vivian")
    let groupedSpeakers = ["English": [SpeakerDescriptor(group: "English", id: "vivian")]]
    let allSpeakers = [SpeakerDescriptor(group: "English", id: "vivian")]

    func model(for mode: GenerationMode) -> ModelDescriptor? {
        models.first { $0.mode == mode }
    }

    func model(id: String) -> ModelDescriptor? {
        models.first { $0.id == id }
    }
}
