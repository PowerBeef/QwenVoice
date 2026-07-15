import Foundation
import XCTest
@testable import QwenVoiceCore

final class ProductionModelCatalogTests: XCTestCase {
    func testCompleteCatalogResolvesExactAuthenticatedDownloadFiles() throws {
        let url = try writeCatalog(makeCatalog())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let catalog = try ProductionModelCatalog(contentsOf: url)
        let artifact = try catalog.artifact(
            modelID: "pro_custom",
            variantID: "quality",
            folder: "Custom-8bit",
            repo: "org/custom-8bit",
            revision: String(repeating: "a", count: 40),
            artifactVersion: "v1",
            estimatedDownloadBytes: 7,
            requiredRelativePaths: ["config.json", "weights/model.safetensors"]
        )

        XCTAssertEqual(artifact.totalBytes, 7)
        XCTAssertEqual(artifact.downloadFiles.map(\.path), ["config.json", "weights/model.safetensors"])
        XCTAssertEqual(
            artifact.downloadFiles.last?.absoluteURL?.absoluteString,
            "https://huggingface.co/org/custom-8bit/resolve/\(String(repeating: "a", count: 40))/weights/model.safetensors"
        )
        XCTAssertTrue(
            catalog.downloadURLPolicy.allowsRedirect(
                from: URL(string: "https://huggingface.co/file")!,
                to: URL(string: "https://cas-bridge.xethub.hf.co/object")!
            )
        )
        XCTAssertTrue(catalog.downloadURLPolicy.allowsInitialRequest(artifact.baseURL))
        XCTAssertFalse(
            catalog.downloadURLPolicy.allowsInitialRequest(URL(string: "https://attacker.invalid/object")!)
        )
    }

    func testIncompleteCatalogFailsClosed() throws {
        var document = makeCatalog()
        document["activationState"] = "staged"
        document["missingArtifactIdentities"] = ["pro_custom:quality"]
        let url = try writeCatalog(document)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertThrowsError(try ProductionModelCatalog(contentsOf: url)) { error in
            XCTAssertEqual(
                error as? ProductionModelCatalog.Error,
                .incomplete(["pro_custom:quality"])
            )
        }
    }

    func testMissingDigestAndUntrustedBaseURLFailClosed() throws {
        for mutation in ["digest", "host"] {
            var document = makeCatalog()
            var artifacts = document["artifacts"] as! [[String: Any]]
            if mutation == "digest" {
                var files = artifacts[0]["files"] as! [[String: Any]]
                files[0]["sha256"] = ""
                artifacts[0]["files"] = files
            } else {
                artifacts[0]["baseURL"] = "https://attacker.invalid/org/custom-8bit/resolve/\(String(repeating: "a", count: 40))"
            }
            document["artifacts"] = artifacts
            let url = try writeCatalog(document)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            XCTAssertThrowsError(try ProductionModelCatalog(contentsOf: url), mutation)
        }
    }

    func testDescriptorDriftFailsBeforeDownload() throws {
        let url = try writeCatalog(makeCatalog())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let catalog = try ProductionModelCatalog(contentsOf: url)

        XCTAssertThrowsError(try catalog.artifactMatchingMacOSDescriptor(
            folder: "Custom-8bit",
            repo: "org/custom-8bit",
            revision: String(repeating: "b", count: 40),
            artifactVersion: "v1",
            estimatedDownloadBytes: 7,
            requiredRelativePaths: ["config.json", "weights/model.safetensors"]
        )) { error in
            guard case ProductionModelCatalog.Error.descriptorMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    private func makeCatalog() -> [String: Any] {
        let revision = String(repeating: "a", count: 40)
        return [
            "schemaVersion": 1,
            "catalogSchema": "config/model-catalog-schema-v1.json",
            "activationState": "complete",
            "allowedArtifactHosts": ["huggingface.co"],
            "allowedRedirectHostSuffixes": ["huggingface.co", "hf.co"],
            "sourceDigests": ["contract": String(repeating: "1", count: 64)],
            "missingArtifactIdentities": [],
            "artifacts": [[
                "modelID": "pro_custom",
                "variantID": "quality",
                "platforms": ["macOS"],
                "folder": "Custom-8bit",
                "repo": "org/custom-8bit",
                "revision": revision,
                "artifactVersion": "v1",
                "baseURL": "https://huggingface.co/org/custom-8bit/resolve/\(revision)",
                "totalBytes": 7,
                "files": [
                    [
                        "relativePath": "config.json",
                        "sizeBytes": 3,
                        "sha256": String(repeating: "2", count: 64),
                    ],
                    [
                        "relativePath": "weights/model.safetensors",
                        "sizeBytes": 4,
                        "sha256": String(repeating: "3", count: 64),
                    ],
                ],
            ]],
        ]
    }

    private func writeCatalog(_ document: [String: Any]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("catalog.json")
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: url)
        return url
    }
}
