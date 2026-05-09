import XCTest
@testable import QwenVoiceCore
@testable import QwenVoiceEngineSupport

final class PlatformCapabilityMatrixTests: XCTestCase {
    func testCapabilityMatrixMatchesSharedEngineCapabilitiesAndTrustPolicy() throws {
        let matrix = try loadMatrix()

        XCTAssertEqual(
            matrix.macOS.xpcService.codeSigningRequirement?.debugAdHocRequirement,
            EngineServiceTrustPolicy.serviceRequirement()
        )
        XCTAssertEqual(
            matrix.macOS.xpcService.codeSigningRequirement?.signedReleaseRequirementTemplate
                .replacingOccurrences(of: "${TEAM_ID}", with: "QwenVoiceTeamIdentifier"),
            EngineServiceTrustPolicy.serviceRequirement(teamIdentifier: "QwenVoiceTeamIdentifier")
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

    func testDeveloperIDReleasePathRunsStrictSignedBundleVerification() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let releaseScriptURL = repoRoot
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("release.sh", isDirectory: false)
        let script = try String(contentsOf: releaseScriptURL)

        XCTAssertTrue(script.contains("QWENVOICE_EXPECT_SIGNED_RELEASE=1"))
        XCTAssertTrue(script.contains("QWENVOICE_EXPECT_TEAM_ID=\"$RELEASE_TEAM_ID\""))
        XCTAssertTrue(script.contains("if [ \"$SIGNING_MODE\" = \"developer-id\" ]; then"))
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
        let codeSigningRequirement: CodeSigningRequirement?
        let engineCapabilities: EngineCapabilities
    }

    struct CodeSigningRequirement: Decodable {
        let debugAdHocRequirement: String
        let signedReleaseRequirementTemplate: String
    }
}
