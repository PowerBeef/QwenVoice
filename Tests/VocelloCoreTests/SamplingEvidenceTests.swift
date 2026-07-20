import XCTest
@testable import QwenVoiceCore

final class SamplingEvidenceTests: XCTestCase {
    func testPromotionRequiresMatchingSeedsAndWAVDigest() throws {
        let evidence = SamplingTakeEvidence(
            plannedSeed: 42,
            observedSeed: 42,
            seedSource: .requested,
            wavDigest: String(repeating: "ab", count: 32)
        )
        XCTAssertNoThrow(try evidence.validatedForPromotion())
        XCTAssertEqual(evidence.telemetryNotes["samplingSeedAgreement"], "matched")
        XCTAssertEqual(evidence.telemetryNotes["samplingWAVDigest"]?.count, 64)
        let packaged = try evidence.packagedTelemetryNotes()
        XCTAssertEqual(packaged["samplingPromotionPackaged"], "true")
        let reconstructed = try XCTUnwrap(SamplingTakeEvidence(telemetryNotes: packaged))
        XCTAssertNoThrow(try reconstructed.validatedForPromotion())
    }

    func testMissingOrMismatchedSeedsFailClosed() {
        XCTAssertThrowsError(
            try SamplingTakeEvidence(
                plannedSeed: nil,
                observedSeed: 1,
                seedSource: .generated,
                wavDigest: String(repeating: "cd", count: 32)
            ).validatedForPromotion()
        ) { error in
            XCTAssertEqual(error as? SamplingTakeEvidence.AgreementError, .missingPlannedSeed)
        }

        XCTAssertThrowsError(
            try SamplingTakeEvidence(
                plannedSeed: 1,
                observedSeed: nil,
                seedSource: .requested,
                wavDigest: String(repeating: "cd", count: 32)
            ).validatedForPromotion()
        ) { error in
            XCTAssertEqual(error as? SamplingTakeEvidence.AgreementError, .missingObservedSeed)
        }

        XCTAssertThrowsError(
            try SamplingTakeEvidence(
                plannedSeed: 1,
                observedSeed: 2,
                seedSource: .requested,
                wavDigest: String(repeating: "cd", count: 32)
            ).validatedForPromotion()
        ) { error in
            XCTAssertEqual(
                error as? SamplingTakeEvidence.AgreementError,
                .seedMismatch(planned: 1, observed: 2)
            )
        }

        XCTAssertThrowsError(
            try SamplingTakeEvidence(
                plannedSeed: 1,
                observedSeed: 1,
                seedSource: .requested,
                wavDigest: nil
            ).validatedForPromotion()
        ) { error in
            XCTAssertEqual(error as? SamplingTakeEvidence.AgreementError, .missingWAVDigest)
        }
    }

    func testSubSeedDerivationIsDomainSeparatedAndDeterministic() throws {
        let base: UInt64 = 19_790_615
        let first = try SamplingSubSeedDerivation.derive(
            baseSeed: base,
            domain: .longFormSegment,
            components: ["segment-a"]
        )
        let repeatFirst = try SamplingSubSeedDerivation.derive(
            baseSeed: base,
            domain: .longFormSegment,
            components: ["segment-a"]
        )
        let otherSegment = try SamplingSubSeedDerivation.derive(
            baseSeed: base,
            domain: .longFormSegment,
            components: ["segment-b"]
        )
        let otherDomain = try SamplingSubSeedDerivation.derive(
            baseSeed: base,
            domain: .candidateRetry,
            components: ["segment-a"]
        )
        XCTAssertEqual(first, repeatFirst)
        XCTAssertNotEqual(first, otherSegment)
        XCTAssertNotEqual(first, otherDomain)
        XCTAssertThrowsError(
            try SamplingSubSeedDerivation.derive(
                baseSeed: base,
                domain: .characterizationControl,
                components: [""]
            )
        )
    }

    func testWAVDigestHashesFileContents() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sampling-evidence-\(UUID().uuidString).bin")
        let payload = Data("vocello-sampling-evidence".utf8)
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let digest = try SamplingTakeEvidence.sha256FileDigest(at: url)
        XCTAssertEqual(digest.count, 64)
        XCTAssertEqual(digest, try SamplingTakeEvidence.sha256FileDigest(at: url))
    }
}
