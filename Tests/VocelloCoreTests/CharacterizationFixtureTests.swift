import XCTest

final class CharacterizationFixtureTests: XCTestCase {
    func testTrackedCharacterizationFixturesCoverRequiredCells() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("config/characterization-fixtures.json")
        let data = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(root?["schemaVersion"] as? Int, 1)
        let status = try XCTUnwrap(root?["status"] as? String)
        XCTAssertTrue(
            [
                "model-free-foundation",
                "live-captures-partial",
                "live-characterization-active",
                "closed",
            ].contains(status)
        )
        let fixtures = try XCTUnwrap(root?["fixtures"] as? [[String: Any]])
        let ids = Set(fixtures.compactMap { $0["id"] as? String })
        XCTAssertEqual(
            ids,
            [
                "custom-speed-short-control",
                "design-speed-short-control",
                "clone-speed-short-control",
                "custom-speed-longform-manifest-v3",
            ]
        )
        for fixture in fixtures {
            let digest = try XCTUnwrap(fixture["promptDigest"] as? String)
            XCTAssertEqual(digest.count, 64)
            XCTAssertEqual(fixture["samplingAlgorithmVersion"] as? Int, 2)
            let mode = try XCTUnwrap(fixture["mode"] as? String)
            let frames = try XCTUnwrap(fixture["chunkFrames"] as? [String: Any])
            let first = try XCTUnwrap(frames["first"] as? Int)
            let later = try XCTUnwrap(frames["later"] as? Int)
            XCTAssertEqual(first, 7)
            if mode == "custom" {
                XCTAssertEqual(later, 7)
            } else {
                XCTAssertEqual(later, 14)
            }
        }
        let pending = try XCTUnwrap(root?["liveEvidencePending"] as? [String])
        XCTAssertTrue(pending.isEmpty)
        if status == "closed" {
            XCTAssertFalse((root?["controlSessions"] as? [Any] ?? []).isEmpty)
        }

        let secretSauce = try XCTUnwrap(root?["secretSauceCells"] as? [[String: Any]])
        XCTAssertEqual(secretSauce.count, 3)
        let secretIDs = Set(secretSauce.compactMap { $0["id"] as? String })
        XCTAssertEqual(
            secretIDs,
            [
                "secret-sauce-custom-speed-short",
                "secret-sauce-design-speed-short",
                "secret-sauce-clone-speed-short",
            ]
        )
        for cell in secretSauce {
            let failClosed = try XCTUnwrap(cell["failClosed"] as? [String])
            XCTAssertTrue(failClosed.contains("hardTrim"))
            XCTAssertTrue(failClosed.contains("fullUnload"))
            let warnAllowed = try XCTUnwrap(cell["warnAllowed"] as? [String])
            XCTAssertEqual(warnAllowed, ["softTrim"])
            let fixtureID = try XCTUnwrap(cell["fixtureId"] as? String)
            XCTAssertTrue(ids.contains(fixtureID))
        }

        let captures = try XCTUnwrap(root?["secretSauceCaptures"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(captures.count, 2)
        let platforms = Set(captures.compactMap { $0["platform"] as? String })
        XCTAssertEqual(platforms, ["macos", "ios"])
        for capture in captures {
            XCTAssertEqual(capture["result"] as? String, "pass")
            let record = try XCTUnwrap(capture["record"] as? String)
            XCTAssertTrue(record.hasPrefix("benchmarks/runs/ui-generation/"))
        }
    }
}
