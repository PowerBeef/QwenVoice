import XCTest
@testable import QwenVoiceCore
@testable import QwenVoiceEngineSupport

final class PlatformCapabilityMatrixTests: XCTestCase {
    func testCapabilityMatrixMatchesSharedEngineCapabilitiesAndTrustPolicy() throws {
        let matrix = try loadMatrix()

        XCTAssertEqual(
            matrix.macOS.xpcService.codeSigningRequirement,
            EngineServiceTrustPolicy.serviceRequirement()
        )
        XCTAssertEqual(
            matrix.macOS.xpcService.engineCapabilities,
            EngineCapabilities.macOSXPCDefault
        )
        XCTAssertEqual(
            matrix.iOS.extension.engineCapabilities,
            EngineCapabilities.iOSExtensionDefault
        )
    }

    private func loadMatrix() throws -> PlatformCapabilityMatrix {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let matrixURL = repoRoot
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("apple-platform-capability-matrix.json", isDirectory: false)
        let data = try Data(contentsOf: matrixURL)
        return try JSONDecoder().decode(PlatformCapabilityMatrix.self, from: data)
    }
}

private struct PlatformCapabilityMatrix: Decodable {
    let macOS: MacPlatform
    let iOS: IOSPlatform

    private enum CodingKeys: String, CodingKey {
        case macOS = "macOS"
        case iOS = "iOS"
    }

    struct MacPlatform: Decodable {
        let xpcService: RuntimeSurface
    }

    struct IOSPlatform: Decodable {
        let `extension`: RuntimeSurface
    }

    struct RuntimeSurface: Decodable {
        let codeSigningRequirement: String?
        let engineCapabilities: EngineCapabilities
    }
}
