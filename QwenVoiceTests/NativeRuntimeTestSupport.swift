import Foundation

enum NativeRuntimeTestSupport {
    struct ModelEntry {
        let id: String
        let name: String
        let folder: String
        let mode: String
        let requiredRelativePaths: [String]

        init(
            id: String,
            name: String,
            folder: String,
            mode: String,
            requiredRelativePaths: [String] = [
                "config.json",
                "speech_tokenizer/model.safetensors",
            ]
        ) {
            self.id = id
            self.name = name
            self.folder = folder
            self.mode = mode
            self.requiredRelativePaths = requiredRelativePaths
        }
    }

    static func makeTemporaryRoot(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func writeManifest(
        at root: URL,
        models: [ModelEntry]
    ) throws -> URL {
        let manifestURL = root.appendingPathComponent("qwenvoice_contract.json")
        let payload: [String: Any] = [
            "defaultSpeaker": "vivian",
            "speakers": [
                "English": ["vivian"]
            ],
            "models": models.map { model in
                [
                    "id": model.id,
                    "name": model.name,
                    "tier": "pro",
                    "mode": model.mode,
                    "folder": model.folder,
                    "huggingFaceRepo": "example/\(model.folder)",
                    "outputSubfolder": model.name.replacingOccurrences(of: " ", with: ""),
                    "requiredRelativePaths": model.requiredRelativePaths,
                ]
            }
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL)
        return manifestURL
    }

    static func installModel(
        _ model: ModelEntry,
        into modelsDirectory: URL,
        existingRelativePaths: [String]? = nil
    ) throws -> URL {
        let installDirectory = modelsDirectory.appendingPathComponent(model.folder, isDirectory: true)
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)

        let relativePaths = existingRelativePaths ?? model.requiredRelativePaths
        for relativePath in relativePaths {
            let fileURL = installDirectory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(relativePath.utf8).write(to: fileURL)
        }
        return installDirectory
    }
}
