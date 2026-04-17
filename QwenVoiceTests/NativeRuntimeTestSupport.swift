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

    static func bundledModelEntry(id: String) throws -> ModelEntry {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Resources/qwenvoice_contract.json")
        let data = try Data(contentsOf: manifestURL)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = payload["models"] as? [[String: Any]],
              let model = models.first(where: { ($0["id"] as? String) == id }),
              let name = model["name"] as? String,
              let folder = model["folder"] as? String,
              let mode = model["mode"] as? String,
              let requiredRelativePaths = model["requiredRelativePaths"] as? [String] else {
            throw NSError(
                domain: "NativeRuntimeTestSupport",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing bundled model entry for \(id)."]
            )
        }

        return ModelEntry(
            id: id,
            name: name,
            folder: folder,
            mode: mode,
            requiredRelativePaths: requiredRelativePaths
        )
    }

    static func installedModelsRoot() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["QWENVOICE_APP_SUPPORT_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("models", isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QwenVoice/models", isDirectory: true)
    }

    static func installedModelDirectory(for model: ModelEntry) -> URL {
        installedModelsRoot().appendingPathComponent(model.folder, isDirectory: true)
    }

    static func mirrorInstalledModel(
        _ model: ModelEntry,
        into modelsDirectory: URL
    ) throws -> URL {
        let sourceURL = installedModelDirectory(for: model)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw NSError(
                domain: "NativeRuntimeTestSupport",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Installed model is missing at \(sourceURL.path)."]
            )
        }

        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let targetURL = modelsDirectory.appendingPathComponent(model.folder, isDirectory: true)
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.createSymbolicLink(at: targetURL, withDestinationURL: sourceURL)
        return targetURL
    }
}
